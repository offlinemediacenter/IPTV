<#
  update_links.ps1 - rebuild My_Playlist.m3u from the master list in channels.json.

  No login, no credentials. For every channel in channels.json it:
    1. tests the channel's URL; if it plays, the channel goes in the playlist;
    2. otherwise looks for a replacement in persianagroup.tv's public channel list
       ("persiana" site id, free channels only), the iptv-org list ("iptvOrg" id)
       and the radio-browser.info directory ("radio" name regex);
    If a stream offers several qualities, the highest-bandwidth one is used.
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
$UA        = 'VLC/3.0.20 LibVLC/3.0.20'
$Utf8NoBom = New-Object Text.UTF8Encoding $false

function Test-Stream([string]$Url) {
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

# If $Url is an HLS master playlist with several qualities, return the URL of the
# highest-bandwidth variant (if it responds); otherwise return $Url unchanged.
function Select-BestQuality([string]$Url) {
    if ($Url -notmatch '\.m3u8') { return $Url }
    $text = Get-Text $Url
    if (-not $text -or $text -notmatch '#EXT-X-STREAM-INF') { return $Url }
    # Audio (or subtitles) delivered as separate renditions: a single video variant
    # would play silently, so keep the master and let the player choose.
    if ($text -match '#EXT-X-MEDIA:[^\r\n]*TYPE=AUDIO[^\r\n]*URI=') {
        Write-Host "  QUALITY  separate audio track - keeping master playlist"
        return $Url
    }
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
                $variants += New-Object PSObject -Property @{ Uri = $uri; Bw = $bw; Px = $px; Res = $res }
            }
        }
    }
    # Try best first; fall back to the next one if a variant doesn't respond.
    foreach ($v in ($variants | Sort-Object -Property @{ e = 'Px'; Descending = $true }, @{ e = 'Bw'; Descending = $true })) {
        $abs = (New-Object Uri ((New-Object Uri $Url), $v.Uri)).AbsoluteUri
        if (Test-Stream $abs) {
            $label = if ($v.Res) { $v.Res } else { '{0:N1} Mbps' -f ($v.Bw / 1e6) }
            Write-Host "  QUALITY  picked top variant ($label)"
            return $abs
        }
    }
    return $Url
}

function Get-PersianaCandidates([string]$SiteId) {
    if ($null -eq $script:PersianaChannels) {
        try {
            $json = Get-Text 'https://persianagroup.tv/api/v1/channels'
            $script:PersianaChannels = @((ConvertFrom-Json $json).channels)
        } catch {
            Write-Host "  (persianagroup.tv lookup failed: $($_.Exception.Message))"
            $script:PersianaChannels = @()
        }
    }
    # Only free channels: anything marked requires_plus (subscription) is skipped.
    return @($script:PersianaChannels |
             Where-Object { $_.id -eq $SiteId -and -not $_.requires_plus -and $_.hls_url } |
             ForEach-Object { $_.hls_url })
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

function Get-RadioCandidates([string]$Pattern) {
    if ($null -eq $script:RadioStations) {
        try {
            $api = 'https://de1.api.radio-browser.info/json/stations/search?name=PMC&limit=200'
            $script:RadioStations = @(Invoke-RestMethod -Uri $api -UserAgent 'IPTV-playlist-updater/1.0' -TimeoutSec 30)
        } catch {
            Write-Host "  (radio-browser lookup failed: $($_.Exception.Message))"
            $script:RadioStations = @()
        }
    }
    return @($script:RadioStations | Where-Object { $_.name -match $Pattern } |
             ForEach-Object { if ($_.url_resolved) { $_.url_resolved } else { $_.url } })
}

function ConvertTo-MasterJson($Channels) {
    $keys = 'name', 'id', 'group', 'logo', 'url', 'iptvOrg', 'radio', 'persiana'
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
$script:RadioStations    = $null
$script:PersianaChannels = $null

# ---------------------------------------------------------------- check
$working       = @()
$dropped       = @()
$masterChanged = $false

foreach ($ch in $channels) {
    Write-Host ""
    Write-Host "[$($ch.name)]"
    if (Test-Stream $ch.url) {
        Write-Host "  OK       $($ch.url)"
        $best = Select-BestQuality $ch.url
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
        $found = Select-BestQuality $found
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

# ---------------------------------------------------------------- write
$m3u = @('#EXTM3U')
foreach ($ch in $working) {
    $logo = if ($ch.PSObject.Properties['logo'] -and $ch.logo) { $LogoBase + $ch.logo } else { '' }
    $m3u += '#EXTINF:-1 tvg-ID="{0}" tvg-name="{1}" tvg-logo="{2}" group-title="{3}",{4}' -f `
            $ch.id, $ch.name, $logo, $ch.group, $ch.name
    $m3u += $ch.url
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
if ($filesChanged.Count) { Write-Host "Updated:  $($filesChanged -join ', ')" }

if ($NoPush) { Write-Host "-NoPush given: not committing."; exit 0 }

# Commit whatever differs from the last commit (also catches edits left by a -NoPush run).
$ErrorActionPreference = 'Continue'
git -C "$Root" add -- My_Playlist.m3u channels.json
git -C "$Root" diff --cached --quiet -- My_Playlist.m3u channels.json
if ($LASTEXITCODE -eq 0) { Write-Host "Nothing new to commit."; exit 0 }

$msg = "Auto-update playlist: $($working.Count)/$($channels.Count) channels working"
if ($dropped.Count) { $msg += " (left out: $($dropped -join ', '))" }

git -C "$Root" commit -q -m $msg
if ($LASTEXITCODE -ne 0) { Write-Host "git commit failed."; exit 1 }
git -C "$Root" push -q origin main
if ($LASTEXITCODE -ne 0) { Write-Host "git push failed."; exit 1 }
Write-Host "Committed and pushed."
