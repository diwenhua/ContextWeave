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
output="$PWD/dist/ContextWeave-${version}-macOS-${arch}-unsigned.dmg"
if [ -e "$output" ]; then echo "Refusing to overwrite $output" >&2; exit 1; fi
hdiutil create -volname "ContextWeave" -srcfolder "$staging" -format UDZO "$output"
(cd dist && shasum -a 256 "$(basename "$output")" > "$(basename "$output").sha256")
printf 'Created unsigned development artifact: %s\n' "$output"
