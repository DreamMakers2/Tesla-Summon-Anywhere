# Requirements

This project is an Android-only Flutter app.

## Completed checks

The source baseline was tested on a Samsung Galaxy S24 with real Google Maps satellite tiles,
foreground and background sessions, the five-minute session limit, Android GPS
and Google fused mock-location callbacks, Stop cleanup and restart recovery.
The owner confirmed successful Tesla operation.

The source release passed dependency resolution, Riverpod source generation,
Dart analysis, all 104 Flutter tests and an Android debug APK build with
placeholder credentials. The build includes the bundled Inter fonts and generic
app icon.

## Phone and service requirements

| Component | Requirement |
| --- | --- |
| Platform | Android phone. |
| Android SDK levels | `minSdk`, `targetSdk` and `compileSdk` come from the installed Flutter SDK through `android/app/build.gradle.kts`. |
| Mock location | Android Developer options must permit selecting Summon Anywhere as the mock-location app. |
| Location | Enabled device location services and location permissions; the app uses Android GPS and Google fused location. |
| Google services | Google Maps and Google Play services location. |
| Network | Internet access to Tesla authentication, Fleet API and Google Maps. |
| Tesla access | A Tesla account and vehicle with Fleet API access, a developer application, the requested scopes, credentials and regional configuration. Active mirroring uses fresh vehicle coordinates. |
| Google Maps | A Maps SDK for Android API key with the service and billing enabled and package/certificate restrictions. |
| Runtime permissions | Location access and foreground-service operation. The manifest also declares notification, background-location and battery-optimization-related permissions. |
| CPU ABI | ABI support follows the Flutter/Android build. |
| Graphics | Map rendering uses the phone's graphics stack. |
| Peripherals and interfaces | The development workflow uses a USB data cable and USB debugging. Normal app use runs on the phone. |

## Build environment

| Tool or component | Configuration |
| --- | --- |
| Flutter | CI uses the stable channel. The checked-in lockfile requires Flutter `>=3.44.0`. |
| Dart | `pubspec.yaml` declares `sdk: ^3.8.1`; the checked-in lockfile requires Dart `>=3.12.0 <4.0.0`. |
| Android SDK / NDK | The Flutter SDK supplies `compileSdkVersion`, `targetSdkVersion`, `minSdkVersion` and `ndkVersion`. |
| Java | Android source/target compatibility and Kotlin JVM target are 17. |
| Gradle | Wrapper version 9.1.0. |
| Android Gradle Plugin | Version 9.0.1 in `android/settings.gradle.kts`. |
| Kotlin plugin | Version 2.3.20 in `android/settings.gradle.kts`. |
| Android location library | `com.google.android.gms:play-services-location:21.2.0`. |
| Packages | Dependencies are declared in `pubspec.yaml` and resolved in `pubspec.lock`; `flutter pub get` resolves them. |
| Source generation | `dart run build_runner build` generates Riverpod sources. |
| CI operating system | `ubuntu-24.04`, with Flutter stable, source generation, analysis and tests. |

See [setup](SETUP.md) for configuration and build commands. The current release
build uses debug signing and embeds the Tesla client secret. Keep APKs containing
real credentials private.
