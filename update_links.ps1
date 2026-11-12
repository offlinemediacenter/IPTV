<#
  update_links.ps1 - rebuild My_Playlist.m3u from the master list in channels.json.

  No login, no credentials. For every channel in channels.json it:
    1. tests the channel's URL; if it plays, the channel goes in the playlist;
    2. otherwise looks for a replacement in persianagroup.tv's public channel list
       ("persiana" site id, free channels only), the iptv-org list ("iptvOrg" id)
       and the radio-browser.info directory ("radio" name regex);
    If a stream offers several qualities, the highest-resolution one is used.
  Any channel without a logo gets one: the official logo from persianagroup.tv /
  iptv-org if available (resized to 512x512), otherwise a text placeholder.
    3. if a replacement responds, saves it to channels.json and uses it;
    4. if nothing works, the channel is LEFT OUT of My_Playlist.m3u.
  channels.json always keeps every channel, so a dropped channel comes back
  automatically on a later run once its link works again.

  If anything changed, it commits and pushes (unless -NoPush).

  Usage:  update_links.bat            (double-click; pauses at the end)
          update_links.bat /auto      (no pause, for Task Scheduler)
          update_links.bat /nopush    (update files only, no commit/push)
#>
param([switch]$NoPush)

$ErrorActionPreference = 'Stop'
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12

$Root      = Split-Path -Parent $MyInvocation.MyCommand.Path
$Master    = Join-Path $Root 'channels.json'
$Playlist  = Join-Path $Root 'My_Playlist.m3u'
$LogoBase  = 'https://raw.githubusercontent.com/offlinemediacenter/IPTV/refs/heads/main/Logos/'
$LogoDir   = Join-Path $Root 'Logos'
$StreamDir  = Join-Path $Root 'Streams'
$StreamBase = 'https://raw.githubusercontent.com/offlinemediacenter/IPTV/refs/heads/main/Streams/'
Add-Type -AssemblyName System.Drawing
$UA        = 'VLC/3.0.20 LibVLC/3.0.20'
$Utf8NoBom = New-Object Text.UTF8Encoding $false

function Test-Stream([string]$Url) {
    $script:LastStreamKey = $null
    if (-not $Url) { return $false }
    $req = $null
    try {
        $req = [Net.HttpWebRequest]::Create($Url)
        $req.UserAgent = $UA
        $req.Timeout = 15000
        $req.ReadWriteTimeout = 15000
        $req.AddRange(0, 2047)
        $resp = $req.GetResponse()
        $code = [int]$resp.StatusCode
        # Where the stream really ends up (after redirects), used to spot duplicate
        # channels. Query strings (tokens) are ignored, and a numbered load-balancer
        # node such as "n0a." / "s5." / "stream-163." is dropped from the host.
        $h = $resp.ResponseUri.Host.ToLower() -replace '^[a-z]{0,6}-?\d+[a-z]?\d*\.(?=[^.]+\.[^.]+)', ''
        $script:LastStreamKey = $h + $resp.ResponseUri.AbsolutePath.TrimEnd('/').ToLower()
        return ($code -ge 200 -and $code -lt 300)
    } catch {
        return $false
    } finally {
        if ($req) { $req.Abort() }   # don't wait on endless radio streams
    }
}

function Get-Text([string]$Url) {
    try {
        $wc = New-Object Net.WebClient
        $wc.Encoding = [Text.Encoding]::UTF8
        $wc.Headers.Add('User-Agent', $UA)
        return $wc.DownloadString($Url)
    } catch { return $null }
}

# Fetch a text resource. Returns @{ Text; Uri } (Uri = final URL after redirects) or $null.
function Get-TextAndUri([string]$Url) {
    try {
        $req = [Net.HttpWebRequest]::Create($Url)
        $req.UserAgent = $UA; $req.Timeout = 15000; $req.ReadWriteTimeout = 15000
        $resp = $req.GetResponse()
        $sr = New-Object IO.StreamReader ($resp.GetResponseStream(), [Text.Encoding]::UTF8)
        $text = $sr.ReadToEnd(); $sr.Close()
        $final = $resp.ResponseUri; $resp.Close()
        return @{ Text = $text; Uri = $final }
    } catch { return $null }
}

