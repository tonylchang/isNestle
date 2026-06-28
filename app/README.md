# isNestle — iOS app (Milestone 1)

A minimal, **fully offline** iPhone app: scan a product barcode and see whether
it's made by Nestlé. Nothing you scan or search ever leaves the device.

## Status

Milestone 1 (Core App / MVP) — **builds and is simulator-verified.** Camera
scanning requires a real iPhone (the Simulator has no camera and falls back to
manual barcode entry).

| Verified | How |
|----------|-----|
| Compiles for iOS | `xcodebuild build` (clean) |
| Bundled SQLite lookup correct in iOS runtime | 4 XCTest unit tests pass |
| App launches & UI renders | Simulator screenshot |
| Verdict screen (Minimal theme) | Simulator screenshot (real lookup) |

## Architecture

- **SwiftUI**, iOS 16+, iPhone-only.
- `BarcodeDatabase` — dependency-free read-only access to the bundled
  `isnestle.sqlite` via the system `SQLite3` module (see `/spec/elements/STACK.md`).
- `BarcodeScannerView` — VisionKit `DataScannerViewController` on device; manual
  barcode entry fallback where unsupported (Simulator).
- `VerdictView` → `MinimalVerdictView` — the **Minimal** theme behind a small seam
  so M2 can add **Informational** (see `/spec/elements/UI.md`). Color is always
  paired with an SF Symbol + text (never color alone — accessibility).
- `ManualSearchView` — local brand-name search. `AboutView` — ODbL attribution +
  disclaimer.

The bundled `isNestle/Resources/isnestle.sqlite` is produced by the
[data-pipeline](../data-pipeline) (Milestone 0): 601 brands, 3,949 barcodes.

## Build & run

The project is generated with [XcodeGen](https://github.com/yonyz/XcodeGen) from
`project.yml` (the source of truth). The generated `isNestle.xcodeproj` is also
committed, so you can open it directly.

```bash
# (only if you changed project.yml)
brew install xcodegen && cd app && xcodegen generate

# Build for the simulator
xcodebuild -project app/isNestle.xcodeproj -scheme isNestle \
  -destination 'platform=iOS Simulator,name=iPhone 17 Pro' build

# Run the tests
xcodebuild test -project app/isNestle.xcodeproj -scheme isNestle \
  -destination 'platform=iOS Simulator,name=iPhone 17 Pro'
```

### Run on your iPhone
1. Open `app/isNestle.xcodeproj` in Xcode.
2. Select the **isNestle** target → Signing & Capabilities → set your **Team**
   (free Apple ID works for development). The bundle id defaults to
   `net.1x0.isNestle` — change if needed.
3. Pick your device and Run. Grant camera access when prompted, point at a
   barcode.

### Dev hook
A `#if DEBUG`-only launch argument pre-loads a verdict for screenshots without a
camera: `xcrun simctl launch booted net.1x0.isNestle -demoBarcode 3023290000953`.
