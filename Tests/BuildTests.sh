#!/bin/bash
set -euo pipefail
STUDIO_SOURCE_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
STUDIO_TEMP_ROOT="${TMPDIR:-/tmp}"
STUDIO_FIXTURE="$(mktemp -d "${STUDIO_TEMP_ROOT%/}/studio-build-test.XXXXXX")"
STUDIO_TEST_ROOT="$STUDIO_FIXTURE/Project [test].(copy)+"
STUDIO_TEST_APP="$STUDIO_TEST_ROOT/dist/Launchpad Studio.app/Contents/MacOS/LaunchpadStudio"
STUDIO_TEST_PID=''
cleanup() {
  if [ -n "$STUDIO_TEST_PID" ]; then
    kill "$STUDIO_TEST_PID" 2>/dev/null || true
    wait "$STUDIO_TEST_PID" 2>/dev/null || true
  fi
  rm -rf "$STUDIO_FIXTURE"
}
trap cleanup EXIT
mkdir -p "$(dirname "$STUDIO_TEST_APP")" "$STUDIO_FIXTURE/bin"
cp "$STUDIO_SOURCE_ROOT/build.sh" "$STUDIO_TEST_ROOT/build.sh"
cp "$STUDIO_SOURCE_ROOT/VERSION" "$STUDIO_SOURCE_ROOT/BUILD_NUMBER" "$STUDIO_TEST_ROOT/"
mkdir -p "$STUDIO_TEST_ROOT/Scripts" "$STUDIO_TEST_ROOT/Sources"
printf '# Fixture localization generator\n' > "$STUDIO_TEST_ROOT/Scripts/localizations.py"
printf 'import Foundation\n' > "$STUDIO_TEST_ROOT/Sources/Fixture.swift"
printf '#include <unistd.h>\nint main(void) { sleep(30); return 0; }\n' |
  xcrun clang -x c - -o "$STUDIO_TEST_APP"
# Reaching the compiler proves the guard allowed this fixture. Never build an app.
printf '#!/bin/bash\nexit 86\n' > "$STUDIO_FIXTURE/bin/xcrun"
chmod +x "$STUDIO_FIXTURE/bin/xcrun"
check_build() {
  local expected="$1" actual=0
  STUDIO_BUILD_DIR="$STUDIO_TEST_ROOT/.build" STUDIO_DIST_DIR="$STUDIO_TEST_ROOT/dist" \
    STUDIO_ARCHS="$(uname -m)" STUDIO_INCLUDE_TESTS=0 PATH="$STUDIO_FIXTURE/bin:$PATH" \
    bash "$STUDIO_TEST_ROOT/build.sh" > "$STUDIO_FIXTURE/result" 2>&1 || actual=$?
  if [ "$actual" != "$expected" ]; then
    cat "$STUDIO_FIXTURE/result" >&2
    printf 'Build guard: expected exit %s, got %s\n' "$expected" "$actual" >&2
    exit 1
  fi
  if [ "$expected" = 1 ]; then
    [[ "$(cat "$STUDIO_FIXTURE/result")" = 'Quit Launchpad Studio before rebuilding it.' ]]
  fi
}
stop_fixture() {
  kill "$STUDIO_TEST_PID"
  wait "$STUDIO_TEST_PID" 2>/dev/null || true
  STUDIO_TEST_PID=''
}
for argument in '' '--test-mode' '--another-argument'; do
  if [ -z "$argument" ]; then "$STUDIO_TEST_APP" & else "$STUDIO_TEST_APP" "$argument" & fi
  STUDIO_TEST_PID=$!
  # Let exec replace the launching shell before inspecting the executable.
  sleep 0.1
  check_build 1
  stop_fixture
done
(cd "$STUDIO_TEST_ROOT" && exec './dist/Launchpad Studio.app/Contents/MacOS/LaunchpadStudio' --test-mode) &
STUDIO_TEST_PID=$!
sleep 0.1
check_build 1
stop_fixture
check_build 86
cp "$STUDIO_TEST_APP" "${STUDIO_TEST_APP}-other"
"${STUDIO_TEST_APP}-other" &
STUDIO_TEST_PID=$!
sleep 0.1
check_build 86
stop_fixture
printf '6 build safety checks passed.\n'