# If $Url is an HLS master playlist with several qualities, pick the highest one.
#  - Normal case: returns the URL of the top variant.
#  - Audio in a separate track: the bare video variant would be silent, so instead a
#    small "pinned" playlist (top variant + audio track) is written to Streams/ and
#    its name is left in $script:LastPinned; $Url itself is returned unchanged.
#    Skipped when the links carry tokens (a pinned copy would expire).
function Select-BestQuality([string]$Url, [string]$Name) {
    $script:LastPinned = $null
    if ($Url -notmatch '\.m3u8') { return $Url }
    $r = Get-TextAndUri $Url
    if (-not $r -or $r.Text -notmatch '#EXT-X-STREAM-INF') { return $Url }
    $text = $r.Text; $base = $r.Uri
    $lines = $text -split "`r?`n"
    # Rank by resolution first (some servers declare bogus bandwidths), then bandwidth.
    $variants = @()
    for ($i = 0; $i -lt $lines.Count - 1; $i++) {
        if ($lines[$i] -match '^#EXT-X-STREAM-INF:(.*)$') {
            $attrs = $Matches[1]
            $bw = 0L; $px = 0L; $res = ''
            if ($attrs -match '\bBANDWIDTH=(\d+)') { $bw = [long]$Matches[1] }
            if ($attrs -match '\bRESOLUTION=(\d+)x(\d+)') { $px = [long]$Matches[1] * [long]$Matches[2]; $res = "$($Matches[1])x$($Matches[2])" }
            $uri = $lines[$i + 1].Trim()
            if ($uri -and -not $uri.StartsWith('#')) {
                $variants += New-Object PSObject -Property @{ Uri = $uri; Bw = $bw; Px = $px; Res = $res; Attrs = $attrs }
            }
        }
    }
    $sorted = @($variants | Sort-Object -Property @{ e = 'Px'; Descending = $true }, @{ e = 'Bw'; Descending = $true })
    $separateAudio = $text -match '#EXT-X-MEDIA:[^\r\n]*TYPE=AUDIO[^\r\n]*URI='

    if ($separateAudio) {
        $hasTokens = $base.Query -or ($variants | Where-Object { $_.Uri -match '\?' }) -or ($text -match 'URI="[^"]*\?')
        if ($hasTokens) {
            Write-Host "  QUALITY  separate audio track, links carry tokens - keeping master playlist"
            return $Url
        }
    }

    # Try best first; fall back to the next one if a variant doesn't respond.
    foreach ($v in $sorted) {
        $abs = (New-Object Uri ($base, $v.Uri)).AbsoluteUri
        if (-not (Test-Stream $abs)) { continue }
        $label = if ($v.Res) { $v.Res } else { '{0:N1} Mbps' -f ($v.Bw / 1e6) }
        if (-not $separateAudio) {
            Write-Host "  QUALITY  picked top variant ($label)"
            return $abs
        }
        # Pinned playlist: header, all EXT-X-MEDIA renditions (absolute URIs), top variant only.
        $out = @('#EXTM3U')
        foreach ($l in $lines) { if ($l -match '^#EXT-X-(VERSION|INDEPENDENT-SEGMENTS)') { $out += $l.Trim() } }
        $toAbs = [Text.RegularExpressions.MatchEvaluator] { param($m) 'URI="' + (New-Object Uri ($base, $m.Groups[1].Value)).AbsoluteUri + '"' }
        foreach ($l in $lines) { if ($l -match '^#EXT-X-MEDIA:') { $out += [regex]::Replace($l.Trim(), 'URI="([^"]+)"', $toAbs) } }
        $out += '#EXT-X-STREAM-INF:' + $v.Attrs
        $out += $abs
        if (-not (Test-Path -LiteralPath $StreamDir)) { $null = New-Item -ItemType Directory -Path $StreamDir }
        $file = ($Name -replace '[^A-Za-z0-9]', '') + '.m3u8'
        [IO.File]::WriteAllText((Join-Path $StreamDir $file), (($out -join "`n") + "`n"), $Utf8NoBom)
        $script:LastPinned = $file
        Write-Host "  QUALITY  pinned top variant ($label) + separate audio -> Streams/$file"
        return $Url
    }
    return $Url
}

