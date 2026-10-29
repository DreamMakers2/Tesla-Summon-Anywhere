# Contributing

Discuss substantial changes in
[the repository](https://github.com/DreamMakers2/Tesla-Summon-Anywhere) before
implementing them. Keep changes focused and describe the problem, the approach
and what was tested. See [setup](docs/SETUP.md) and
[requirements](docs/REQUIREMENTS.md).

For source changes, run:

```sh
flutter pub get
dart run build_runner build
flutter analyze
flutter test
```

Use placeholder credentials for source and CI checks. Never commit local
configuration, credential backups, tokens, keys, signing files, device logs or
APKs containing real credentials.

Preserve the MIT license, upstream attribution and applicable third-party
notices. Include the license for any added assets. See [SECURITY.md](SECURITY.md)
for sensitive reports.
