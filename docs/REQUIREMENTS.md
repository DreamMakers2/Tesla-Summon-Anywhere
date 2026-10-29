# Requirements and verified coverage

This project is an Android-only Flutter app. Requirements below distinguish
repository configuration from observed testing. No broad device compatibility
claim or measured minimum hardware specification is available.

## Verified test evidence

The project notes record testing on a Samsung Galaxy S24, including real Google
Maps satellite tiles, foreground/background session behavior, five-minute
expiry, GPS and Google fused mock-location callbacks, Stop cleanup and
restart recovery. The owner subsequently confirmed the app works after full
Tesla testing. The earlier source validation recorded 103 passing Flutter
tests and successful analysis.

The phone's exact model variant, Android version, firmware, CPU architecture,
RAM, free storage and GPU were not captured in a sanitized verification record.
They are not asserted here. The checked-in dependency lockfile records minimum
SDK constraints; these are dependency constraints rather than a device
compatibility guarantee.

## Phone and service requirements

| Component | Requirement and evidence limit |
| --- | --- |
| Platform | A real Android phone is needed for the documented end-to-end verification. iOS, web and desktop operation are not implemented or verified. |
| Android version | `minSdk`, `targetSdk` and `compileSdk` are taken from the installed Flutter SDK in `android/app/build.gradle.kts`. There is no separately pinned Android version here; plugin requirements must also be met. No minimum Android release has been verified by a device matrix. |
| Mock location | Android Developer options must permit selecting this app as the mock-location app. Device policies that prohibit mock location prevent this feature. |
| Location | Enabled device location services and appropriate location permissions; the app uses Android GPS and Google fused location. |
| Google services | The app depends on Google Maps and Google Play services location. Devices without working Google services have not been verified. |
| Network | Internet access to Tesla authentication/Fleet API and Google Maps is required. Offline operation and a minimum bandwidth have not been established. |
| Tesla access | A Tesla account/vehicle with usable Fleet API access and a developer application with the required scopes, credentials and region configuration. The vehicle must return fresh coordinates for active mirroring. |
| Google Maps | A Maps SDK for Android API key with the relevant service/billing enabled and package/certificate restrictions. |
| Runtime permissions | Location access and foreground-service operation are needed. Notification access controls notification visibility; the manifest also declares background location and battery-optimization-related permissions. Follow the app's onboarding and Android prompts. |
| CPU, RAM and storage | No measured minimum or recommended capacity has been established. CPU ABI availability depends on the Flutter/Android build. The tested device's variant is not documented, so this project makes no ABI compatibility claim. |
| GPU/accelerator | Map rendering uses the phone's graphics stack; no specific GPU requirement or separate accelerator is documented or tested. |
| Peripherals/interfaces | No external GPS device is required by the code. USB debugging and a data cable are used for the documented development workflow; normal app use does not require a computer connection. |

## Build environment

| Tool or component | Repository evidence |
| --- | --- |
| Flutter | Stable channel is used by CI; the SDK is not pinned. The checked-in lockfile requires Flutter `>=3.44.0`. |
| Dart | `pubspec.yaml` declares `sdk: ^3.8.1`, but the checked-in lockfile requires Dart `>=3.12.0 <4.0.0`. |
| Android SDK / NDK | Selected through the installed Flutter SDK's `compileSdkVersion`, `targetSdkVersion`, `minSdkVersion` and `ndkVersion`; install what Flutter's Android tooling reports as required. |
| Java | Android source/target compatibility and Kotlin JVM target are 17. A JDK compatible with the selected Gradle and Android Gradle Plugin is also necessary; source compatibility alone does not establish which JDK can run the build. |
| Gradle | Wrapper configuration specifies 9.1.0. Use the wrapper through Flutter rather than installing an unrelated global Gradle version. |
| Android Gradle Plugin | `android/settings.gradle.kts` specifies 9.0.1. |
| Kotlin plugin | `android/settings.gradle.kts` declares 2.3.20. |
| Android location library | Native dependency on `com.google.android.gms:play-services-location:21.2.0`. |
| Packages | Dart/Flutter packages are declared in `pubspec.yaml` and resolved in `pubspec.lock`; `flutter pub get` is the package command. |
| Source generation | `dart run build_runner build` generates Riverpod source files. |
| CI operating system | The workflow specifies `ubuntu-24.04`, Flutter stable, generation, analysis and tests. A workflow declaration is not proof of successful execution on every commit. |
| Host hardware | Development host CPU, RAM, storage and GPU minimums have not been measured. Follow the current Flutter/Android SDK host requirements. |
| Drivers and firmware | ADB connectivity may require manufacturer-specific USB drivers on the chosen host. No project-specific driver or firmware version is verified or required in the repository. |

The repository does not document verified setup on every supported Flutter host
operating system. The Android toolchain, network access and enough local disk
space for the SDK, dependency caches and build outputs are necessary, but this
project has no defensible numeric capacity recommendation.

See [setup](SETUP.md) for configuration and checks. The current release build
uses debug signing and embeds the Tesla client secret, so the documented
workflow is for private sideloading; do not publish credential-bearing APKs.
