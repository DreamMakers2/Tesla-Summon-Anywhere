# Contributing

Please discuss substantial changes in
[the repository](https://github.com/DreamMakers2/Tesla-Summon-Anywhere) before
implementing them. Keep changes focused and describe the problem, the approach
and what was tested. See [setup](docs/SETUP.md) and
[requirements](docs/REQUIREMENTS.md).

For source changes, resolve dependencies, generate Riverpod sources when needed
and run:

```sh
flutter pub get
dart run build_runner build
flutter analyze
flutter test
```

Use placeholder credentials for source and CI checks. Never commit local
configuration, credential backups, tokens, keys, credential-bearing APKs,
signing files or device logs. Public build artifacts must not contain developer
credentials.

Preserve attribution and applicable third-party notices when adding or changing
assets. This project uses the MIT license; do not change the licensing model
without an explicit decision. See [SECURITY.md](SECURITY.md) for sensitive
reports.
