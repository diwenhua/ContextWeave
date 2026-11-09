#!/bin/sh
set -eu
cd "$(dirname "$0")/.."
version=${CONTEXTWEAVE_VERSION:-0.1.0}
build_number=${CONTEXTWEAVE_BUILD_NUMBER:-1}
case "$version" in *[!0-9.]*|'') echo "Invalid version" >&2; exit 1;; esac
case "$build_number" in *[!0-9]*|'') echo "Invalid build number" >&2; exit 1;; esac
./scripts/swift-local.sh build -c release --product ContextWeave
binary_path=$(./scripts/swift-local.sh build -c release --show-bin-path)
app_dir="$PWD/dist/ContextWeave.app"
mkdir -p "$app_dir/Contents/MacOS" "$app_dir/Contents/Frameworks"
framework=$(find .build/artifacts -type d -name Sparkle.framework -path "*macos*" -print -quit)
if [ -z "$framework" ]; then echo "Sparkle.framework not found in SwiftPM artifacts" >&2; exit 1; fi
ditto "$framework" "$app_dir/Contents/Frameworks/Sparkle.framework"
cp "$binary_path/ContextWeave" "$app_dir/Contents/MacOS/ContextWeave"
mkdir -p "$app_dir/Contents/Resources"
cp -R "$binary_path/ContextWeave_ContextWeaveApp.bundle" "$app_dir/Contents/Resources/"
cat > "$app_dir/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleDevelopmentRegion</key><string>en</string>
<key>CFBundleLocalizations</key><array><string>en</string><string>zh-Hans</string></array>
<key>CFBundleName</key><string>ContextWeave</string>
<key>CFBundleDisplayName</key><string>ContextWeave</string>
<key>CFBundleIdentifier</key><string>local.contextweave.app</string>
<key>CFBundleExecutable</key><string>ContextWeave</string>
<key>CFBundlePackageType</key><string>APPL</string>
<key>CFBundleShortVersionString</key><string>$version</string>
<key>CFBundleVersion</key><string>$build_number</string>
<key>LSMinimumSystemVersion</key><string>13.0</string>
<key>NSHighResolutionCapable</key><true/>
<key>SUFeedURL</key><string>http://127.0.0.1:8765/appcast.xml</string>
<key>SUPublicEDKey</key><string>pwOAK2xEkG20mV+hUoDC69S+fb5gryk8oEqHg9ZPvgM=</string>
<key>SUEnableAutomaticChecks</key><false/>
<key>NSAppTransportSecurity</key><dict><key>NSAllowsLocalNetworking</key><true/></dict>
</dict></plist>
PLIST
printf 'Built %s\n' "$app_dir"
