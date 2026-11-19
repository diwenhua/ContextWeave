#!/bin/bash
set -euo pipefail

: "${GITHUB_REPOSITORY:?Required}" "${RUNNER_TEMP:?Required}"
: "${APPLE_TEAM_ID:?Missing Developer ID team}" "${SPARKLE_PRIVATE_KEY:?Missing Sparkle signing key}"
if [[ ! "$APPLE_TEAM_ID" =~ ^[A-Z0-9]{10}$ ]]; then
    echo 'Invalid Developer ID team' >&2
    exit 1
fi

work=$(mktemp -d "$RUNNER_TEMP/sparkle-feed.XXXXXX")
mount="$work/mount"
feed_checkout="$work/feed"
mounted=false
cleanup() {
    if [[ "$mounted" == true ]]; then
        hdiutil detach "$mount" >&2 || true
    fi
    if [[ -d "$feed_checkout" ]]; then
        git worktree remove --force "$feed_checkout" >&2 || true
    fi
    rm -rf "$work"
}
trap cleanup EXIT

release=$(gh api "repos/$GITHUB_REPOSITORY/releases/latest")
tag=$(jq -er '.tag_name | select(test("^v(0|[1-9][0-9]*)\\.(0|[1-9][0-9]*)\\.(0|[1-9][0-9]*)$"))' <<< "$release")
asset=$(jq -ec --arg version "${tag#v}" '
    [.assets[] | select(.state == "uploaded" and
       .name == ("ContextWeave-" + $version + "-macOS-arm64.dmg"))]
    | if length == 1 then .[0] else error("Expected one release arm64 DMG") end
' <<< "$release")
name=$(jq -r .name <<< "$asset")
url=$(jq -r .browser_download_url <<< "$asset")
published=$(jq -r .published_at <<< "$release")
dmg="$work/$name"
gh release download "$tag" --repo "$GITHUB_REPOSITORY" --pattern "$name" --dir "$work"

requirement="anchor apple generic and certificate leaf[field.1.2.840.113635.100.6.1.13] exists and certificate leaf[subject.OU] = \"$APPLE_TEAM_ID\""
codesign --verify --strict -R="$requirement" "$dmg"
xcrun stapler validate "$dmg"
mkdir "$mount"
hdiutil attach -readonly -nobrowse -mountpoint "$mount" "$dmg" >/dev/null
mounted=true
app="$mount/ContextWeave.app"
codesign --verify --strict -R="$requirement" "$app"
plist="$app/Contents/Info.plist"
version=$(plutil -extract CFBundleShortVersionString raw "$plist")
build=$(plutil -extract CFBundleVersion raw "$plist")
minimum=$(plutil -extract LSMinimumSystemVersion raw "$plist")
public_key=$(plutil -extract SUPublicEDKey raw "$plist")
feed_url="https://raw.githubusercontent.com/$GITHUB_REPOSITORY/sparkle-feed/appcast.xml"
[[ "$version" == "${tag#v}" && "$build" =~ ^[1-9][0-9]*$ ]]
[[ "$(plutil -extract SUFeedURL raw "$plist")" == "$feed_url" ]]
[[ "$(plutil -extract SURequireSignedFeed raw "$plist")" == true ]]
hdiutil detach "$mount" >/dev/null
mounted=false

# Resolve the same pinned Sparkle distribution used to build the app.
SPARKLE_KEY_FOR_SIGNING=$SPARKLE_PRIVATE_KEY
unset SPARKLE_PRIVATE_KEY
swift package resolve
sign_update=$(find .build/artifacts/sparkle -type f -path '*/bin/sign_update' -print -quit)
test -x "$sign_update"
signature=$(printf '%s' "$SPARKLE_KEY_FOR_SIGNING" | "$sign_update" --ed-key-file - -p "$dmg")

# Check against the public key actually embedded in the distributed application.
cat > "$work/verify.swift" <<'SWIFT'
import CryptoKit
import Foundation

let args = CommandLine.arguments
let key = try Curve25519.Signing.PublicKey(rawRepresentation: Data(base64Encoded: args[2]) ?? Data())
let signature = Data(base64Encoded: args[3]) ?? Data()
let message = try Data(contentsOf: URL(fileURLWithPath: args[1]), options: .mappedIfSafe)
guard key.isValidSignature(signature, for: message) else {
    fatalError("Sparkle signing key does not match the public key in the release DMG")
}
SWIFT
xcrun --sdk macosx swift "$work/verify.swift" "$dmg" "$public_key" "$signature"

python3 - "$work/appcast.xml" "$version" "$build" "$minimum" "$url" "$published" "$signature" "$(stat -f %z "$dmg")" <<'PYTHON'
import sys
from datetime import datetime
from email.utils import format_datetime
from xml.etree import ElementTree as ET

path, version, build, minimum, url, published, signature, size = sys.argv[1:]
namespace = "http://www.andymatuschak.org/xml-namespaces/sparkle"
ET.register_namespace("sparkle", namespace)
rss = ET.Element("rss", version="2.0")
channel = ET.SubElement(rss, "channel")
ET.SubElement(channel, "title").text = "ContextWeave Updates"
item = ET.SubElement(channel, "item")
ET.SubElement(item, "title").text = f"ContextWeave {version}"
ET.SubElement(item, "pubDate").text = format_datetime(datetime.fromisoformat(published.replace("Z", "+00:00")))
for name, value in (
    ("version", build),
    ("shortVersionString", version),
    ("minimumSystemVersion", minimum),
    ("hardwareRequirements", "arm64"),
):
    ET.SubElement(item, f"{{{namespace}}}{name}").text = value
ET.SubElement(item, "enclosure", {
    "url": url,
    "length": size,
    "type": "application/octet-stream",
    f"{{{namespace}}}edSignature": signature,
})
ET.indent(rss)
ET.ElementTree(rss).write(path, encoding="utf-8", xml_declaration=True)
PYTHON
printf '%s' "$SPARKLE_KEY_FOR_SIGNING" | "$sign_update" --ed-key-file - "$work/appcast.xml"
unset SPARKLE_KEY_FOR_SIGNING

# Keep the public feed on its own branch and never force-push it.
if [[ -n "$(git ls-remote origin refs/heads/sparkle-feed)" ]]; then
    git fetch origin refs/heads/sparkle-feed
    git worktree add --detach "$feed_checkout" FETCH_HEAD
else
    git worktree add --detach "$feed_checkout" HEAD
    git -C "$feed_checkout" switch --orphan sparkle-feed
fi
cp "$work/appcast.xml" "$feed_checkout/appcast.xml"
git -C "$feed_checkout" add appcast.xml
if git -C "$feed_checkout" diff --cached --quiet; then
    echo "Sparkle already advertises $tag"
    exit 0
fi
git -C "$feed_checkout" -c user.name='github-actions[bot]' \
    -c user.email='41898282+github-actions[bot]@users.noreply.github.com' \
    commit -m "Publish Sparkle update for $tag"
git -C "$feed_checkout" push origin HEAD:refs/heads/sparkle-feed
printf 'Published Sparkle appcast for %s\n' "$tag"
