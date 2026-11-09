#!/bin/sh
# Build all standard macOS icon representations from the checked-in master.
set -eu
cd "$(dirname "$0")/.."
source_icon="$PWD/Sources/ContextWeaveApp/Resources/AppIcon.png"
output_dir="$PWD/.build/icon-assets"
icon_work=$(mktemp -d "${TMPDIR:-/tmp}/contextweave-icon.XXXXXX")
trap 'rm -rf "$icon_work"' EXIT HUP INT TERM
iconset="$icon_work/ContextWeave.iconset"
mkdir -p "$iconset" "$output_dir"
for size in 16 32 128 256 512; do
    sips -z "$size" "$size" "$source_icon" --out "$iconset/icon_${size}x${size}.png" >/dev/null
    retina_size=$((size * 2))
    sips -z "$retina_size" "$retina_size" "$source_icon" --out "$iconset/icon_${size}x${size}@2x.png" >/dev/null
done
iconutil -c icns "$iconset" -o "$output_dir/ContextWeave.icns"
printf 'Built %s\n' "$output_dir/ContextWeave.icns"
