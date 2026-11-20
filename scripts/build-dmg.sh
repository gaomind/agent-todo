#!/bin/bash
set -euo pipefail

project_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)"
output_dir="$project_dir/dist"
mkdir -p "$output_dir"

staging_dir="$(mktemp -d "$output_dir/.agent-hold-dmg.XXXXXX")"
image_contents="$staging_dir/image"
mount_point="$staging_dir/mount"
writable_image="$staging_dir/writable.dmg"
app="$image_contents/Agent Todo.app"
app_icon="$app/Contents/Resources/AppIcon.icns"

cleanup() {
    local mount_device staging_device
    if [[ -d "$mount_point" ]]; then
        mount_device="$(stat -f '%d' "$mount_point")" || return 1
        staging_device="$(stat -f '%d' "$staging_dir")" || return 1
        if [[ "$mount_device" != "$staging_device" ]] && ! hdiutil detach "$mount_point"; then
            printf 'Unable to eject the disk image at %s\n' "$mount_point" >&2
            return 1
        fi
    fi
    find -x "$staging_dir" -depth -delete
}
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

"$project_dir/scripts/build-app.sh" universal "$image_contents"
ln -s /Applications "$image_contents/Applications"
cp "$app_icon" "$image_contents/.VolumeIcon.icns"

version="$(plutil -extract CFBundleShortVersionString raw "$app/Contents/Info.plist")"
image_name="agent-todo-$version-macOS.dmg"
image="$staging_dir/$image_name"
archive_name="agent-todo-$version-macOS-Finder.zip"

# hdiutil does not copy the source folder's Finder flags to the volume root.
hdiutil create -srcfolder "$image_contents" -volname 'Agent Todo' \
    -fs HFS+ -format UDRW "$writable_image"
mkdir "$mount_point"
hdiutil attach -nobrowse -noautoopen -mountpoint "$mount_point" "$writable_image"
SetFile -a C "$mount_point"
hdiutil detach "$mount_point"
hdiutil convert "$writable_image" -format UDZO -o "$image"
hdiutil verify "$image"

# Finder uses a resource fork for the icon of the DMG file itself.
swift - "$app_icon" "$image" <<'SWIFT'
import AppKit

let iconPath = CommandLine.arguments[1]
let imagePath = CommandLine.arguments[2]
guard let icon = NSImage(contentsOfFile: iconPath),
      NSWorkspace.shared.setIcon(icon, forFile: imagePath) else {
    FileHandle.standardError.write(Data("Failed to set the disk image icon.\n".utf8))
    exit(EXIT_FAILURE)
}
SWIFT

# Preserve the resource fork and Finder metadata across downloads.
ditto -c -k --sequesterRsrc "$image" "$staging_dir/$archive_name"
mv -f "$image" "$output_dir/$image_name"
mv -f "$staging_dir/$archive_name" "$output_dir/$archive_name"
printf '%s\n' "$output_dir/$image_name" "$output_dir/$archive_name"
