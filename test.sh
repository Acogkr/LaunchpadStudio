#!/bin/bash
set -euo pipefail
STUDIO_SOURCE="$(cd "$(dirname "$0")" && pwd)"
bash "$STUDIO_SOURCE/Tests/BuildTests.sh"
STUDIO_BUILD="${STUDIO_BUILD_DIR:-$STUDIO_SOURCE/.build}"
STUDIO_TEST_DIST="$STUDIO_BUILD/test-app"
STUDIO_ARCHS="$(uname -m)" STUDIO_INCLUDE_TESTS=1 STUDIO_DIST_DIR="$STUDIO_TEST_DIST" "$STUDIO_SOURCE/build.sh"
mkdir -p "$STUDIO_BUILD/test-results"
STUDIO_FIXTURE_DIR="$(mktemp -d "$STUDIO_BUILD/fixtures.XXXXXX")"
trap 'rm -rf "$STUDIO_FIXTURE_DIR"' EXIT
STUDIO_TEST_ARGS=(--test-directory "$STUDIO_FIXTURE_DIR")
if [[ "${1:-}" == --live-data && $# == 1 ]]; then
  STUDIO_TEST_ARGS+=(--live-data)
elif [[ $# == 0 ]]; then
  python3 "$STUDIO_SOURCE/Tests/Fixtures/generate.py" "$STUDIO_FIXTURE_DIR/source.sqlite"
  STUDIO_TEST_ARGS+=(--fixture "$STUDIO_FIXTURE_DIR/source.sqlite")
else
  echo 'Usage: ./test.sh [--live-data]' >&2; exit 1
fi
for STUDIO_SUITE in self model localization audit management trash cleanup updates; do
  STUDIO_EXPECTED_VERSION="$(cat "$STUDIO_SOURCE/VERSION")" "$STUDIO_TEST_DIST/Launchpad Studio.app/Contents/MacOS/LaunchpadStudio" "--$STUDIO_SUITE-test" "${STUDIO_TEST_ARGS[@]}" | tee "$STUDIO_BUILD/test-results/$STUDIO_SUITE.txt"
done
