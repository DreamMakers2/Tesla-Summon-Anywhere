# Summon Anywhere

Based on [usamasaleem1/summon-anywhere-tesla](https://github.com/usamasaleem1/summon-anywhere-tesla).

*Show a Tesla's location and temporarily mirror it to Android mock GPS.*

![Android](https://img.shields.io/badge/platform-Android-3DDC84)
![Flutter](https://img.shields.io/badge/built%20with-Flutter-02569B)
![License: MIT](https://img.shields.io/badge/license-MIT-blue)

An Android-only Flutter app that reads a Tesla's location through the Tesla Fleet
API and shows it alongside the phone's effective location on a satellite map.
It does not send vehicle-control or wake commands.

**Start GPS Sync** starts a foreground session of up to five minutes. While the
vehicle is available, the app polls its location approximately every five seconds
and submits fresh coordinates to Android GPS and Google fused location. Stop
requests cleanup and a return to normal location. The location-status sheet
separates the Tesla fix, submitted mock, effective location and last observed
real phone fix. Other apps can detect or decline mocked locations.

An asleep or offline vehicle may not provide coordinates. The app retries and
backs off on API failures and rate limits; old or invalid coordinates are not
used for mocking. Fleet API calls may incur charges; see
[Tesla's billing and limits](https://developer.tesla.com/docs/fleet-api/billing-and-limits).

## Setup and private builds

See [setup](docs/SETUP.md) for Tesla registration, Google Maps configuration,
Android permissions and installation, and [requirements](docs/REQUIREMENTS.md)
for toolchain constraints and verified coverage.

```sh
git clone https://github.com/DreamMakers2/Tesla-Summon-Anywhere.git
cd Tesla-Summon-Anywhere
flutter pub get
```

Configure the ignored local `secrets.json` and `android/local.properties` files
as described in the setup guide, then run:

```sh
dart run build_runner build
flutter run --dart-define-from-file=secrets.json
```

The build embeds the Tesla Client Secret and Google Maps key in the APK. They
can be extracted. **Never publicly distribute an APK built with real
credentials.** Use your own developer credentials and restrict the Maps key to
Maps SDK for Android, this app's package and your signing certificate. The
current release build uses debug signing and is intended for private sideloading.

Tesla OAuth tokens use encrypted app storage. Selected vehicle ID and name use
ordinary app-local SharedPreferences; see [security](SECURITY.md).
The requested OAuth scopes are preserved, including `user_data`.
Inter fonts are bundled locally under the SIL Open Font License, and runtime
font fetching is disabled.

## Validation and coverage

```sh
flutter analyze
flutter test
```

The source baseline was tested on a real Android phone and Tesla by the owner.
See [requirements](docs/REQUIREMENTS.md) and the
[release checklist](docs/PUBLIC_RELEASE_CHECKLIST.md).

## Screenshots

These are real device captures from the tested baseline. The map, vehicle name,
location coordinates and device status bar have been obscured for privacy. In
the main-screen image, translucent panel backgrounds are also flattened to
conceal map details. The location-status capture was made while the vehicle was
unavailable.

<img src="docs/images/main-screen.png" alt="Main screen with map and vehicle name redacted" width="320"> <img src="docs/images/location-status.png" alt="Location status sheet with coordinates redacted" width="320"> <img src="docs/images/settings.png" alt="Summon Anywhere settings" width="320">

## Project structure and documentation

- `lib/core` contains authentication, Fleet API, location services and storage.
- `lib/features` contains app screens and the background session.
- `android/app` contains the native Android integration.
- [Setup](docs/SETUP.md) and [requirements](docs/REQUIREMENTS.md) cover configuration and verification.
- [Security](SECURITY.md) and [contributing](CONTRIBUTING.md) describe sensitive reporting and development.
- The [security review](docs/SECURITY_REVIEW.md) and [public release checklist](docs/PUBLIC_RELEASE_CHECKLIST.md) record findings and release status.

## License

This project retains the upstream MIT license and its copyright notice; see
[LICENSE](LICENSE) and [NOTICE](NOTICE). Dependencies retain their individual
licenses. This project is not an official Tesla or Google product.
