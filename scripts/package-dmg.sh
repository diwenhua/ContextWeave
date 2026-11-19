#!/bin/sh
set -eu
cd "$(dirname "$0")/.."
version=${CONTEXTWEAVE_VERSION:-0.1.0}
case "$version" in *[!0-9.]*|'') echo "Invalid version" >&2; exit 1;; esac
./scripts/build-app.sh
arch=$(uname -m)
case "$arch" in arm64|x86_64) ;; *) echo "Unsupported architecture: $arch" >&2; exit 1;; esac
staging=$(mktemp -d "${TMPDIR:-/tmp}/contextweave-dmg.XXXXXX")
trap 'rm -rf "$staging"' EXIT HUP INT TERM
cp -R dist/ContextWeave.app "$staging/"
ln -s /Applications "$staging/Applications"
suffix=-unsigned
if [ -n "${CONTEXTWEAVE_SIGNING_IDENTITY:-}" ]; then
    : "${APPLE_ID:?Required for notarization}" "${APPLE_TEAM_ID:?Required for notarization}" \
        "${APPLE_APP_SPECIFIC_PASSWORD:?Required for notarization}"
    suffix=
fi
output="$PWD/dist/ContextWeave-${version}-macOS-${arch}${suffix}.dmg"
if [ -e "$output" ]; then echo "Refusing to overwrite $output" >&2; exit 1; fi
hdiutil create -volname "ContextWeave" -srcfolder "$staging" -format UDZO "$output"
if [ -n "${CONTEXTWEAVE_SIGNING_IDENTITY:-}" ]; then
    codesign --sign "$CONTEXTWEAVE_SIGNING_IDENTITY" --timestamp "$output"
    codesign --verify --strict "$output"
    if ! xcrun notarytool submit "$output" --apple-id "$APPLE_ID" --team-id "$APPLE_TEAM_ID" \
        --password "$APPLE_APP_SPECIFIC_PASSWORD" --wait --timeout 20m --output-format json \
        > "$staging/notary.json"; then
        cat "$staging/notary.json" >&2
        exit 1
    fi
    cat "$staging/notary.json"
    status=$(plutil -extract status raw "$staging/notary.json")
    if [ "$status" != Accepted ]; then
        submission=$(plutil -extract id raw "$staging/notary.json")
        xcrun notarytool log "$submission" --apple-id "$APPLE_ID" --team-id "$APPLE_TEAM_ID" \
            --password "$APPLE_APP_SPECIFIC_PASSWORD" >&2
        exit 1
    fi
    xcrun stapler staple "$output"
    xcrun stapler validate "$output"
fi
(cd dist && shasum -a 256 "$(basename "$output")" > "$(basename "$output").sha256")
printf 'Created disk image: %s\n' "$output"
