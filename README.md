# Visualiser

A music visualiser for macOS that lives in your MacBook's notch.

Visualiser listens to what your Mac is playing and turns it into moving bars, glows and colours taken from the album art. It runs in its own window, as a live wallpaper, or inside a Dynamic-Island-style island around the notch. The island also carries a set of small everyday tools.

<!-- Add screenshots or a short GIF here, e.g. ![The island](docs/island.gif) -->

## Features

**Music**
- Real-time spectrum from your Mac's audio, with a beat pulse and colours from the album art
- Full-window, wallpaper and notch looks
- Now playing for Spotify: artwork, all credited artists, and synced lyrics
- Swipe on the island to skip tracks, scroll to change the volume
- Artwork and lyrics are cached, so they still show offline

**The notch island**
- Volume, brightness, keyboard-language, Caps Lock, headphone-battery and charging animations
- File shelf: drag files onto the notch to keep them handy, then drag them out or AirDrop them
- Clipboard history with dictionary cards for copied words
- Timer with editable presets
- Screenshot catcher, a calendar and weather greeting, and a few playful extras
- Can be pinned open, and stays put on the Lock Screen and while switching Spaces

**Hearing**
- Estimates how loud your headphones are in dB, from the actual audio level and your volume
- Optional calibration that measures your own headphones' volume curve with the built-in microphone
- Daily and weekly listening history, with a weekly sound dose based on the WHO 80 dB / 40 hours guideline

**System**
- CPU, memory, GPU, network and battery dashboard, grouped by app (helpers such as WebKit are counted under their app)
- Quit apps or end runaway processes
- Optional usage log you can export as a summary

## Requirements

- macOS 13 Ventura or later
- A MacBook with a notch for the island; the visualiser window works on any Mac
- Xcode Command Line Tools (`xcode-select --install`) to build
- Spotify desktop app for now-playing details. The visualiser itself reacts to any audio.

It has mostly been tested on a MacBook Air (M2). Other notch sizes, external displays and older macOS versions may have rough edges. Issue reports are welcome.

## Building

```bash
git clone https://github.com/rieldevdex/Visualiser.git
cd Visualiser
./build-app.sh
open Visualiser.app
```

Move `Visualiser.app` to `/Applications` if you want to keep it.

### Keeping permissions between builds

macOS remembers permissions by an app's signature. Without a certificate, each build is signed ad hoc and macOS asks for permissions again. To avoid that, make a signing certificate once:

1. Open **Keychain Access** and choose **Keychain Access › Certificate Assistant › Create a Certificate…**
2. Name it `Visualiser Signing`, set **Identity Type** to *Self Signed Root* and **Certificate Type** to *Code Signing*.
3. Rebuild. `build-app.sh` uses the certificate automatically when it finds it.

## Permissions

| Permission | Why |
|---|---|
| Screen & System Audio Recording | Hears the audio your Mac plays, to draw the visualiser and estimate loudness. Nothing is recorded or saved. |
| Accessibility | Detects the media and brightness keys and shows them in the island |
| Automation (Spotify, Safari) | Reads what's playing; reads open Safari sites only if you turn on the usage log's site option |
| Microphone | Only during headphone calibration, to measure a test tone |
| Calendars | Only if you turn on the calendar greeting |

Everything stays on your Mac. Visualiser has no account, no analytics and no server of its own. It only goes online to fetch artwork, artists, lyrics and weather (see below).

## Third-party services

Visualiser is an unofficial, independent project. It is not affiliated with or endorsed by Apple or Spotify.

- [LRCLIB](https://lrclib.net) for synced lyrics
- [Open-Meteo](https://open-meteo.com) for weather (data under CC BY 4.0)
- Spotify's public oEmbed endpoint and track pages for artwork and the full artist list

Visualiser also uses some private macOS frameworks (for example, to stay above the Lock Screen and read media and sensor information). They make it ineligible for the Mac App Store, and a macOS update may break them. Most have a fallback, so the rest of the app keeps working.

## Hearing disclaimer

The dB reading is an **estimate for awareness only**. It is not a medical device or a safety measurement. Accuracy depends on your headphones, their fit, noise control and calibration, and is typically within a few dB at best. If you're worried about your hearing, see an audiologist.

## Licence

Copyright © 2026 Devony

Visualiser is free software: you can redistribute it and/or modify it under the terms of the GNU General Public License as published by the Free Software Foundation, either version 3 of the License, or (at your option) any later version. See [LICENSE](LICENSE).

This means anyone may use, study, change and share it. Anyone who distributes a modified version must release it under the same licence, with its source code.