function Get-PersianaList {
    if ($null -eq $script:PersianaChannels) {
        try {
            $json = Get-Text 'https://persianagroup.tv/api/v1/channels'
            $script:PersianaChannels = @((ConvertFrom-Json $json).channels)
        } catch {
            Write-Host "  (persianagroup.tv lookup failed: $($_.Exception.Message))"
            $script:PersianaChannels = @()
        }
    }
    return $script:PersianaChannels
}

function Get-PersianaCandidates([string]$SiteId) {
    $null = Get-PersianaList
    # Only free channels: anything marked requires_plus (subscription) is skipped.
    return @($script:PersianaChannels |
             Where-Object { $_.id -eq $SiteId -and -not $_.requires_plus -and $_.hls_url } |
             ForEach-Object { $_.hls_url })
}

# ---------------------------------------------------------------- logos
# Find the area of $Bmp that differs from its corner colour (i.e. trim plain margins).
function Get-ContentRect($Bmp) {
    $bg = $Bmp.GetPixel(0, 0)
    $step = [Math]::Max(1, [int]([Math]::Max($Bmp.Width, $Bmp.Height) / 400))
    $minX = $Bmp.Width; $minY = $Bmp.Height; $maxX = -1; $maxY = -1
    for ($y = 0; $y -lt $Bmp.Height; $y += $step) {
        for ($x = 0; $x -lt $Bmp.Width; $x += $step) {
            $p = $Bmp.GetPixel($x, $y)
            $diff = [Math]::Abs($p.R - $bg.R) + [Math]::Abs($p.G - $bg.G) + [Math]::Abs($p.B - $bg.B) + [Math]::Abs($p.A - $bg.A)
            if ($diff -gt 40) {
                if ($x -lt $minX) { $minX = $x }; if ($x -gt $maxX) { $maxX = $x }
                if ($y -lt $minY) { $minY = $y }; if ($y -gt $maxY) { $maxY = $y }
            }
        }
    }
    if ($maxX -lt 0) { return New-Object Drawing.Rectangle 0, 0, $Bmp.Width, $Bmp.Height }
    $minX = [Math]::Max(0, $minX - $step); $minY = [Math]::Max(0, $minY - $step)
    $maxX = [Math]::Min($Bmp.Width - 1, $maxX + $step); $maxY = [Math]::Min($Bmp.Height - 1, $maxY + $step)
    return New-Object Drawing.Rectangle $minX, $minY, ($maxX - $minX + 1), ($maxY - $minY + 1)
}

# Draw $Image (plain margins trimmed) centred on a transparent 512x512 canvas, save as PNG.
function Save-Logo512($Image, [string]$Path) {
    $src = New-Object Drawing.Bitmap $Image
    $rect = Get-ContentRect $src
    $box = 472                                   # leave a small border inside 512
    $s = [Math]::Min($box / $rect.Width, $box / $rect.Height)
    $w = [int]($rect.Width * $s); $h = [int]($rect.Height * $s)
    $bmp = New-Object Drawing.Bitmap 512, 512
    $g = [Drawing.Graphics]::FromImage($bmp)
    $g.Clear([Drawing.Color]::Transparent)
    $g.InterpolationMode = 'HighQualityBicubic'; $g.SmoothingMode = 'HighQuality'; $g.PixelOffsetMode = 'HighQuality'
    $dest = New-Object Drawing.Rectangle ([int]((512 - $w) / 2)), ([int]((512 - $h) / 2)), $w, $h
    $g.DrawImage($src, $dest, $rect, [Drawing.GraphicsUnit]::Pixel)
    $src.Dispose()
    $g.Dispose(); $bmp.Save($Path, [Drawing.Imaging.ImageFormat]::Png); $bmp.Dispose()
}

