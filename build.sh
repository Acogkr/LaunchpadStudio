#!/bin/bash
set -euo pipefail
STUDIO_SOURCE="$(cd "$(dirname "$0")" && pwd)"
STUDIO_BUILD="${STUDIO_BUILD_DIR:-$STUDIO_SOURCE/.build}"
STUDIO_DIST="${STUDIO_DIST_DIR:-$STUDIO_SOURCE/dist}"
STUDIO_VERSION="$(cat "$STUDIO_SOURCE/VERSION")"
STUDIO_NUMBER="$(cat "$STUDIO_SOURCE/BUILD_NUMBER")"
STUDIO_ARCHS="${STUDIO_ARCHS:-arm64 x86_64}"
ensure_app_is_stopped() {
  local executable="$STUDIO_DIST/Launchpad Studio.app/Contents/MacOS/LaunchpadStudio"
  if [ -f "$executable" ] && /usr/sbin/lsof -t -a -d txt "$executable" >/dev/null 2>&1; then
    printf 'Quit Launchpad Studio before rebuilding it.\n' >&2
    exit 1
  fi
}
ensure_app_is_stopped
[[ "$STUDIO_VERSION" =~ ^[0-9]+\.[0-9]+(\.[0-9]+)?$ && "$STUDIO_NUMBER" =~ ^[0-9]+$ ]] || { echo 'Invalid version metadata.' >&2; exit 1; }
mkdir -p "$STUDIO_BUILD" "$STUDIO_DIST"
STUDIO_STAGE="$(mktemp -d "$STUDIO_BUILD/bundle.XXXXXX")"
cleanup() {
  if [ -d "$STUDIO_STAGE/previous.app" ] && [ ! -e "$STUDIO_DIST/Launchpad Studio.app" ]; then
    if ! mv "$STUDIO_STAGE/previous.app" "$STUDIO_DIST/Launchpad Studio.app"; then
      printf 'Previous app preserved at: %s\n' "$STUDIO_STAGE/previous.app" >&2
      return 1
    fi
  fi
  rm -rf "$STUDIO_STAGE"
}
trap cleanup EXIT
STUDIO_APP="$STUDIO_STAGE/Launchpad Studio.app"
mkdir -p "$STUDIO_APP/Contents/MacOS" "$STUDIO_APP/Contents/Resources"
python3 "$STUDIO_SOURCE/Scripts/localizations.py" --output "$STUDIO_STAGE/localizations"
STUDIO_SOURCE_DIRS=("$STUDIO_SOURCE/Sources")
STUDIO_FLAGS=()
STUDIO_BUNDLE_ID="local.launchpadstudio.app"
STUDIO_DISPLAY_NAME="Launchpad Studio"
if [[ "${STUDIO_INCLUDE_TESTS:-0}" == 1 ]]; then
  STUDIO_SOURCE_DIRS+=("$STUDIO_SOURCE/Tests")
  STUDIO_FLAGS+=(-D STUDIO_TESTING)
  STUDIO_BUNDLE_ID="local.launchpadstudio.tests"
  STUDIO_DISPLAY_NAME="Launchpad Studio Tests"
fi
python3 - "${STUDIO_SOURCE_DIRS[@]}" > "$STUDIO_STAGE/sources.txt" <<'PY'
from pathlib import Path
import sys

for directory in sys.argv[1:]:
    for source in sorted(Path(directory).rglob('*.swift')):
        sys.stdout.buffer.write(str(source).encode() + b'\0')
PY
STUDIO_SOURCES=()
while IFS= read -r -d '' STUDIO_FILE; do
  STUDIO_SOURCES+=("$STUDIO_FILE")
