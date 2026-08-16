# Kefir for Omarchy

Control KEF wireless speakers (LSX II, LS50 Wireless II, LS60) from the
Omarchy bar. Talks directly to the speaker's KEF Connect HTTP API on the
local network — no daemon, no CLI dependency. Same protocol as
[SwiftKEF](https://github.com/melonamin/SwiftKEF) /
[Kefir](https://github.com/melonamin/Kefir) /
[KefirCLI](https://github.com/amebalabs/KefirCLI).

## Features

- Bar pill showing speaker state (off/standby, on, muted), with tooltip
- Popup panel: power switch, volume slider with mute, input source picker,
  and a now-playing card with album art, track/artist/album, a progress bar,
  and play/pause/next/previous
- Transport buttons follow the speaker's own `controls` capability report,
  so they enable only on sources that support them (streaming, not
  passthrough); passthrough pseudo-tracks ("COAX", "OPT", ...) are filtered
  out of the card
- Scroll the bar icon to change volume (with OSD), right-click to mute,
  middle-click to play/pause
- Panel keys: `h`/`l` volume, `m` mute, `Enter`/`Space` play/pause, `Esc` close

## Install

```bash
omarchy plugin add https://github.com/melonamin/omarchy-kefir.git --enable
omarchy bar set melonamin.kefir host <speaker-ip>
```

Find the speaker's IP in the KEF Connect app, your router, or via
`avahi-browse -rt _airplay._tcp` (KEF speakers advertise AirPlay).

## IPC

For Hyprland keybindings:

```bash
omarchy-shell melonamin.kefir toggle      # open/close the panel
omarchy-shell melonamin.kefir volumeUp    # +5
omarchy-shell melonamin.kefir volumeDown  # -5
omarchy-shell melonamin.kefir mute
omarchy-shell melonamin.kefir playPause
```

## Notes

- Mute is volume-0 with the previous level remembered, matching Kefir.
- Writes are POSTs with a JSON body; firmware p20.x rejects the older
  query-param setData with 405.
- Selecting a source while in standby powers the speaker on (KEF behavior).

## Tests

```bash
node --test tests/model.test.js        # unit: wire-format parsing/building
tests/integration.sh <speaker-ip>      # live read-only poll against a speaker
```