# Download an image and save it as a 512x512 PNG. Returns $true on success.
function Save-LogoFromUrl([string]$Url, [string]$Path) {
    try {
        $wc = New-Object Net.WebClient
        $wc.Headers.Add('User-Agent', 'Mozilla/5.0')
        $bytes = $wc.DownloadData($Url)
        $ms = New-Object IO.MemoryStream (, $bytes)
        $img = [Drawing.Image]::FromStream($ms)
        if ($img.Width -lt 64 -or $img.Height -lt 64) { $img.Dispose(); return $false }   # tiny favicon: would be blurry
        Save-Logo512 $img $Path
        $img.Dispose(); $ms.Dispose()
        return $true
    } catch { return $false }   # unsupported format (e.g. SVG) or download error
}

# Placeholder: channel name in white on a coloured rounded square.
function Save-TextLogo([string]$Name, [string]$Path) {
    $palette = '#8E2430', '#6B4226', '#1F2A44', '#B8860B', '#5A1E6E', '#0F5E6E', '#C0392B', '#2E86C1', '#1E8449', '#7D3C98'
    $sum = 0; foreach ($c in $Name.ToCharArray()) { $sum += [int]$c }
    $color = [Drawing.ColorTranslator]::FromHtml($palette[$sum % $palette.Count])
    $text = $Name.ToUpper()
    if ($text.Length -gt 6 -and $text.Contains(' ')) {      # break at the space nearest the middle
        $mid = $text.Length / 2; $best = -1
        for ($i = 0; $i -lt $text.Length; $i++) {
            if ($text[$i] -eq ' ' -and ($best -lt 0 -or [Math]::Abs($i - $mid) -lt [Math]::Abs($best - $mid))) { $best = $i }
        }
        $text = $text.Substring(0, $best) + "`n" + $text.Substring($best + 1)
    }
    $bmp = New-Object Drawing.Bitmap 512, 512
    $g = [Drawing.Graphics]::FromImage($bmp)
    $g.SmoothingMode = 'AntiAlias'; $g.TextRenderingHint = 'AntiAliasGridFit'
    $g.Clear([Drawing.Color]::Transparent)
    $r = 72; $p = New-Object Drawing.Drawing2D.GraphicsPath
    $p.AddArc(16, 16, $r, $r, 180, 90); $p.AddArc(496 - $r, 16, $r, $r, 270, 90)
    $p.AddArc(496 - $r, 496 - $r, $r, $r, 0, 90); $p.AddArc(16, 496 - $r, $r, $r, 90, 90); $p.CloseFigure()
    $g.FillPath((New-Object Drawing.SolidBrush $color), $p)
    $fmt = New-Object Drawing.StringFormat; $fmt.Alignment = 'Center'; $fmt.LineAlignment = 'Center'
    $size = 150
    do {
        $font = New-Object Drawing.Font('Segoe UI', $size, [Drawing.FontStyle]::Bold, [Drawing.GraphicsUnit]::Pixel)
        $m = $g.MeasureString($text, $font); $size -= 4
    } while (($m.Width -gt 420 -or $m.Height -gt 400) -and $size -gt 24)
    $g.DrawString($text, $font, [Drawing.Brushes]::White, (New-Object Drawing.RectangleF 16, 16, 480, 480), $fmt)
    $g.Dispose(); $bmp.Save($Path, [Drawing.Imaging.ImageFormat]::Png); $bmp.Dispose()
}