done < "$STUDIO_STAGE/sources.txt"
[[ ${#STUDIO_SOURCES[@]} -gt 0 ]] || { echo 'No Swift sources found.' >&2; exit 1; }
STUDIO_BINARIES=()
for STUDIO_ARCH in $STUDIO_ARCHS; do
  [[ "$STUDIO_ARCH" == arm64 || "$STUDIO_ARCH" == x86_64 ]] || { echo "Unsupported architecture: $STUDIO_ARCH" >&2; exit 1; }
  STUDIO_BINARY="$STUDIO_STAGE/LaunchpadStudio-$STUDIO_ARCH"
  xcrun swiftc -swift-version 5 -O -parse-as-library -target "$STUDIO_ARCH-apple-macosx13.0" \
    ${STUDIO_FLAGS[@]+"${STUDIO_FLAGS[@]}"} "${STUDIO_SOURCES[@]}" \
    -framework AppKit -framework SwiftUI -framework CryptoKit -lsqlite3 -o "$STUDIO_BINARY"
  STUDIO_BINARIES+=("$STUDIO_BINARY")
done
[[ ${#STUDIO_BINARIES[@]} -gt 0 ]] || { echo 'Choose at least one architecture.' >&2; exit 1; }
xcrun lipo -create "${STUDIO_BINARIES[@]}" -output "$STUDIO_APP/Contents/MacOS/LaunchpadStudio"
cat > "$STUDIO_APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleExecutable</key><string>LaunchpadStudio</string>
<key>CFBundleIdentifier</key><string>$STUDIO_BUNDLE_ID</string>
<key>CFBundleName</key><string>$STUDIO_DISPLAY_NAME</string>
<key>CFBundleDisplayName</key><string>$STUDIO_DISPLAY_NAME</string>
<key>CFBundlePackageType</key><string>APPL</string>
<key>CFBundleShortVersionString</key><string>$STUDIO_VERSION</string>
<key>CFBundleVersion</key><string>$STUDIO_NUMBER</string>
<key>CFBundleDevelopmentRegion</key><string>en</string>
<key>CFBundleLocalizations</key><array><string>en</string><string>ko</string><string>ja</string><string>zh-Hans</string></array>
<key>LSMinimumSystemVersion</key><string>13.0</string>
<key>NSHighResolutionCapable</key><true/>
<key>NSAppleEventsUsageDescription</key><string>Use Finder to move selected files to Trash, restore them, or empty Trash when you request it.</string>
<key>NSAppBundlesUsageDescription</key><string>Move the apps you select to Trash.</string>
<key>NSAppDataUsageDescription</key><string>Find related files for the app you selected and move only the files you choose to Trash.</string>
<key>CFBundleIconFile</key><string>AppIcon</string>
</dict></plist>
PLIST
for STUDIO_LANGUAGE in en ko ja zh-Hans; do
  ditto "$STUDIO_STAGE/localizations/$STUDIO_LANGUAGE.lproj" "$STUDIO_APP/Contents/Resources/$STUDIO_LANGUAGE.lproj"
done
cp "$STUDIO_SOURCE/LICENSE" "$STUDIO_APP/Contents/Resources/LICENSE.txt"
# Sign before running the native slice to generate the icon.
codesign --force --sign - "$STUDIO_APP"
"$STUDIO_APP/Contents/MacOS/LaunchpadStudio" --write-icon "$STUDIO_STAGE/icon.png"
mkdir -p "$STUDIO_STAGE/AppIcon.iconset"
for STUDIO_SIZE in 16 32 128 256 512; do
  sips -z "$STUDIO_SIZE" "$STUDIO_SIZE" "$STUDIO_STAGE/icon.png" --out "$STUDIO_STAGE/AppIcon.iconset/icon_${STUDIO_SIZE}x${STUDIO_SIZE}.png" >/dev/null
  STUDIO_DOUBLE=$((STUDIO_SIZE * 2))
  sips -z "$STUDIO_DOUBLE" "$STUDIO_DOUBLE" "$STUDIO_STAGE/icon.png" --out "$STUDIO_STAGE/AppIcon.iconset/icon_${STUDIO_SIZE}x${STUDIO_SIZE}@2x.png" >/dev/null
done
iconutil -c icns "$STUDIO_STAGE/AppIcon.iconset" -o "$STUDIO_APP/Contents/Resources/AppIcon.icns"
codesign --force --sign - "$STUDIO_APP"
codesign --verify --deep --strict "$STUDIO_APP"
# Compilation takes time; the destination may have been launched in the meantime.
ensure_app_is_stopped
if [ -e "$STUDIO_DIST/Launchpad Studio.app" ]; then
  mv "$STUDIO_DIST/Launchpad Studio.app" "$STUDIO_STAGE/previous.app"
fi
mv "$STUDIO_APP" "$STUDIO_DIST/Launchpad Studio.app"
printf 'Built: %s\n' "$STUDIO_DIST/Launchpad Studio.app"
