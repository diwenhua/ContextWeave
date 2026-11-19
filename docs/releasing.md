# Branches and releases

`main` is the integration branch. Create short-lived feature or fix branches and merge through a pull request after macOS CI passes. Administrators should follow the same workflow.

Stable tags use `vMAJOR.MINOR.PATCH` and must point to a commit reachable from `main`. Pushing a tag builds and tests the app on macOS, signs and notarizes the runner-architecture DMG, generates a SHA-256 checksum, and uploads both files to a draft GitHub Release for manual review.

In GitHub repository settings, create the `macos-release` environment and configure its secrets:

| Secret | Value |
| --- | --- |
| `MACOS_CERTIFICATE_BASE64` | Base64-encoded password-protected PKCS#12 export of the Developer ID Application identity |
| `MACOS_CERTIFICATE_PASSWORD` | Password for the PKCS#12 export |
| `APPLE_ID` | Apple Account used for notarization |
| `APPLE_TEAM_ID` | Developer ID signing team |
| `APPLE_APP_SPECIFIC_PASSWORD` | App-specific password for notarization |

Restrict the release environment to the trusted `main` branch and release tags. Use **Release draft → Run workflow** on `main` with **Sign and notarize this test DMG** enabled to check signing and notarization before tagging. Download the `signed-macos-package` artifact. The default manual run produces an unsigned development package, which Gatekeeper may block. Manual runs do not create GitHub Releases. In-app updates are not configured for public distribution.

After the workflow is on `main`, a maintainer can create a release tag from the intended `main` commit:

```sh
git switch main
git pull --ff-only
git tag -a v0.1.0 -m "v0.1.0"
git push origin v0.1.0
```

A published tag should not be moved or reused. If packaging fails before the draft is created, correct the problem and create a new version tag; check existing drafts and assets before rerunning.