# Give a channel a logo if it has none (or its file is missing).
# Official logo from persianagroup.tv / iptv-org first, text placeholder otherwise.
function Set-MissingLogo($Ch) {
    $has = $Ch.PSObject.Properties['logo'] -and $Ch.logo
    if ($has -and (Test-Path -LiteralPath (Join-Path $LogoDir $Ch.logo))) { return $false }

    if ($has) { $file = $Ch.logo }
    else {
        $base = if ($Ch.PSObject.Properties['iptvOrg'] -and $Ch.iptvOrg) { $Ch.iptvOrg -replace '\.[A-Za-z]+$', '' } else { $Ch.name }
        $file = 'IPTV_' + ($base -replace '[^A-Za-z0-9]', '') + '.png'
    }
    $path = Join-Path $LogoDir $file

    $sources = @()
    if ($Ch.PSObject.Properties['logoSrc'] -and $Ch.logoSrc) { $sources += $Ch.logoSrc }
    if ($Ch.PSObject.Properties['persiana'] -and $Ch.persiana) {
        $sources += @(Get-PersianaList | Where-Object { $_.id -eq $Ch.persiana -and $_.logo_url } |
                      ForEach-Object { 'https://persianagroup.tv/' + $_.logo_url.TrimStart('/') })
    }
    if ($Ch.PSObject.Properties['iptvOrg'] -and $Ch.iptvOrg) {
        $pattern = 'tvg-id="' + [regex]::Escape($Ch.iptvOrg) + '@'
        foreach ($l in $script:IptvLines) {
            if ($l.StartsWith('#EXTINF') -and $l -match $pattern -and $l -match 'tvg-logo="([^"]+)"') { $sources += $Matches[1] }
        }
    }

    $how = $null
    foreach ($s in ($sources | Select-Object -Unique)) {
        if (Save-LogoFromUrl $s $path) { $how = "downloaded"; break }
    }
    if (-not $how) { Save-TextLogo $Ch.name $path; $how = "generated text placeholder" }

    $Ch | Add-Member -NotePropertyName logo -NotePropertyValue $file -Force
    Write-Host "  LOGO     [$($Ch.name)] $how -> Logos/$file"
    return $true
}

function Get-IptvOrgCandidates([string]$TvgId) {
    $pattern = 'tvg-id="' + [regex]::Escape($TvgId) + '@'
    $out = @()
    for ($i = 0; $i -lt $script:IptvLines.Count - 1; $i++) {
        if ($script:IptvLines[$i].StartsWith('#EXTINF') -and $script:IptvLines[$i] -match $pattern) {
            for ($j = $i + 1; $j -lt $script:IptvLines.Count; $j++) {
                $u = $script:IptvLines[$j].Trim()
                if ($u -and -not $u.StartsWith('#')) { $out += $u; break }
            }
        }
    }
    return $out
}

# "radio" is a station name (or regex). The text before the first regex symbol is used
# as the radio-browser search term; results are then filtered with the full pattern.
function Get-RadioCandidates([string]$Pattern) {
    $term = ($Pattern -split '[\.\*\+\?\(\)\[\]\|\\^$]')[0].Trim()
    if (-not $term) { return @() }
    if (-not $script:RadioStations.ContainsKey($term)) {
        try {
            $api = 'https://de1.api.radio-browser.info/json/stations/search?hidebroken=true&limit=200&name=' + [Uri]::EscapeDataString($term)
            $script:RadioStations[$term] = @(Invoke-RestMethod -Uri $api -UserAgent 'IPTV-playlist-updater/1.0' -TimeoutSec 30)
        } catch {
            Write-Host "  (radio-browser lookup failed: $($_.Exception.Message))"
            $script:RadioStations[$term] = @()
        }
    }
    # Prefer the station's base URL: url_resolved often carries short-lived tokens.
    $out = @()
    foreach ($s in ($script:RadioStations[$term] | Where-Object { $_.name -match $Pattern })) {
        if ($s.url) { $out += $s.url }
        if ($s.url_resolved) { $out += $s.url_resolved }
    }
    return $out
}

