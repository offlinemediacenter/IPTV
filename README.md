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

Sources: the broadcasters' own free streams, [persianagroup.tv](https://persianagroup.tv/)
(free channels only; Persiana+ needs a subscription and is not included),
the [iptv-org](https://github.com/iptv-org/iptv) lists (Persian, plus dance/DJ, K-pop
and fashion channels), Vevo's free channels (US and Spain) and
[radio-browser.info](https://www.radio-browser.info/) for radio.

| Group | Channels |
|---|---|
| **News** (7) | BBC Persian, Iran International, IraneFarda TV, IRINN, IRINN 2, National Iranian Congress TV, VoA TV Persian |
| **National** (5) | IRIB 1, IRIB 2, IRIB UHD, Isfahan TV, Tehran TV |
| **Movies & Series** (19) | Persiana Family, Persiana Series, Persiana Cinema, Persiana Korea, Persiana Iranian, Persiana Türkiye, Persiana China, Persiana Latino, Afra Film, Cafe Film, Gold Star, Grand Cinema, iFilm 2, iFilm Persian, Maah TV, Meta Film TV, SL 1, SL 2, Tamasha |
| **Entertainment** (17) | FashionTV+, Persiana Comedy, Persiana Reality, Persiana Podcast, 247 Box TV, 4U TV, FX 1, MBC Persia, Namayesh TV, Nasim, OXIR TV, Shabakeh 7, Tin TV, TV ITN, Arirang TV, FashionTV Secrets, Global Fashion Channel |
| **Music** (26) | Avang TV, Navahang TV, PMC Music, PMC Royale, RJTV, Persiana Music, Persiana Nostalgia, Persiana Folk, Persiana SetMix, Persiana Rap, 4Kurd, AFN TV, High Vision TV, T2 TV, Clubbing TV, Deejay TV, Deluxe Dance, Best of Dance TV, DanceTV Techno Warehouse, Power Dance, Totalmusic Dance, Number 1 Dance, Dance FM, Stingray Today's K-Pop, NEW K-POP, Kpop Mix |
| **Vevo** (19) | Vevo Pop (US), Vevo '70s (US), Vevo '80s (US), Vevo '90s (US), Vevo 2K (US), Vevo 2010s (US), Vevo Hip Hop (US), Vevo True School Hip-Hop (US), Vevo R&B (US), Vevo Rock (US), Vevo Retro Rock (US), Vevo Country (US), Vevo Country Rewind (US), Vevo Latino (US), Vevo Íconos Latinos (US), Vevo Regional Mexicano (US), Vevo Holiday (US), Vevo Pop (Spain), Vevo Latino (Spain) |
| **Documentary** (4) | Persiana Medical, Persiana Docs, Persiana Travel, Persiana Voyage |
| **Kids** (5) | Persiana Junior, Persiana Teen, IRIB Omid, Pooya TV, Pooya TV Plus |
| **Sports** (3) | Persiana Fight, IRIB 3, Varzesh TV |
| **Radio** (16) | PMC Radio (Planeta), PMC Radio (Select), Radio Farda, Iran International Radio, RFI Persian, Radio Faaz, Radio Navahang, Radio Simorgh, Radio Shadi, Persian Vibe Radio, Farsi Frequency, Radio Yar Plus, Radio Yar LA, Iran On Air, Radio Hamrah, Radio ZZA |

## Logos

Channel logos are stored in [`Logos/`](Logos) and referenced from the playlist via raw GitHub URLs.

## Keeping links fresh

`update_links.bat` checks every channel in `channels.json`:

1. If the channel's link works, it goes in the playlist.
2. If not, a replacement is looked up in public sources (persianagroup.tv for Persiana channels,
   [iptv-org](https://github.com/iptv-org/iptv) and
   [radio-browser.info](https://www.radio-browser.info/)). A working one is
   saved to `channels.json` and used.
3. If nothing works, the channel is left out of `My_Playlist.m3u`. It stays in
   `channels.json`, so it returns automatically once a link works again.

Changes are then committed and pushed. It needs no login.

To add a channel, add an entry to `channels.json` (`name`, `id`, `group`,
`url`, plus optional `iptvOrg` tvg-id, `persiana` site id and `radio` name
regex for finding replacements) and run the `.bat`.

**Highest quality.** When a stream offers several qualities, the `.bat` picks the
highest resolution. If the audio comes as a separate track (e.g. MBC Persia), it
writes a small pinned playlist to `Streams/` with just the top video quality plus
the audio, and the playlist points there. Streams whose links carry expiring
tokens (Pluto TV) are left adaptive.

**Logos are automatic.** If a channel has no `logo` (or its file is missing),
the `.bat` downloads the official one (from the optional `logoSrc` link,
persianagroup.tv or iptv-org), trims plain margins,
resizes it to 512x512 and saves it in `Logos/`. If none exists (or it is a tiny
favicon), it makes a text
placeholder with the channel name. To use your own logo instead, put a file in
`Logos/` and set `logo` to its file name (or overwrite the existing file).

```
update_links.bat            run and wait for a key at the end
update_links.bat /auto      no pause (for Windows Task Scheduler)
update_links.bat /nopush    update the file only, don't commit/push
```

## Notes

Streams are public links provided by the broadcasters and may change or go offline without notice.
