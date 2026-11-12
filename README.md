# IPTV

A small personal M3U playlist of music and fashion TV channels and radio streams.

## Use it

Add this URL as an M3U playlist in your player (VLC, TiviMate, Kodi, IPTV Smarters, etc.):

```
https://raw.githubusercontent.com/offlinemediacenter/IPTV/main/My_Playlist.m3u
```

## Channels

| Channel | Group | Type |
|---|---|---|
| Avang TV | Music | TV (HLS) |
| Navahang TV | Music | TV (HLS) |
| PMC Radio (Planeta) | Music | Radio |
| PMC Radio (Select) | Music | Radio |
| PMC Music | Music | TV (HLS) |
| PMC Royale | Music | TV (HLS) |
| RJTV | Music | TV (HLS) |
| FashionTV+ | Fashion | TV (HLS) |

## Logos

Channel logos are stored in [`Logos/`](Logos) and referenced from the playlist via raw GitHub URLs.

## Keeping links fresh

`update_links.ps1` (run via a local `update_links.bat` launcher) checks the PMC streams. Any that stopped working are replaced
from public sources ([iptv-org](https://github.com/iptv-org/iptv) and
[radio-browser.info](https://www.radio-browser.info/)), then committed and pushed.
It needs no login.

```
update_links.bat            run and wait for a key at the end
update_links.bat /auto      no pause (for Windows Task Scheduler)
update_links.bat /nopush    update the file only, don't commit/push
```

## Notes

Streams are public links provided by the broadcasters and may change or go offline without notice.
