# One-O

Your MacBook desktop folds with the lid.

Close the lid and the desktop tilts away, blurs, and dims from the far edge in, the way a foldable's
screen passes through its moving half. Open it and everything snaps back. One screen, one hinge: One-O.

## How it works

- The lid angle comes from the MacBook's own lid sensor. It reports about ten times a second in
  multi-degree jumps, so One-O carries it forward at the observed velocity between samples and
  renders on a display link at your panel's refresh rate (120 Hz on ProMotion).
- ScreenCaptureKit mirrors the display into a Metal texture.
- **Hold the plane** (default): the desktop keeps its angle in space while the physical panel moves
  around it. Four Gaussian blur levels are blended by height and tilt, the image edge is feathered,
  and once the lid rests for a moment the reference settles back so the real desktop shows again.
  This effect follows jh3y/lid-plane (MIT), see `NOTICE`. Options: hold content angle, perspective
  taper, progressive blur, settle delay, and **Anchor Here** in the menu.
- **Duo fold**: the absolute fold. A fixed front-view projection treats the desktop as a flat plane
  and every pixel shows what a stationary eye would see through the swinging panel; blur and
  darkening grow from the hinge. Follows the study in chuspeeism/iphone-duo (MIT).

Frames stay in memory on your Mac. Nothing is recorded, written to disk, or sent anywhere.
The app has no network code at all.

## Requirements

Apple silicon MacBook with a lid angle sensor, macOS 14 or later.

## Build

```sh
git clone https://github.com/weigibbor/one-o.git
cd one-o
make install      # builds, signs, copies to /Applications
open /Applications/One-O.app
```

Grant Screen Recording when asked, then turn One-O on from the menu bar. The open position is
learned from wherever the lid rests, so the fold starts the moment the lid moves.

## Source map

| File | Purpose |
| --- | --- |
| `Sources/LidAngle.swift` | Reads the lid sensor over IOKit HID |
| `Sources/FoldMotion.swift` | Degrees to fold amount, spring smoothing |
| `Sources/DesktopCapture.swift` | ScreenCaptureKit stream, excluding the overlay |
| `Sources/FoldRenderer.swift` | Metal pipeline, mip chain, per-frame draw |
| `Sources/FoldController.swift` | Sensor, capture, overlay window, state |
| `Sources/OneOApp.swift` | Menu bar app and settings window |
| `Resources/Fold.metal` | The fold projection and progressive blur |

## Website

The landing page and the $1 checkout live in a separate private repository, `weigibbor/one-o-web`.
This repository is the app only.

## Credits

The fixed front-view projection follows the fold study in
[chuspeeism/iphone-duo](https://github.com/chuspeeism/iphone-duo). The idea of folding a Mac
desktop with the lid was first shown by [Noveum/hinge](https://github.com/Noveum/hinge).
One-O is an independent implementation by GE Labs.

## License

MIT. See `LICENSE`.
