#!/bin/bash
set -euo pipefail

project_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)"
output_dir="$project_dir/dist"
mkdir -p "$output_dir"

staging_dir="$(mktemp -d "$output_dir/.agent-hold-dmg.XXXXXX")"
trap 'find "$staging_dir" -depth -delete' EXIT
image_contents="$staging_dir/image"
app="$image_contents/Agent Todo.app"

"$project_dir/scripts/build-app.sh" universal "$image_contents"
ln -s /Applications "$image_contents/Applications"

version="$(plutil -extract CFBundleShortVersionString raw "$app/Contents/Info.plist")"
image_name="agent-todo-$version-macOS.dmg"
hdiutil create -srcfolder "$image_contents" -volname 'Agent Todo' \
    -fs HFS+ -format UDZO "$staging_dir/$image_name"
hdiutil verify "$staging_dir/$image_name"
mv -f "$staging_dir/$image_name" "$output_dir/$image_name"
printf '%s\n' "$output_dir/$image_name"
