#!/bin/sh
# Work around a stale private PackageDescription interface in some CLT installs.
set -eu
cd "$(dirname "$0")/.."
manifest_dir="$(xcode-select -p)/usr/lib/swift/pm/ManifestAPI"
private_interface="$manifest_dir/PackageDescription.swiftmodule/arm64-apple-macos.private.swiftinterface"
public_interface="$manifest_dir/PackageDescription.swiftmodule/arm64-apple-macos.swiftinterface"
if [ "$(uname -m)" = arm64 ] && [ -f "$private_interface" ] && [ -f "$public_interface" ] && grep -q 'enum SwiftVersion' "$private_interface" && grep -q 'enum SwiftLanguageMode' "$public_interface"; then
    overlay="$PWD/.build/local-toolchain"
    mkdir -p "$overlay/ManifestAPI" "$PWD/.build/module-cache"
    cp -R "$manifest_dir/." "$overlay/ManifestAPI/"
    cp "$public_interface" "$overlay/ManifestAPI/PackageDescription.swiftmodule/arm64-apple-macos.private.swiftinterface"
    export SWIFTPM_CUSTOM_LIBS_DIR="$overlay"
    export CLANG_MODULE_CACHE_PATH="$PWD/.build/module-cache"
    export SWIFTPM_MODULECACHE_OVERRIDE="$PWD/.build/module-cache"
fi
exec swift "$@"
