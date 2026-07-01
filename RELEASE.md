# Release Checklist

Use this before cutting a TestFlight or App Store build.

## Local Validation

From the repo root:

```bash
python3 scripts/verify_release_assets.py
python3 data-pipeline/test_spike.py
```

From `app/`, regenerate the Xcode project after adding or moving Swift files:

```bash
xcodegen generate
```

Build and test on a simulator:

```bash
xcodebuild build -project app/isNestle.xcodeproj -scheme isNestle \
  -destination 'platform=iOS Simulator,name=iPhone 17 Pro'

xcodebuild test -project app/isNestle.xcodeproj -scheme isNestle \
  -destination 'platform=iOS Simulator,name=iPhone 17 Pro'
```

Run a device smoke test before upload:

- Camera permission prompt appears with the expected privacy copy.
- Live scanning works on a known Nestlé barcode.
- Simulator/manual fallback works with a known barcode.
- Online lookup is off by default.
- Turning online lookup on sends only unknown local misses to Open Food Facts.
- Settings shows the current dataset version and counts.
- Privacy policy link opens `https://tonylchang.github.io/isNestle/`.

## Xcode Cloud

The repo does not carry Xcode Cloud configuration. Configure it in App Store
Connect/Xcode so project settings and signing remain Apple-managed:

- Workflow: build on pushes or tags intended for TestFlight.
- Scheme: `isNestle`.
- Environment: current Xcode, iOS 16+ deployment target.
- Actions: build, run unit tests, archive, distribute to TestFlight.
- Pre-build command: `cd app && xcodegen generate`.
- Post-clone validation command from repo root:

```bash
python3 scripts/verify_release_assets.py
```

## Versioning

- App marketing version follows SemVer in the `0.x` line until public App Store
  release.
- App build number increments every uploaded archive.
- Dataset version comes from `app/isNestle/Resources/dataset_manifest.json` and
  must be `YYYY.MM.DD.HHMM`.
- App releases are documented in `CHANGELOG.md`; daily dataset changes are not.

## App Store Privacy

The expected privacy label is "Data Not Collected" for this app. If optional
online lookup remains enabled only by user choice and only contacts Open Food
Facts directly, disclose that third-party request in the privacy policy without
marking it as data collected by this app.

