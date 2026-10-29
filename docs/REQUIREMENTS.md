# Requirements

## Android and services

- An Android phone with Google Play services, enabled location services and
  location permissions.
- Android Developer options with **Summon Anywhere** selected as the
  mock-location app.
- A Tesla account and vehicle with Fleet API access, plus a Tesla developer
  application with credentials, scopes and a regional Fleet API configuration.
  Active GPS sync uses fresh vehicle coordinates.
- A Google Maps API key with Maps SDK for Android and billing enabled, restricted
  to the app package and signing certificate.
- Internet access to Tesla authentication, Fleet API and Google Maps.

The app uses Android GPS and Google fused location. Foreground-service and
notification permissions support the GPS sync session. Android SDK levels and
NDK version come from the installed Flutter SDK in
`android/app/build.gradle.kts`.

## Build toolchain

| Component | Configuration |
| --- | --- |
| Flutter | Stable channel; `pubspec.lock` requires `>=3.44.0`. |
| Dart | `pubspec.lock` requires `>=3.12.0 <4.0.0`. |
| Java and Kotlin | Java source/target compatibility and Kotlin JVM target 17. |
| Gradle | Wrapper version 9.1.0. |
| Android Gradle Plugin | 9.0.1. |
| Kotlin plugin | 2.3.20. |
| Native location library | Google Play services location 21.2.0. |

Flutter packages are declared in `pubspec.yaml` and resolved in `pubspec.lock`.
Riverpod sources are generated with `build_runner`.

See [setup](SETUP.md) for configuration, build and installation commands.
