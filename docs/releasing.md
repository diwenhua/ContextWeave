# Branches and releases

`main` is the integration branch. Create short-lived feature or fix branches and merge through a pull request after macOS CI passes. Administrators should follow the same workflow.

Stable version tags use `vMAJOR.MINOR.PATCH`, for example `v0.1.0`, and must point to a commit reachable from `main`. Pushing a tag starts the release workflow, which builds and tests the app, creates an unsigned DMG for the runner architecture, generates a SHA-256 checksum, and creates a **draft** GitHub Release. Manually review the draft before publishing. To test packaging without creating a tag or release, run the workflow with `workflow_dispatch`; download its workflow artifact.

The current package is an unsigned development artifact and is not notarized. Gatekeeper may block it. Before public distribution, add Developer ID signing, notarization, appropriate release notes, and test installation on supported macOS versions and architectures. In-app updates are not configured.

After the workflow is on `main`, a maintainer can create a release tag from the intended `main` commit:

```sh
git switch main
git pull --ff-only
git tag -a v0.1.0 -m "v0.1.0"
git push origin v0.1.0
```

A published tag should not be moved or reused. If packaging fails before the draft is created, correct the problem and create a new version tag; check existing drafts and assets before rerunning.
