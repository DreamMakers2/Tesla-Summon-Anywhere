# Setup

These instructions build the Android app for private use on your own phone.
See [requirements](REQUIREMENTS.md) before starting. The source can be shared
without local configuration; an APK built with real credentials must stay
private because its Tesla client secret can be extracted.

## 1. Prepare the development tools

Install the Flutter stable SDK, an Android SDK and a compatible JDK. The project
uses Java 17 source/target compatibility; see the toolchain details
in [requirements](REQUIREMENTS.md). Follow Flutter's
[Android setup instructions](https://docs.flutter.dev/platform-integration/android/setup)
and complete Android SDK license acceptance when requested by those tools.

Check your installation:

```sh
flutter doctor
```

Use a USB data cable and the phone manufacturer's normal USB/ADB setup to
connect a real Android phone. Enable Developer options and USB debugging on
the phone, authorize your development computer, and check that Flutter sees it:

```sh
flutter devices
```

## 2. Get the project

```sh
git clone https://github.com/DreamMakers2/Tesla-Summon-Anywhere.git
cd Tesla-Summon-Anywhere
flutter pub get
```

The upstream project is
[usamasaleem1/summon-anywhere-tesla](https://github.com/usamasaleem1/summon-anywhere-tesla).

## 3. Configure Tesla Fleet API access

1. Sign in to the [Tesla Developer Portal](https://developer.tesla.com/) and
   create a developer application for your own use.
2. Register this redirect URI exactly, including its scheme, host and path:
   `com.summonanywhere.auth://app/callback`.
3. Enable the scopes requested by this app: `openid`, `offline_access`,
   `user_data`, `vehicle_device_data` and `vehicle_location`.
4. Keep the application Client ID and Client Secret private. Set the Fleet API
   base URL for the region associated with your Tesla account. The example file
   uses Tesla's Europe endpoint; it is not a universal regional setting.
5. Complete any partner registration required by Tesla for your region. An
   HTTP 412 response can indicate that registration is incomplete.

From the project root:

```sh
cp secrets.json.example secrets.json
```

Edit only the local `secrets.json`, replacing the placeholder Client ID and
Client Secret and confirming the Fleet API region. Do not paste credentials
into an issue, screenshot or commit. The app reads this configuration at build
time through `--dart-define-from-file=secrets.json`; a build made without that
argument retains placeholders and cannot complete normal sign-in.

Tesla controls account, vehicle and API eligibility. Consult the current
[Fleet API documentation](https://developer.tesla.com/docs/fleet-api) and
[billing and limits](https://developer.tesla.com/docs/fleet-api/billing-and-limits)
for registration, regional endpoints, access and charges.

## 4. Configure Google Maps

In Google Cloud, enable Maps SDK for Android and the billing required by that
service, then create an API key. Restrict the key to Maps SDK for Android and
to this app's Android package, `com.summonanywhere`, with the SHA-1 fingerprint
of the certificate that signs your local APK. Follow Google's
[API key instructions](https://developers.google.com/maps/documentation/android-sdk/get-api-key).

Add this property to `android/local.properties`, replacing the placeholder:

```properties
GOOGLE_MAPS_API_KEY=YOUR_GOOGLE_MAPS_API_KEY
```

The file also needs the normal `sdk.dir` and `flutter.sdk` paths for your own
installation. Flutter/Android tooling normally manages these paths. Preserve
an existing file rather than replacing it; `android/local.properties.example`
shows the Maps property. The Maps key is present in the APK, so restrictions
are necessary even when the source configuration remains private.

Both `secrets.json` and `android/local.properties` are Git-ignored. Confirm
that before sharing any files:

```sh
git check-ignore secrets.json android/local.properties
```

## 5. Generate and run

```sh
dart run build_runner build
flutter run --dart-define-from-file=secrets.json
```

If several devices are connected, add `-d DEVICE_ID` using an identifier from
`flutter devices`; keep that identifier out of public logs and screenshots.

For a private local APK:

```sh
flutter build apk --release --dart-define-from-file=secrets.json
```

The output is `build/app/outputs/flutter-apk/app-release.apk`. The current
release configuration uses the debug signing key. Keep this APK private;
this setup does not configure store distribution or a dedicated release key.
An update signed with the same certificate can preserve existing app data.

## 6. Complete onboarding and check operation

1. Sign in with Tesla in the app and authorize access to your account.
2. In Android Developer options, select **Summon Anywhere** as the mock location
   app. Return to the app and refresh the onboarding status if needed.
3. Follow the app's battery-settings step. Allow location access and
   notifications when prompted. Precise location and enabled device location
   services are needed to observe the phone's location.
4. When it is appropriate for other apps on your phone to receive mocked
   location, tap **Start GPS Sync**. A foreground session lasts up to five
   minutes and polls available Tesla location approximately every five seconds.
5. Open the location-status sheet to inspect Tesla, submitted mock, effective
   phone and last observed real phone fixes. Use **Stop** to end the session.

The app reads Fleet API data; it does not send wake or vehicle-control commands.
An asleep or offline vehicle may not provide current coordinates. Other apps can
detect or decline mock locations.

Inter font assets are bundled locally and runtime font fetching is disabled;
font downloads are not part of application startup. See
[the bundled font license](../assets/fonts/OFL.txt).

The app saves the selected vehicle ID and name in ordinary app-local
SharedPreferences; OAuth tokens use encrypted storage. See
[security](../SECURITY.md).

## Source checks

```sh
flutter analyze
flutter test
```

CI also resolves dependencies and generates sources before these checks.

## Troubleshooting

- **Sign-in fails:** check the local build defines, exact redirect URI, scopes,
  account access and Fleet region. Use **Settings → Sign in to Tesla** if the
  saved sign-in has expired. Do not share tokens or the Client Secret.
- **Blank map:** check Maps SDK enablement, billing, the package restriction and
  the SHA-1 restriction for the actual signing certificate used for this APK.
- **No current Tesla location:** check the app's reported API status. A sleeping
  or offline vehicle may return HTTP 408; API failures and rate limits cause
  retries with backoff. Old or invalid coordinates are not used for mocking.
- **Mock location unavailable:** confirm the Android mock-location app selection
  and location permissions, then check the app's status again.
- **Location still looks mocked after stopping:** reopen the app and check its
  cleanup/effective-location status.
