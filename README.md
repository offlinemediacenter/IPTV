# IPTV

A small personal M3U playlist of music and fashion TV channels and radio streams.

## Use it

Add this URL as an M3U playlist in your player (VLC, TiviMate, Kodi, IPTV Smarters, etc.):

```
https://raw.githubusercontent.com/offlinemediacenter/IPTV/main/My_Playlist.m3u
```

## Channels

All channels are defined in [`channels.json`](channels.json) (the master list).
`My_Playlist.m3u` is generated from it and contains only the channels whose
stream currently works, so some of these may be temporarily missing from it.

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

`update_links.bat` checks every channel in `channels.json`:

1. If the channel's link works, it goes in the playlist.
2. If not, a replacement is looked up in public sources
   ([iptv-org](https://github.com/iptv-org/iptv) and
   [radio-browser.info](https://www.radio-browser.info/)). A working one is
   saved to `channels.json` and used.
3. If nothing works, the channel is left out of `My_Playlist.m3u`. It stays in
   `channels.json`, so it returns automatically once a link works again.

Changes are then committed and pushed. It needs no login.

To add a channel, add an entry to `channels.json` (`name`, `id`, `group`,
`logo` file in `Logos/`, `url`, plus optional `iptvOrg` tvg-id and `radio`
name regex for finding replacements) and run the `.bat`.

```
update_links.bat            run and wait for a key at the end
update_links.bat /auto      no pause (for Windows Task Scheduler)
update_links.bat /nopush    update the file only, don't commit/push
```

## Notes

Streams are public links provided by the broadcasters and may change or go offline without notice.
