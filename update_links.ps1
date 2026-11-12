<#
  update_links.ps1 - refresh PMC stream links in My_Playlist.m3u from public sources.

  No login, no credentials. For each channel below it:
    1. tests the URL currently in the playlist; if it plays, it is kept;
    2. otherwise looks for a replacement in the public iptv-org list
       (and the radio-browser.info directory for radio channels);
    3. uses the first replacement that actually responds.
  If anything changed, it commits and pushes (unless -NoPush).

  Usage:  update_links.bat            (double-click; pauses at the end)
          update_links.bat /auto      (no pause, for Task Scheduler)
          powershell -File update_links.ps1 -NoPush
#>
param([switch]$NoPush)

$ErrorActionPreference = 'Stop'
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12

$Root     = Split-Path -Parent $MyInvocation.MyCommand.Path
$Playlist = Join-Path $Root 'My_Playlist.m3u'
$UA       = 'VLC/3.0.20 LibVLC/3.0.20'

# Channels to maintain. Name = display name after the comma in #EXTINF.
#   IptvOrg : regex matched against iptv-org #EXTINF lines
#   Radio   : regex a radio-browser station name must match (radio channels only)
$Channels = @(
    @{ Name = 'PMC Music';           IptvOrg = 'tvg-id="PMC\.ae@' },
    @{ Name = 'PMC Royale';          IptvOrg = 'tvg-id="PMCRoyale\.ae@' },
    @{ Name = 'PMC Radio (Planeta)'; IptvOrg = ',\s*PMC[^,]*Planeta'; Radio = 'PMC.*Planeta' },
    @{ Name = 'PMC Radio (Select)';  IptvOrg = ',\s*PMC[^,]*Select';  Radio = 'PMC.*Select' }
)

function Test-Stream([string]$Url) {
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

function Get-IptvOrgCandidates([string]$Pattern) {
    $out = @()
    for ($i = 0; $i -lt $script:IptvLines.Count - 1; $i++) {
        $l = $script:IptvLines[$i]
        if ($l.StartsWith('#EXTINF') -and $l -match $Pattern) {
            for ($j = $i + 1; $j -lt $script:IptvLines.Count; $j++) {
                $u = $script:IptvLines[$j].Trim()
                if ($u -and -not $u.StartsWith('#')) { $out += $u; break }
            }
        }
    }
    return $out
}

function Get-RadioCandidates([string]$Pattern) {
    try {
        $api = 'https://de1.api.radio-browser.info/json/stations/search?name=PMC&limit=100'
        $stations = Invoke-RestMethod -Uri $api -UserAgent 'IPTV-playlist-updater/1.0' -TimeoutSec 30
        return @($stations | Where-Object { $_.name -match $Pattern } |
                 ForEach-Object { if ($_.url_resolved) { $_.url_resolved } else { $_.url } })
    } catch {
        Write-Host "  (radio-browser lookup failed: $($_.Exception.Message))"
        return @()
    }
}

Write-Host "Downloading iptv-org channel list..."
try {
    # WebClient returns text; Invoke-WebRequest in PS 5.1 returns .m3u as raw bytes.
    $wc = New-Object Net.WebClient
    $wc.Encoding = [Text.Encoding]::UTF8
    $wc.Headers.Add('User-Agent', 'IPTV-playlist-updater/1.0')
    $raw = $wc.DownloadString('https://iptv-org.github.io/iptv/index.m3u')
    $script:IptvLines = $raw -split "`r?`n"
    Write-Host "  $($script:IptvLines.Count) lines"
} catch {
    Write-Host "  could not download iptv-org list: $($_.Exception.Message)"
    $script:IptvLines = @()
}

$lines   = [System.Collections.Generic.List[string]](Get-Content -LiteralPath $Playlist)
$changed = @()

foreach ($ch in $Channels) {
    Write-Host ""
    Write-Host "[$($ch.Name)]"
    $idx = -1
    for ($i = 0; $i -lt $lines.Count; $i++) {
        if ($lines[$i].StartsWith('#EXTINF') -and $lines[$i].EndsWith(",$($ch.Name)")) { $idx = $i + 1; break }
    }
    if ($idx -lt 0 -or $idx -ge $lines.Count) { Write-Host "  not found in playlist, skipped"; continue }

    $current = $lines[$idx].Trim()
    if (Test-Stream $current) { Write-Host "  OK      $current"; continue }
    Write-Host "  BROKEN  $current"

    $candidates = @()
    if ($ch.IptvOrg) { $candidates += Get-IptvOrgCandidates $ch.IptvOrg }
    if ($ch.Radio)   { $candidates += Get-RadioCandidates  $ch.Radio }
    $candidates = @($candidates | Where-Object { $_ -and $_ -ne $current } | Select-Object -Unique)

    $found = $null
    foreach ($c in $candidates) {
        if (Test-Stream $c) { $found = $c; break }
        Write-Host "  tried   $c (not responding)"
    }
    if ($found) {
        $lines[$idx] = $found
        $changed += $ch.Name
        Write-Host "  UPDATED $found"
    } else {
        Write-Host "  no working free replacement found - left unchanged"
    }
}

Write-Host ""
if ($changed.Count -eq 0) { Write-Host "No changes."; exit 0 }

# Keep Windows (CRLF) line endings, no BOM.
[IO.File]::WriteAllText($Playlist, (($lines -join "`r`n") + "`r`n"), (New-Object Text.UTF8Encoding $false))
Write-Host "Playlist updated: $($changed -join ', ')"

if ($NoPush) { Write-Host "-NoPush given: not committing."; exit 0 }

$ErrorActionPreference = 'Continue'
git -C "$Root" add -- My_Playlist.m3u
git -C "$Root" commit -q -m "Auto-update stream links: $($changed -join ', ')"
if ($LASTEXITCODE -ne 0) { Write-Host "git commit failed."; exit 1 }
git -C "$Root" push -q origin main
if ($LASTEXITCODE -ne 0) { Write-Host "git push failed."; exit 1 }
Write-Host "Committed and pushed."
