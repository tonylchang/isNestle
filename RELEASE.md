# Release Checklist

Use this before cutting a TestFlight or App Store build.

## Local Validation

From the repo root:

```bash
python3 scripts/verify_release_assets.py
python3 data-pipeline/test_spike.py
(cd data-pipeline && python3 test_parsing.py)
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
- Privacy policy link opens `https://tonylchang.github.io/isNestle/privacy.html`.

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

## Dataset Signing & Key Management

The daily workflow signs `manifest.json` (Ed25519) and the app only installs
datasets whose manifest verifies against a trusted public key baked into
`DatasetManifest.trustedPublicKeys` (primary + standby).

Where things live:

- **Primary private key** — GitHub environment secret `DATASET_SIGNING_KEY` in
  the `dataset-publish` environment (deployments restricted to `main`), plus a
  copy in the password manager.
- **Standby private key** — password manager **only**, never in GitHub. This is
  what makes rotation survive a GitHub account compromise.
- **Public keys (hex)** — baked into the app *and* listed in the workflow's
  `TRUSTED_PUBLIC_KEYS` (the sign step refuses to sign with an unrecognized key).

Rotation runbook (suspected primary-key leak):

1. Swap the secret to the standby key — shipped apps already trust it:
   `gh secret set DATASET_SIGNING_KEY --env dataset-publish --repo tonylchang/isNestle < isnestle-signing-standby.pem`
2. Generate a fresh standby (`openssl genpkey -algorithm ed25519`), store the
   PEM in the password manager only.
3. In the next app release: add the new standby's public key to
   `DatasetManifest.trustedPublicKeys` and the workflow's `TRUSTED_PUBLIC_KEYS`,
   and drop the leaked key from both.

Verify a published release locally:

```bash
gh release download dataset-latest -p 'manifest.json*' --clobber
printf '302a300506032b6570032100cc8c8947d16d824d37f84579a587fdf720c1ac83336f503748c9963a1b39bff9' \
  | xxd -r -p > /tmp/isnestle-pub.der
openssl pkeyutl -verify -pubin -keyform DER -inkey /tmp/isnestle-pub.der \
  -rawin -in manifest.json -sigfile manifest.json.sig
```

## App Store Privacy

App Store Connect requires a privacy policy URL and privacy-practice answers for
iOS apps. Use:

- Privacy policy URL: `https://tonylchang.github.io/isNestle/privacy.html`.
- Privacy policy source: `docs/privacy.html`.
- Questionnaire stance: the app itself does not collect data, track users, run
  analytics, or store scan history.
- Optional online lookup: remains off by default and sends unresolved barcodes
  directly to Open Food Facts only after the user enables it. Keep the privacy
  policy and App Store privacy answers aligned with Apple's current wording for
  third-party data handling.

Apple references:

- App privacy details: <https://developer.apple.com/app-store/app-privacy-details/>.
- Manage app privacy: <https://developer.apple.com/help/app-store-connect/manage-app-information/manage-app-privacy/>.
- TestFlight test information: <https://developer.apple.com/help/app-store-connect/test-a-beta-version/provide-test-information>.
- Export compliance: <https://developer.apple.com/documentation/security/complying-with-encryption-export-regulations>.
