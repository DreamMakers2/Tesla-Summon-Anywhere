# Public source release security review

This review covers the separate, sanitized source-release copy. The owner
approved the first public push of the reviewed source commit.

## Review and changes

- The release copy was made from the latest verified source snapshot without
  copying its Git history. The destination was public and empty when checked.
- A Gitleaks 8.30.1 scan and targeted searches covered the intended source tree,
  including generated code, examples, tests and workflow files. The scan found
  no credentials. Pattern matches for path-like strings were Dart imports;
  coordinate-like values in tests were synthetic fixtures, not device readings.
- Local configuration and backup examples are ignored; checked-in examples use
  placeholders. APKs, Android App Bundles and common signing-key and certificate
  formats are ignored. A Git ignore rule does not protect files shared by other
  means or previously committed elsewhere.
- All included PNGs were checked for metadata; none contained ancillary metadata.
  The three app screenshots were visually inspected and retain opaque redactions
  or cropping for the map, coordinates, vehicle name and status bar.
- The workflow has read-only repository permissions and runs source checks. It
  neither injects real credentials nor builds or uploads APKs.
- Upstream's MIT license and copyright notice match the retained `LICENSE`.
  Bundled Inter fonts include the full SIL Open Font License in
  `assets/fonts/OFL.txt`; the four font files were checked against the hashes in
  the locked `google_fonts` package. Runtime font fetching is disabled.
- The inherited Android splash asset was removed; the splash uses the existing
  generic app icon.

## Credentials and local data

- Tesla client credentials and the Maps key are embedded in APKs built with real
  values. Never publish or redistribute such APKs. Maps restrictions do not make
  the key secret.
- `user_data` grants profile, contact and address access. The app retains its
  existing OAuth scope set.
- Selected vehicle ID and name use ordinary app-local SharedPreferences,
  separately from encrypted token storage. Android backup is disabled; a rooted
  or compromised device may expose app data.

## Validation

`flutter pub get`, `dart run build_runner build`, `flutter analyze` and
`flutter test` passed in the release copy using placeholder configuration;
104 tests passed, including an offline Inter-loading test. The Android debug
build (`flutter build apk --debug`) succeeded using placeholder Tesla and Google Maps credentials
and an isolated debug signing key. All four bundled font files matched their
source assets; the compiled Android 31 splash referenced the generic app icon,
and all five compiled icon densities matched the generic sources. The compiled
manifest contained the Maps placeholder. The temporary APK, signing key and
build artifacts were deleted; no APK was published or installed and no device
settings were changed.

The original private source repository was not modified.

Review [SECURITY.md](../SECURITY.md) and the
[release checklist](PUBLIC_RELEASE_CHECKLIST.md) for the publication status.
