<img src="assets/icon.png" alt="PracticePad icon" width="120" align="left" />

# PracticePad

A macOS app for practicing music by ear. Load an MP3, slow it down without changing the pitch (or shift the pitch without changing the speed), and loop a tricky passage over and over until you've got it.

Built with SwiftUI and AVFoundation (`AVAudioEngine` + `AVAudioUnitTimePitch`).

<br clear="left" />

![PracticePad screenshot](assets/practice_pad.png)

## Features

- **Speed control** — play from `0.25x` to `2.0x` without affecting pitch, with quick `0.5×` / `0.75×` / `1×` presets.
- **Pitch control** — shift `-12` to `+12` semitones without affecting speed.
- **Waveform view** — see the whole track; click to seek.
- **A-B looping** — gapless looping of a selected region, ideal for drilling a passage.
- **Drag-and-drop** — drop an MP3 onto the window to load it.
- **Recent files** — reopen previously loaded tracks from the File menu.
- **Remembers your setup** — speed, pitch, the last file, and its loop are restored on launch.

## Using the app

### Load a track
- Click **Open MP3** (⌘O), or drag an MP3 file onto the window.
- Reopen something you had before via **File ▸ Open Recent** (with **Clear Menu** to reset the list).
- **Close** unloads the current track and returns to the empty state.

### Play and adjust
- **Play/Pause** with the button or the **spacebar**; **Stop** with the button or ⌘.
- Drag the **Speed** slider (or tap a preset) to slow the track down — pitch stays the same.
- Drag the **Pitch** slider to transpose in semitones — speed stays the same.
- **Reset** (↺, or ⌘R) restores speed to `1.00x` and pitch to `0`.

### Seek
- **Click** anywhere on the waveform, or drag the position slider, to jump to that spot.
- The elapsed / total time is shown under the waveform.

### Loop a section (A-B)
- **Drag across the waveform** to select a region — looping turns on automatically.
- Or use **Set A** / **Set B** to mark the in/out points at the current position, then toggle **Loop**.
- Fine-tune the region by dragging the **A** and **B** handles:
  - Dragging **A** restarts the loop at the new start.
  - Dragging **B** keeps playing from the current spot out to the new end, then loops.
- **Clear** removes the loop.

Behavior notes:
- Seeking **inside** the loop keeps looping; seeking **outside** it plays straight through from the needle.
- **Stop → Play** always restarts the loop from **A**.

### Keyboard shortcuts

| Shortcut | Action |
| --- | --- |
| `⌘O` | Open an MP3 |
| `Space` | Play / Pause |
| `⌘.` | Stop |
| `⌘R` | Reset speed & pitch |

> Menus and shortcuts are only available when running the built `.app` (see below) — not via `swift run`.

## Building from source

Requires macOS 13+ and a Swift toolchain (Xcode or the Swift command-line tools).

### Run during development

```bash
swift build          # verify it compiles
swift run PracticePad
```

`swift run` is fine for quick checks, but it launches a bare executable with no
menu bar — use the packaged app below to test menus and keyboard shortcuts.

### Build an installable app

`scripts/make_app.sh` produces a release build wrapped in a proper, ad-hoc–signed
`.app` bundle. If `assets/icon.png` (1024×1024) exists, it's used as the app icon.

```bash
./scripts/make_app.sh
```

This creates `dist/PracticePad.app`. Install it by dragging it into `/Applications`, or:

```bash
cp -R dist/PracticePad.app /Applications/
```

The bundle is ad-hoc signed, which is fine for your own machine. To run it on
another Mac you'd need a Developer ID signature and notarization.

## Project layout

- `Package.swift` — Swift package manifest.
- `Sources/PracticePad/PracticePadApp.swift` — app entry point and menu commands.
- `Sources/PracticePad/ContentView.swift` — main UI, transport controls, drag-and-drop.
- `Sources/PracticePad/WaveformView.swift` — waveform, seek, and loop handles.
- `Sources/PracticePad/AudioPlayer.swift` — audio engine, seeking, gapless looping, persistence.
- `Sources/PracticePad/FileImporter.swift` — MP3 open panel.
- `scripts/make_app.sh` — packages the `.app` bundle.
