# Public source release checklist

The [destination repository](https://github.com/DreamMakers2/Tesla-Summon-Anywhere)
is already public. Do not push source until the owner explicitly approves the
first publication. Do not change either repository's visibility.

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
  generic icon; see the [security review](SECURITY_REVIEW.md) for limits.
- [x] Document credential-bearing APKs, Maps key restrictions, retained OAuth
  scopes, unencrypted vehicle metadata, polling costs and cleanup limitations.
- [x] Run dependency resolution, source generation, analysis and tests in the
  release copy with placeholder configuration; verify offline Inter loading.
- [x] Review the release copy independently.
- [x] Verify a single parentless initial commit with no inherited history,
  branches, tags or remotes.

## Pending before publication

- [ ] The owner reviews the copy, remaining risks and licensing and explicitly
  approves the first public push.

## Verification limits

The owner reported successful real-device/Tesla testing of the source baseline.
The prepared release copy, including its bundled fonts and changed splash
resource, has not been tested in a new Android build or on a device. Source
checks cannot establish Fleet API access, map authorization or GPS cleanup on a
different device. The app embeds credentials in local APKs; never distribute
an APK built with real credentials. The minimum working OAuth scopes have not
been verified, and selected vehicle ID and name remain in ordinary app-local
SharedPreferences. See [SECURITY.md](../SECURITY.md) and the
[security review](SECURITY_REVIEW.md).
