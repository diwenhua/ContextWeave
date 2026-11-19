#!/bin/bash
set -euo pipefail

pending="$1"
output="$2"
: "${APPLE_ID:?Required for notarization}" "${APPLE_TEAM_ID:?Required for notarization}" \
    "${APPLE_APP_SPECIFIC_PASSWORD:?Required for notarization}"

submission=$(cat "$pending/submission-id")
if [[ ! "$submission" =~ ^[0-9a-fA-F]{8}(-[0-9a-fA-F]{4}){3}-[0-9a-fA-F]{12}$ ]]; then
    echo "Invalid Apple submission ID" >&2
    exit 1
fi
shopt -s nullglob
images=("$pending"/ContextWeave-*.dmg)
if [[ ${#images[@]} != 1 ]]; then
    echo "Expected exactly one signed ContextWeave disk image" >&2
    exit 1
fi
image="${images[0]}"
digest=$(shasum -a 256 "$image" | cut -d ' ' -f 1)
if [[ "$digest" != "$(cat "$pending/dmg.sha256")" ]]; then
    echo "Original disk image checksum mismatch" >&2
    exit 1
fi

credentials=(--apple-id "$APPLE_ID" --team-id "$APPLE_TEAM_ID" --password "$APPLE_APP_SPECIFIC_PASSWORD")
result=$(xcrun notarytool info "$submission" "${credentials[@]}" --output-format json)
status=$(printf '%s' "$result" | plutil -extract status raw -o - -)
printf 'Apple submission %s: %s\n' "$submission" "$status"
case "$status" in
    'In Progress')
        echo 'Apple is still reviewing this DMG. Run the resume step again with the same source run ID.'
        exit 0
        ;;
    Accepted) ;;
    *)
        xcrun notarytool log "$submission" "${credentials[@]}" >&2
        exit 1
        ;;
esac

mkdir -p "$output"
name="${image##*/}"
cp "$image" "$output/$name"
xcrun stapler staple "$output/$name"
xcrun stapler validate "$output/$name"
codesign --verify --strict "$output/$name"
(cd "$output" && shasum -a 256 "$name" > "$name.sha256")
