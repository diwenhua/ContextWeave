# Branches and releases

`main` is the shared branch for integration and testing. Create short-lived feature or fix branches and merge through a pull request after macOS CI passes. Administrators should follow the same workflow.

1. **Merge changes.** Each merge to `main` runs macOS CI to build and test the app. Release packaging and public Sparkle updates have separate triggers.
2. **Build a test DMG when needed.** In GitHub Actions, open **Release draft → Run workflow**, select `main`, and leave the inputs at their defaults. Download `unsigned-macos-package` from that run. Record the commit SHA shown on the run page and verify the changes using that DMG.
3. **Push a release tag.** When a group of changes is ready to ship, tag the exact tested commit, even if more changes have since landed on `main`. The tag triggers the signed DMG build and Apple notarization submission. After Apple accepts it, resume the workflow to staple the ticket and create the GitHub Release draft.
4. **Publish the stable release.** Review the draft and publish it as the latest stable release. This triggers the public Sparkle appcast update. Manual installation and Sparkle updates use the same final, notarized DMG from GitHub Releases.

Stable tags use `vMAJOR.MINOR.PATCH` and must point to a commit reachable from `main`. Pushing a tag builds and tests the app on macOS, signs the runner-architecture DMG, and submits it to Apple. Resume that submission to generate the notarized package and create its draft GitHub Release.

In GitHub repository settings, create the `macos-release` environment and configure its secrets:

| Secret | Value |
| --- | --- |
| `MACOS_CERTIFICATE_BASE64` | Base64-encoded password-protected PKCS#12 export of the Developer ID Application identity |
| `MACOS_CERTIFICATE_PASSWORD` | Password for the PKCS#12 export |
| `APPLE_ID` | Apple Account used for notarization |
| `APPLE_TEAM_ID` | Developer ID signing team |
| `APPLE_APP_SPECIFIC_PASSWORD` | App-specific password for notarization |
| `SPARKLE_PRIVATE_KEY` | Sparkle EdDSA private key matching the public key in the tagged app |

Restrict the release environment to the trusted `main` branch and release tags.

1. To test signing and submission, run **Release draft → Run workflow** on `main` and enable **Sign and submit a test DMG to Apple**. A release tag runs this phase automatically. The run summary records the Apple submission ID and the GitHub run ID. The `notarization-pending` artifact holds the original signed DMG, its checksum, and submission metadata.
2. Run the same workflow on `main` with `resume_run_id` set to the original submission run ID. While Apple reports **In Progress**, the check exits and the original artifact remains available for another check. If Apple accepts the submission, the workflow staples and verifies the ticket, generates the final SHA-256 checksum, and uploads `signed-macos-package`. A submission originally built from a release tag also creates a draft GitHub Release if one does not exist. Resume before the original artifact expires.

The default manual run with neither input set produces an unsigned development package, which Gatekeeper may block. Manual test packages use the local Sparkle feed.

To start a release, replace `<tested-commit-sha>` with the commit SHA from the test DMG run and choose the version:

```sh
git fetch origin main
git tag -a v0.1.0 -m "v0.1.0" <tested-commit-sha>
git push origin v0.1.0
```

A published tag should not be moved or reused. If packaging fails before the draft is created, correct the problem and create a new version tag; check existing drafts and assets before rerunning.

## Public Sparkle updates

The tagged app uses the public [appcast](https://raw.githubusercontent.com/diwenhua/ContextWeave/sparkle-feed/appcast.xml). Install the first release with this configuration from GitHub Releases to start receiving public updates. Automatic checks are still opt-in in the app.

Review the notarized arm64 DMG in the draft and publish the release as the latest stable version. Publishing starts **Publish Sparkle feed**. The workflow downloads that release's final DMG, verifies its Apple signature and stapled ticket, signs the same bytes with Sparkle EdDSA, and signs the appcast. The appcast points to the existing release asset. The workflow creates or updates the `sparkle-feed` branch. If publishing the feed fails, run **Publish Sparkle feed → Run workflow** on `main` to retry using the latest stable release.

Keep the Sparkle private key backed up securely and keep it out of Git. The corresponding public key is embedded in tagged releases. A change to an already published DMG invalidates its Sparkle signature.
