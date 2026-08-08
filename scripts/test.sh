#!/usr/bin/env bash
#
# Runs the test suite and cleans up afterwards.
#
#   ./scripts/test.sh              # Debug
#   ./scripts/test.sh Release      # optimised
#
# The cleanup is the point. SplitSound is the test host, and as a menu bar app
# it has no window to close, so `xcodebuild test` leaves a second instance
# sitting in the menu bar. That instance is a *different build* from the one in
# Applications, and clicking it while debugging something else wastes an
# astonishing amount of time.
set -euo pipefail

cd "$(dirname "$0")/.."

CONFIGURATION="${1:-Debug}"
EXTRA=()

if [ "$CONFIGURATION" = "Release" ]; then
  # Passed here rather than set in project.yml, so the shipped build keeps
  # both its hardening and its full optimisation:
  #   - library validation would otherwise refuse to load the ad-hoc signed
  #     test bundle into the hardened app
  #   - @testable import needs testability, which Release does not enable
  EXTRA+=(ENABLE_HARDENED_RUNTIME=NO ENABLE_TESTABILITY=YES)
fi

cleanup() {
  # Only the test host from the build directory. Matching on the process name
  # alone would also kill the copy the user has installed and is using.
  pkill -f "$PWD/build/Build/Products/.*/SplitSound.app" 2>/dev/null || true
}
trap cleanup EXIT

set +e
xcodebuild test \
  -project SplitSound.xcodeproj \
  -scheme SplitSound \
  -destination 'platform=macOS' \
  -configuration "$CONFIGURATION" \
  -derivedDataPath build \
  ${EXTRA[@]+"${EXTRA[@]}"} > "$TMPDIR/splitsound-test.log" 2>&1
STATUS=$?
set -e

grep -E "Executed [0-9]+ tests, with|TEST (SUCCEEDED|FAILED)" "$TMPDIR/splitsound-test.log" | tail -2
if [ "$STATUS" -ne 0 ]; then
  echo
  echo "Failures:"
  grep -E "error:|XCTAssert.* failed" "$TMPDIR/splitsound-test.log" | grep -v linkd | head -10
  exit "$STATUS"
fi

# Note that a passing suite says nothing about the optimiser bug documented in
# docs/TECHNICAL.md; scripts/build-release.sh is what guards against that.
