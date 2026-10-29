# Public source release security review

This review covers the separate, sanitized source-release copy. It is not a
penetration test or a guarantee that every issue has been found. The owner has
not approved the first public push.

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
- An inherited Android splash asset depicted Tesla branding and a car, whose
  separate trademark/image rights were not established by the MIT license. It
  was removed from this copy; the splash now uses the existing generic app icon.
  This is not a legal opinion or a verification of all third-party rights.

## Remaining risks and limits

1. **Extractable build credentials:** Tesla client credentials and the Maps key
   are embedded in APKs built with real values. Never publish or redistribute
   such APKs. Maps restrictions do not make the key secret. A safer public
   binary would require a separately designed credential-handling solution.
2. **OAuth scope:** `user_data` grants profile/contact/address access. The app's
   existing scope set was preserved because its minimum working set has not been
   verified through a fresh authorization, refresh and vehicle-location test.
3. **Local vehicle metadata:** selected vehicle ID and name remain in ordinary
   app-local SharedPreferences, not encrypted token storage. Android backup is
   disabled, but a compromised or rooted device may expose this data. The
   selection behavior was retained to avoid changing tested session behavior.
4. **Android and Tesla verification:** the owner reported successful real-device
   testing of the source baseline. The release copy's bundled fonts and splash
   resource have not been tested on a device or in an Android APK build. No new
   Tesla sign-in, location, foreground-session or cleanup test was performed.
   Mock-provider cleanup and fresh non-mocked fixes must be verified on the target
   device; stale caches or platform failures can delay confirmation.
5. **Licensing:** the upstream MIT notice and font license are retained; rights
   to every third-party dependency and trademark have not been independently
   established. Tesla and Google are third-party trademarks.

## Validation

`flutter pub get`, `dart run build_runner build`, `flutter analyze` and
`flutter test` passed in the release copy using placeholder configuration;
104 tests passed, including an offline Inter-loading test. Android XML resources
were parsed and the generic splash icon reference checked. No APK was built or
published, and no device settings were changed. The original private source
repository was not modified.

Review [SECURITY.md](../SECURITY.md) and the
[release checklist](PUBLIC_RELEASE_CHECKLIST.md) before publication.