function ConvertTo-MasterJson($Channels) {
    $keys = 'name', 'id', 'group', 'logo', 'logoSrc', 'url', 'iptvOrg', 'radio', 'persiana'
    $esc  = { param($s) ([string]$s).Replace('\', '\\').Replace('"', '\"') }
    $blocks = foreach ($c in $Channels) {
        $fields = foreach ($k in $keys) {
            if ($c.PSObject.Properties[$k] -and $c.$k) { '    "{0}": "{1}"' -f $k, (& $esc $c.$k) }
        }
        "  {`r`n" + ($fields -join ",`r`n") + "`r`n  }"
    }
    return "[`r`n" + ($blocks -join ",`r`n") + "`r`n]`r`n"
}

# ---------------------------------------------------------------- load
# PS 5.1 pipes a JSON array as ONE object, so unroll it explicitly.
$channels = @()
foreach ($c in (ConvertFrom-Json ([IO.File]::ReadAllText($Master, [Text.Encoding]::UTF8)))) { $channels += $c }
Write-Host "Master list: $($channels.Count) channels"

Write-Host "Downloading iptv-org channel list..."
try {
    # WebClient returns text; Invoke-WebRequest in PS 5.1 returns .m3u as raw bytes.
    $wc = New-Object Net.WebClient
    $wc.Encoding = [Text.Encoding]::UTF8
    $wc.Headers.Add('User-Agent', 'IPTV-playlist-updater/1.0')
    $script:IptvLines = $wc.DownloadString('https://iptv-org.github.io/iptv/index.m3u') -split "`r?`n"
} catch {
    Write-Host "  could not download iptv-org list: $($_.Exception.Message)"
    $script:IptvLines = @()
}
$script:RadioStations    = @{}
$script:PersianaChannels = $null

# ---------------------------------------------------------------- check
$working       = @()
$dropped       = @()
$masterChanged = $false

$streamOwner = @{}     # final stream path -> first channel that uses it
$duplicates  = @()
$playUrl     = @{}     # channel name -> pinned playlist URL (used in the M3U instead of url)

foreach ($ch in $channels) {
    Write-Host ""
    Write-Host "[$($ch.name)]"
    if (Test-Stream $ch.url) {
        Write-Host "  OK       $($ch.url)"
        $key = $script:LastStreamKey
        if ($key) {
            if ($streamOwner.ContainsKey($key)) {
                Write-Host "  WARNING  same stream as [$($streamOwner[$key])] - duplicate?"
                $duplicates += "$($ch.name) = $($streamOwner[$key])"
            } else { $streamOwner[$key] = $ch.name }
        }
        $best = Select-BestQuality $ch.url $ch.name
        if ($script:LastPinned) { $playUrl[$ch.name] = $script:LastPinned }
        if ($best -ne $ch.url) { $ch.url = $best; $masterChanged = $true; Write-Host "  UPDATED  $best" }
        $working += $ch
        continue
    }
    Write-Host "  BROKEN   $($ch.url)"

    $candidates = @()
    if ($ch.PSObject.Properties['persiana'] -and $ch.persiana) { $candidates += Get-PersianaCandidates $ch.persiana }
    if ($ch.PSObject.Properties['iptvOrg'] -and $ch.iptvOrg) { $candidates += Get-IptvOrgCandidates $ch.iptvOrg }
    if ($ch.PSObject.Properties['radio']   -and $ch.radio)   { $candidates += Get-RadioCandidates  $ch.radio }
    $candidates = @($candidates | Where-Object { $_ -and $_ -ne $ch.url } | Select-Object -Unique)

    $found = $null
    foreach ($c in $candidates) {
        if (Test-Stream $c) { $found = $c; break }
        Write-Host "  tried    $c (not responding)"
    }
    if ($found) {
        $found = Select-BestQuality $found $ch.name
        if ($script:LastPinned) { $playUrl[$ch.name] = $script:LastPinned }
        Write-Host "  UPDATED  $found"
        $ch.url = $found
        $masterChanged = $true
        $working += $ch
    } else {
        Write-Host "  DROPPED  no working link found - left out of the playlist"
        $dropped += $ch.name
    }
}

Write-Host ""
if ($working.Count -eq 0) {
    Write-Host "No channel responded at all - probably a network problem. Nothing written."
    exit 1
}

# ---------------------------------------------------------------- logos
$newLogos = @()
foreach ($ch in $channels) {
    if (Set-MissingLogo $ch) { $newLogos += 'Logos/' + $ch.logo; $masterChanged = $true }
}

# ---------------------------------------------------------------- write
$m3u = @('#EXTM3U')
foreach ($ch in $working) {
    $logo = if ($ch.PSObject.Properties['logo'] -and $ch.logo) { $LogoBase + $ch.logo } else { '' }
    $m3u += '#EXTINF:-1 tvg-ID="{0}" tvg-name="{1}" tvg-logo="{2}" group-title="{3}",{4}' -f `
            $ch.id, $ch.name, $logo, $ch.group, $ch.name
    $m3u += if ($playUrl.ContainsKey($ch.name)) { $StreamBase + $playUrl[$ch.name] } else { $ch.url }
}

# Remove pinned playlists no longer in use.
if (Test-Path -LiteralPath $StreamDir) {
    foreach ($f in Get-ChildItem -LiteralPath $StreamDir -Filter '*.m3u8') {
        if ($playUrl.Values -notcontains $f.Name) { Remove-Item -LiteralPath $f.FullName; Write-Host "  removed unused Streams/$($f.Name)" }
    }
}
$newM3u = ($m3u -join "`r`n") + "`r`n"
$oldM3u = if (Test-Path -LiteralPath $Playlist) { [IO.File]::ReadAllText($Playlist) } else { '' }

$filesChanged = @()
if ($newM3u -ne $oldM3u) {
    [IO.File]::WriteAllText($Playlist, $newM3u, $Utf8NoBom)
    $filesChanged += 'My_Playlist.m3u'
}
if ($masterChanged) {
    [IO.File]::WriteAllText($Master, (ConvertTo-MasterJson $channels), $Utf8NoBom)
    $filesChanged += 'channels.json'
}

Write-Host "Playlist: $($working.Count) of $($channels.Count) channels working."
if ($dropped.Count) { Write-Host "Left out:  $($dropped -join ', ')" }
if ($duplicates.Count) { Write-Host "Possible duplicates (check and remove one from channels.json): $($duplicates -join '; ')" }
if ($filesChanged.Count) { Write-Host "Updated:  $($filesChanged -join ', ')" }

if ($NoPush) { Write-Host "-NoPush given: not committing."; exit 0 }

# Commit whatever differs from the last commit (also catches edits left by a -NoPush run).
$ErrorActionPreference = 'Continue'
# Logos/ is included so new or replaced logo files are published too.
$paths = @('My_Playlist.m3u', 'channels.json', 'Logos')
$streamFiles = @(if (Test-Path -LiteralPath $StreamDir) { Get-ChildItem -LiteralPath $StreamDir -File })
if ($streamFiles.Count -or (git -C "$Root" ls-files -- Streams)) { $paths += 'Streams' }   # empty pathspec would error
git -C "$Root" add -A -- $paths
git -C "$Root" diff --cached --quiet -- $paths
if ($LASTEXITCODE -eq 0) { Write-Host "Nothing new to commit."; exit 0 }

$msg = "Auto-update playlist: $($working.Count)/$($channels.Count) channels working"
if ($dropped.Count) { $msg += " (left out: $($dropped -join ', '))" }
if ($newLogos.Count) { $msg += "; new logos: $($newLogos.Count)" }

git -C "$Root" commit -q -m $msg
if ($LASTEXITCODE -ne 0) { Write-Host "git commit failed."; exit 1 }
git -C "$Root" push -q origin main
if ($LASTEXITCODE -ne 0) { Write-Host "git push failed."; exit 1 }
Write-Host "Committed and pushed."
