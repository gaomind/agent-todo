#!/bin/bash
set -euo pipefail

project_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)"
cd "$project_dir"

icon_source="$project_dir/Assets/AppIcon.png"
if [[ ! -r "$icon_source" ]]; then
    printf 'Missing app icon: %s\n' "$icon_source" >&2
    exit 1
fi

architecture="${1:-native}"
app_parent="${2:-$project_dir/dist}"
case "$architecture" in
    native|universal) ;;
    *)
        printf 'Usage: %s [native|universal] [output-directory]\n' "$0" >&2
        exit 1
        ;;
esac
mkdir -p "$app_parent"
app_parent="$(cd "$app_parent" && pwd -P)"
app_path="$app_parent/Agent 待办.app"
staging_dir="$(mktemp -d "$app_parent/.agent-hold.XXXXXX")"
trap 'if [[ -d "$staging_dir" ]]; then find "$staging_dir" -depth -delete; fi' EXIT
staged_app="$staging_dir/Agent 待办.app"
iconset="$staging_dir/AppIcon.iconset"
mkdir -p "$staged_app/Contents/MacOS" "$staged_app/Contents/Resources" "$iconset"
if [[ "$architecture" == universal ]]; then
    # Build slices separately so the Command Line Tools work without Xcode's build system.
    for arch in arm64 x86_64; do
        swift build --configuration release --arch "$arch"
    done
    arm_dir="$(swift build --configuration release --arch arm64 --show-bin-path)"
    intel_dir="$(swift build --configuration release --arch x86_64 --show-bin-path)"
    for executable in AgentHold AgentHoldHook; do
        binary="$staged_app/Contents/MacOS/$executable"
        lipo -create "$arm_dir/$executable" "$intel_dir/$executable" -output "$binary"
        strip -S "$binary"
        chmod 755 "$binary"
        lipo "$binary" -verify_arch arm64 x86_64
    done
else
    swift build --configuration release
    binary_dir="$(swift build --configuration release --show-bin-path)"
    for executable in AgentHold AgentHoldHook; do
        install -m 755 "$binary_dir/$executable" "$staged_app/Contents/MacOS/$executable"
    done
fi

for size in 16 32 128 256 512; do
    sips -z "$size" "$size" "$icon_source" --out "$iconset/icon_${size}x${size}.png" >/dev/null
    double_size=$((size * 2))
    sips -z "$double_size" "$double_size" "$icon_source" --out "$iconset/icon_${size}x${size}@2x.png" >/dev/null
done
iconutil -c icns "$iconset" -o "$staged_app/Contents/Resources/AppIcon.icns"

cat > "$staged_app/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleDevelopmentRegion</key>
    <string>zh_CN</string>
    <key>CFBundleDisplayName</key>
    <string>Agent 待办</string>
    <key>CFBundleExecutable</key>
    <string>AgentHold</string>
    <key>CFBundleIdentifier</key>
    <string>local.agenthold.app</string>
    <key>CFBundleIconFile</key>
    <string>AppIcon.icns</string>
    <key>CFBundleInfoDictionaryVersion</key>
    <string>6.0</string>
    <key>CFBundleName</key>
    <string>AgentHold</string>
    <key>CFBundlePackageType</key>
    <string>APPL</string>
    <key>CFBundleShortVersionString</key>
    <string>0.0.1</string>
    <key>CFBundleVersion</key>
    <string>1</string>
    <key>LSMinimumSystemVersion</key>
    <string>13.0</string>
    <key>LSUIElement</key>
    <true/>
    <key>NSHighResolutionCapable</key>
    <true/>
</dict>
</plist>
PLIST

plutil -lint "$staged_app/Contents/Info.plist"
codesign --force --sign - "$staged_app/Contents/MacOS/AgentHoldHook"
codesign --force --sign - "$staged_app"
codesign --verify --strict --deep "$staged_app"
if [[ -d "$app_path" ]]; then
    mv "$app_path" "$staging_dir/Previous.app"
fi
if ! mv "$staged_app" "$app_path"; then
    if [[ -d "$staging_dir/Previous.app" ]]; then
        mv "$staging_dir/Previous.app" "$app_path"
    fi
    exit 1
fi
printf '%s\n' "$app_path"
