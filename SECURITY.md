# Security

## Credentials and local data

- Tesla client credentials and the Google Maps key are embedded in built APKs
  and can be extracted. **Never publicly distribute an APK containing real
  credentials.** Use your own Tesla developer application for private builds.
- Restrict the Maps key to Maps SDK for Android, package `com.summonanywhere`
  and the signing certificate used for the APK. Restrictions do not make an
  embedded key secret. Keep local configuration and credential backups out of Git.
- Tesla access and refresh tokens use encrypted app storage. Android app backup
  is disabled. A rooted or compromised device can expose app data.
- The selected vehicle ID and name use ordinary app-local SharedPreferences,
  separately from encrypted token storage. Removing tokens does not remove the
  saved vehicle selection.
- Maps, screenshots, logs and diagnostics can reveal locations or identifiers.
  Remove sensitive details before sharing them; blur alone does not reliably
  conceal sensitive text.

## OAuth scopes and third-party services

The app requests `openid`, `offline_access`, `user_data`, `vehicle_device_data`
and `vehicle_location`. `user_data` grants profile, contact and address access.
See [Tesla's scope documentation](https://developer.tesla.com/docs/fleet-api/authentication/overview)
and the authorization consent screen.

Tesla authentication, Fleet API access and Google Maps communicate with their
respective services. Their eligibility, privacy and billing terms apply. Inter
fonts are bundled in `assets/fonts` under the [OFL license](assets/fonts/OFL.txt),
and runtime font fetching is disabled.

## Mock location and cleanup

Mock location affects other apps on the phone. Sessions last up to five minutes
and implement Stop, cancellation and recovery cleanup. Stop requests removal of
the GPS test provider and disables fused mock mode. Android can return a cached
fix after cleanup. The location-status sheet reports the age and mock status of
the effective phone location; the last real phone fix is a historical reading.
Cleanup errors appear in the app with a **Stop** retry action.

## Reporting a vulnerability

Do not put credentials, tokens, precise locations or private exploit details in
a public issue. If private vulnerability reporting is enabled, use the
[repository's Security tab](https://github.com/DreamMakers2/Tesla-Summon-Anywhere/security)
to report privately. Otherwise, contact the repository owner through a trusted
private channel. Include a minimal description and reproduction steps with
sensitive values removed.
