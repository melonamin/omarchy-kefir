# KEF Speakers — Omarchy bar widget

Control KEF wireless speakers (LSX II, LS50 Wireless II, LS60) from the
Omarchy bar. Talks directly to the speaker's KEF Connect HTTP API on the
local network — no daemon, no CLI dependency. Same protocol as
[SwiftKEF](https://github.com/melonamin/SwiftKEF) /
[Kefir](https://github.com/melonamin/Kefir) /
[KefirCLI](https://github.com/amebalabs/KefirCLI).

## Features

- Bar pill showing speaker state (off/standby, on, muted), with tooltip
- Popup panel: power switch, volume slider with mute, input source picker,
  now-playing with play/pause/next/previous for Wi-Fi and Bluetooth sources
- Scroll the bar icon to change volume (with OSD), right-click to mute,
  middle-click to play/pause
- Panel keys: `h`/`l` volume, `m` mute, `Enter`/`Space` play/pause, `Esc` close

## Install

```bash
# Already on this machine under ~/.config/omarchy/plugins/melonamin.kef
omarchy plugin enable melonamin.kef
omarchy bar set melonamin.kef host <speaker-ip>
```

Find the speaker's IP in the KEF Connect app, your router, or via
`avahi-browse -rt _airplay._tcp` (KEF speakers advertise AirPlay).

## IPC

For Hyprland keybindings:

```bash
omarchy-shell melonamin.kef toggle      # open/close the panel
omarchy-shell melonamin.kef volumeUp    # +5
omarchy-shell melonamin.kef volumeDown  # -5
omarchy-shell melonamin.kef mute
omarchy-shell melonamin.kef playPause
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
