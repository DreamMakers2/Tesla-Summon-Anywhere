# Public source release checklist

The [destination repository](https://github.com/DreamMakers2/Tesla-Summon-Anywhere)
is public. The owner approved the first source publication; do not change
either repository's visibility or publish credential-bearing APKs.

## Completed checks

- [x] Snapshot the latest source into a separate copy without its Git history;
  leave the original private repository unchanged.
- [x] Exclude credentials, backups, local configuration, logs, build outputs,
  signing material and APKs; check the example configurations and ignore rules.
- [x] Scan the intended source tree with Gitleaks and targeted patterns;
  inspect matches and the tracked file list.
- [x] Scan the initial commit with Gitleaks.
- [x] Inspect screenshots, PNG metadata, generated sources, tests, assets and
  CI. The workflow does not inject real credentials or publish APKs.
- [x] Preserve upstream MIT attribution and copyright and include the Inter
  OFL license. Replace the inherited branded splash image with the existing
  generic icon; see the [security review](SECURITY_REVIEW.md) for details.
- [x] Document credential-bearing APKs, Maps key restrictions, retained OAuth
  scopes, unencrypted vehicle metadata, polling costs and cleanup.
- [x] Run dependency resolution, source generation, analysis and tests in the
  release copy with placeholder configuration; verify offline Inter loading.
- [x] Build the Android debug APK with placeholder credentials and an isolated
  debug signing key. Verify the bundled fonts, compiled generic splash/icon and
  Maps placeholder; delete the temporary APK, key and build artifacts.
- [x] Review the release copy independently.
- [x] Verify a single parentless initial commit with no inherited history,
  branches, tags or remotes.

## Publication

- [x] The owner reviewed the copy and explicitly approved the first source push.
