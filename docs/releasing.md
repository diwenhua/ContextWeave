# Branches and releases

`main` is the integration branch. Create short-lived feature or fix branches and merge through a pull request after macOS CI passes. Administrators should follow the same workflow.

Stable tags use `vMAJOR.MINOR.PATCH` and must point to a commit reachable from `main`. Pushing a tag builds and tests the app on macOS, signs the runner-architecture DMG, and submits it to Apple. Resume that submission to generate the notarized package and create its draft GitHub Release.

In GitHub repository settings, create the `macos-release` environment and configure its secrets:

| Secret | Value |
| --- | --- |
| `MACOS_CERTIFICATE_BASE64` | Base64-encoded password-protected PKCS#12 export of the Developer ID Application identity |
| `MACOS_CERTIFICATE_PASSWORD` | Password for the PKCS#12 export |
| `APPLE_ID` | Apple Account used for notarization |
| `APPLE_TEAM_ID` | Developer ID signing team |
| `APPLE_APP_SPECIFIC_PASSWORD` | App-specific password for notarization |

Restrict the release environment to the trusted `main` branch and release tags.

1. To test signing and submission, run **Release draft → Run workflow** on `main` and enable **Sign and submit a test DMG to Apple**. A release tag runs this phase automatically. The run summary records the Apple submission ID and the GitHub run ID. The `notarization-pending` artifact holds the original signed DMG, its checksum, and submission metadata.
2. Run the same workflow on `main` with `resume_run_id` set to the original submission run ID. While Apple reports **In Progress**, the check exits and the original artifact remains available for another check. If Apple accepts the submission, the workflow staples and verifies the ticket, generates the final SHA-256 checksum, and uploads `signed-macos-package`. A submission originally built from a release tag also creates a draft GitHub Release if one does not exist. Resume before the original artifact expires.

The default manual run with neither input set produces an unsigned development package, which Gatekeeper may block. In-app updates are not configured for public distribution.

After the workflow is on `main`, a maintainer can create a release tag from the intended `main` commit:

```sh
git switch main
git pull --ff-only
git tag -a v0.1.0 -m "v0.1.0"
git push origin v0.1.0
```

A published tag should not be moved or reused. If packaging fails before the draft is created, correct the problem and create a new version tag; check existing drafts and assets before rerunning.
