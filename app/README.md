# isNestle — iOS app

An offline-first iPhone app: scan a product barcode and see whether it's made by
Nestlé. By default nothing you scan or search leaves the device; optional online
lookup can identify unknown products via Open Food Facts.

## Status

Core app plus dataset self-update features. Camera scanning requires a real
iPhone; the Simulator has no camera and falls back to manual barcode entry.

| Verified | How |
|----------|-----|
| Compiles for iOS | `xcodebuild build` (clean) |
| Bundled SQLite lookup correct in iOS runtime | XCTest suite |
| App launches & UI renders | Simulator screenshot |
| Verdict screen (Minimal theme) | Simulator screenshot (real lookup) |

## Architecture

- **SwiftUI**, iOS 16+, iPhone-only.
- `BarcodeDatabase` — dependency-free read-only access to the bundled
  `isnestle.sqlite` via the system `SQLite3` module (see `/spec/elements/STACK.md`).
- `BarcodeScannerView` — VisionKit `DataScannerViewController` on device; manual
  barcode entry fallback where unsupported (Simulator).
- `ResultPanel` / `VerdictView` — four switchable themes fed by the same
  `OwnershipResult` model. Color is always paired with an SF Symbol + text
  (never color alone — accessibility).
- `DatasetUpdater` — daily manifest check, verified SQLite download, atomic
  install of newer datasets.
- `ManualSearchView` — local brand-name search. `SettingsView` — theme,
  online-lookup opt-in, dataset status, attribution, and disclaimer.

The bundled `isNestle/Resources/isnestle.sqlite` is produced by the
[data-pipeline](../data-pipeline): 601 brands, 33,275 barcodes.

## Build & run

The project is generated with [XcodeGen](https://github.com/yonyz/XcodeGen) from
`project.yml` (the source of truth). The `.xcodeproj` is **not committed** — you
generate it locally. **Signing lives in a gitignored `Local.xcconfig`**, so your
personal team / bundle id never land in git and `xcodegen generate` never wipes
them.

First-time setup:
```bash
brew install xcodegen
cd app
cp Local.xcconfig.example Local.xcconfig    # then set DEVELOPMENT_TEAM (+ bundle id)
xcodegen generate                           # creates isNestle.xcodeproj
open isNestle.xcodeproj
```
Re-run `xcodegen generate` after editing `project.yml` (e.g. adding files).

```bash
# Build for the simulator
xcodebuild -project app/isNestle.xcodeproj -scheme isNestle \
  -destination 'platform=iOS Simulator,name=iPhone 17 Pro' build

# Run the tests
xcodebuild test -project app/isNestle.xcodeproj -scheme isNestle \
  -destination 'platform=iOS Simulator,name=iPhone 17 Pro'
```

### Run on your iPhone
1. Set `DEVELOPMENT_TEAM` (and a unique `PRODUCT_BUNDLE_IDENTIFIER`) in
   `app/Local.xcconfig`, then `xcodegen generate` and open the project.
2. Pick your device and **Run** (⌘R). A **free Apple ID works** for development.
3. First launch: trust the cert (Settings → General → VPN & Device Management),
   make sure **Developer Mode** is on (Settings → Privacy & Security), and
   **reboot** if the app won't launch after trusting.
4. Grant camera access when prompted, point at a barcode.

### Dev hook
A `#if DEBUG`-only launch argument pre-loads a verdict for screenshots without a
camera (use whatever `PRODUCT_BUNDLE_IDENTIFIER` you set in `Local.xcconfig`):
`xcrun simctl launch booted <your.bundle.id> -demoBarcode 3023290000953`.
