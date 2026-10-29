# Setup

See [REQUIREMENTS](REQUIREMENTS.md) for the Android and toolchain requirements.
Use your own developer credentials. **Never publicly distribute an APK
containing real credentials:** the Tesla client secret and Maps key are
embedded in the build.

## 1. Prepare the tools

Install Flutter stable, the Android SDK and a compatible JDK using Flutter's
[Android setup instructions](https://docs.flutter.dev/platform-integration/android/setup).
Complete the Android SDK license prompts, then run:

```sh
flutter doctor
```

For a connected phone, enable Developer options and USB debugging, connect a
USB data cable, and authorize the computer. List available devices with:

```sh
flutter devices
```

## 2. Get the project

```sh
git clone https://github.com/DreamMakers2/Tesla-Summon-Anywhere.git
cd Tesla-Summon-Anywhere
flutter pub get
```

## 3. Configure Tesla Fleet API

Create an application in the [Tesla Developer Portal](https://developer.tesla.com/)
with the redirect URI `com.summonanywhere.auth://app/callback` and these scopes:
`openid`, `offline_access`, `user_data`, `vehicle_device_data`, `vehicle_location`.
Complete any partner registration required by Tesla for your region.

```sh
cp secrets.json.example secrets.json
```

Replace the local file's Client ID and Client Secret placeholders and set the
Fleet API base URL for your Tesla account's region. The example uses the Europe
endpoint. Keep this file and its backups private. The app receives its settings
at build time through `--dart-define-from-file=secrets.json`.

Consult Tesla's [Fleet API documentation](https://developer.tesla.com/docs/fleet-api)
and [billing and limits](https://developer.tesla.com/docs/fleet-api/billing-and-limits)
for registration, regional endpoints, eligibility and charges.

## 4. Configure Google Maps

In Google Cloud, enable Maps SDK for Android and its billing, then create an API
key. Restrict the key to Maps SDK for Android, Android package
`com.summonanywhere`, and the SHA-1 fingerprint of the certificate signing your
APK. See Google's [API key instructions](https://developers.google.com/maps/documentation/android-sdk/get-api-key).

Add the following to `android/local.properties`:

```properties
GOOGLE_MAPS_API_KEY=YOUR_GOOGLE_MAPS_API_KEY
```

Preserve the SDK paths managed by Flutter/Android tooling in that file.
`android/local.properties.example` contains the Maps property template.
Both local configuration files are Git-ignored:

```sh
git check-ignore secrets.json android/local.properties
```

## 5. Build and install

```sh
dart run build_runner build
flutter run --dart-define-from-file=secrets.json
```

`flutter run` builds and installs the app on the connected device. Add
`-d DEVICE_ID` if more than one device is available.

For a private sideloaded APK:

```sh
flutter build apk --release --dart-define-from-file=secrets.json
adb install -r build/app/outputs/flutter-apk/app-release.apk
```

The current release configuration uses the debug signing key. Updates signed
with the same certificate preserve app data. Keep credential-bearing APKs
private; do not upload them to GitHub or distribute them publicly.

## 6. Onboarding and GPS sync

1. Sign in to Tesla in the app and authorize access.
2. Select **Summon Anywhere** as the mock-location app in Android Developer options.
3. Follow the app's battery-settings step and grant location and notification
   permissions. Enable precise location and device location services.
4. Tap **Start GPS Sync** when you want other apps to receive the vehicle's
   location. The foreground session lasts up to five minutes and polls available
   vehicle coordinates approximately every five seconds.
5. Use **Location status** to view the Tesla fix, submitted mock, effective phone
   location and last real phone fix. Tap **Stop** to end the session and start
   GPS cleanup.

Android can return a cached location after Stop. A cached fix retains its older
timestamp; it is not a current location update. The **Last real phone fix** row
is historical. Use the age and mock status in **Effective phone GPS** to read
the phone's latest reported location. The app displays cleanup errors
with a **Stop** retry action.

The app reads Fleet API data without wake or vehicle-control commands. Sleeping
or offline vehicles may not return coordinates. Other apps can detect or decline
mock locations. Inter fonts are bundled and do not require runtime downloads.
See [SECURITY](../SECURITY.md) for credential and local-data handling.

## Source checks

```sh
flutter analyze
flutter test
```

CI resolves dependencies and generates sources before these commands.

## Troubleshooting

- **Sign-in fails:** check build defines, redirect URI, scopes, account access
  and Fleet region. Use **Settings → Sign in to Tesla** to reconnect.
- **Blank map:** check Maps SDK enablement, billing, package restriction and the
  SHA-1 restriction for the certificate signing the installed APK.
- **No Tesla location:** a sleeping or offline vehicle may return HTTP 408;
  API failures and rate limits trigger retries and backoff. HTTP 412 can indicate
  incomplete regional partner registration.
- **Mock location unavailable:** select the app in Android Developer options and
  grant location permissions.
- **Location still shows a mock after Stop:** use the location-status ages
  to distinguish a cached reading from a new update. Reopen the app and use the
  **Stop** retry action if it reports a cleanup error.
