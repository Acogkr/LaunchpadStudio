#!/bin/bash
set -euo pipefail
STUDIO_SOURCE="$(cd "$(dirname "$0")" && pwd)"
STUDIO_BUILD="${STUDIO_BUILD_DIR:-$STUDIO_SOURCE/.build}"
STUDIO_DIST="${STUDIO_DIST_DIR:-$STUDIO_SOURCE/dist}"
STUDIO_APP="$STUDIO_DIST/Launchpad Studio.app"
STUDIO_VERSION="$(cat "$STUDIO_SOURCE/VERSION")"
STUDIO_ACTUAL_VERSION="$(/usr/libexec/PlistBuddy -c 'Print CFBundleShortVersionString' "$STUDIO_APP/Contents/Info.plist")"
[[ "$STUDIO_VERSION" == "$STUDIO_ACTUAL_VERSION" ]] || { echo 'Build version differs from VERSION. Run build.sh first.' >&2; exit 1; }
[[ "$(/usr/libexec/PlistBuddy -c 'Print CFBundleVersion' "$STUDIO_APP/Contents/Info.plist")" == "$(cat "$STUDIO_SOURCE/BUILD_NUMBER")" ]] || { echo 'Build number is stale. Run build.sh first.' >&2; exit 1; }
xcrun lipo "$STUDIO_APP/Contents/MacOS/LaunchpadStudio" -verify_arch arm64 x86_64
/usr/bin/codesign --verify --deep --strict "$STUDIO_APP"
mkdir -p "$STUDIO_BUILD"
STUDIO_STAGE="$(mktemp -d "$STUDIO_BUILD/dmg.XXXXXX")"
trap 'rm -rf "$STUDIO_STAGE"' EXIT
if [[ -n "${STUDIO_DMG_PYTHON:-}" ]]; then
  [[ -x "$STUDIO_DMG_PYTHON" ]] || { echo 'STUDIO_DMG_PYTHON must point to an existing Python executable.' >&2; exit 1; }
else
  STUDIO_DMG_PYTHON="$STUDIO_BUILD/dmg-venv/bin/python"
  if [[ ! -x "$STUDIO_DMG_PYTHON" ]]; then
    STUDIO_PYTHON=""
    for STUDIO_CANDIDATE in python3 python3.13 python3.12 python3.11 python3.10; do
      if command -v "$STUDIO_CANDIDATE" >/dev/null && "$STUDIO_CANDIDATE" -c 'import sys; sys.exit(sys.version_info < (3, 10))'; then
        STUDIO_PYTHON="$STUDIO_CANDIDATE"; break
      fi
    done
    [[ -n "$STUDIO_PYTHON" ]] || { echo 'Packaging requires Python 3.10 or later.' >&2; exit 1; }
    "$STUDIO_PYTHON" -m venv "$STUDIO_BUILD/dmg-venv"
  fi
fi
"$STUDIO_DMG_PYTHON" -c 'import sys; sys.exit(sys.version_info < (3, 10))'
"$STUDIO_DMG_PYTHON" -m pip --disable-pip-version-check install -q -r "$STUDIO_SOURCE/Scripts/dmg-requirements.txt"
xcrun swift "$STUDIO_SOURCE/Scripts/DMGBackground.swift" "$STUDIO_STAGE/background"
STUDIO_NAME="Launchpad-Studio-$STUDIO_VERSION-universal.dmg"
"$STUDIO_DMG_PYTHON" -m dmgbuild -s "$STUDIO_SOURCE/Scripts/dmg-settings.py" \
  -D "app=$STUDIO_APP" -D "assets=$STUDIO_STAGE/background" \
  'Launchpad Studio' "$STUDIO_STAGE/$STUDIO_NAME"
/usr/bin/hdiutil verify "$STUDIO_STAGE/$STUDIO_NAME"
mv "$STUDIO_STAGE/$STUDIO_NAME" "$STUDIO_DIST/$STUDIO_NAME"
(cd "$STUDIO_DIST" && /usr/bin/shasum -a 256 "$STUDIO_NAME" > "$STUDIO_NAME.sha256")
printf 'Packaged: %s\n' "$STUDIO_DIST/$STUDIO_NAME"
