# Security

## Credentials and local data

- Build-time Tesla client credentials and the Google Maps key are embedded in
  the APK and can be extracted. Never publish APKs containing real credentials.
  Configure your own Tesla developer application for private builds.
- Restrict the Maps key to Maps SDK for Android, package `com.summonanywhere`
  and the certificate that signs your APK. Restrictions do not make the key a
  secret. Keep local configuration and credential backups out of Git.
- Tesla access and refresh tokens use encrypted app storage. Android app backup
  is disabled. A rooted or compromised device may still expose app data.
- The selected vehicle ID and name are stored in SharedPreferences in the app's
  local data, separately from encrypted token storage. They are identifying
  metadata and are not protected by the token store. Removing tokens does not
  itself remove the saved vehicle selection.
- The app reads vehicle location and submits mock locations to Android. Maps,
  screenshots, logs and diagnostics may reveal sensitive information. Review
  and redact coordinates, vehicle/account identifiers and local paths before
  sharing them. Do not rely on blur alone to conceal sensitive text.

## OAuth scopes and third-party services

The app requests `openid`, `offline_access`, `user_data`, `vehicle_device_data`
and `vehicle_location`. The existing scope set is retained to preserve the
working authentication flow. `user_data` grants profile, contact and address
access. Review the consent screen and
[Tesla's scope documentation](https://developer.tesla.com/docs/fleet-api/authentication/overview).

Tesla authentication, Fleet API access and Google Maps require communication
with their respective services. Review those providers' current eligibility,
privacy and billing terms. Inter fonts are bundled in `assets/fonts`, and
`GoogleFonts.config.allowRuntimeFetching` is disabled to prevent runtime font
downloads. The font files are covered by [their OFL license](assets/fonts/OFL.txt).

## Mock location and cleanup

Mock location affects other apps on the phone. The session is bounded to five
minutes and implements Stop, cancellation and recovery cleanup.

## Reporting a vulnerability

Do not put credentials, tokens, precise locations or private exploit details in
a public issue. If private vulnerability reporting is enabled for
[the repository](https://github.com/DreamMakers2/Tesla-Summon-Anywhere), use its
Security tab to report privately. Otherwise, contact the repository owner
through a trusted private channel. Include a minimal description and reproduction
steps with sensitive values removed.
