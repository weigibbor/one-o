# One-O

Your MacBook desktop folds with the lid.

Close the lid and the desktop tilts away, blurs, and dims from the far edge in, the way a foldable's
screen passes through its moving half. Open it and everything snaps back. One screen, one hinge: One-O.

## How it works

- The lid angle comes from the MacBook's own lid sensor, polled at your display's refresh rate
  (120 Hz on ProMotion, whatever your panel reports otherwise).
- ScreenCaptureKit mirrors the display into a Metal texture. A fragment shader applies a fixed
  front-view projection: the desktop is treated as a flat plane in space and every pixel shows what
  a stationary eye would see through the swinging panel. Blur and darkening grow with distance from
  the hinge.
- A critically damped spring smooths the whole-degree sensor steps at frame rate.

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

Grant Screen Recording when asked, then turn One-O on from the menu bar. Set your usual lid
position with **Set open position** so the fold starts the moment the lid moves.

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

`web/` is the one-o site: Next.js 16, Stripe Checkout at $1, and a download route that hands out the
signed DMG only for a paid Stripe session. Deploy it on Vercel with the project root set to `web`.
Env vars are listed in `web/.env.example`; publish a build with `make dmg` then `npm run publish-dmg`.

## Credits

The fixed front-view projection follows the fold study in
[chuspeeism/iphone-duo](https://github.com/chuspeeism/iphone-duo). The idea of folding a Mac
desktop with the lid was first shown by [Noveum/hinge](https://github.com/Noveum/hinge).
One-O is an independent implementation by GE Labs.

## License

MIT. See `LICENSE`.
