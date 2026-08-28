#!/bin/bash
# Runs the QA harnesses against the current source.
#
# Each file is a standalone `main.swift`-style program compiled against Shared/ (and,
# for the guard tests, the helper). They are kept out of the Xcode project on purpose:
# they need a live NTFS volume and a real process table, so they are run by hand
# against a throwaway disk image rather than on every build.
#
# Usage:  Tests/QA/run.sh <bsdname-of-a-test-ntfs-volume>     e.g. Tests/QA/run.sh disk23s1
set -uo pipefail
cd "$(dirname "$0")/../.."
BSD="${1:-}"
OUT=$(mktemp -d)
trap 'rm -rf "$OUT"' EXIT

cc -O0 -o "$OUT/ntfs-3g" -x c - <<'C'
#include <unistd.h>
int main(void){ for(;;) sleep(1); return 0; }
C

mkdir -p "$OUT/a" "$OUT/b" "$OUT/c"
cp Tests/QA/SharedLogicTests.swift     "$OUT/a/main.swift"
cp Tests/QA/DiskArbitrationTests.swift "$OUT/b/main.swift"
cp Tests/QA/MountPointGuardTests.swift "$OUT/c/main.swift"

RC=0
swiftc -O -swift-version 6 -o "$OUT/a/run" Shared/*.swift "$OUT/a/main.swift" || RC=1
swiftc -O -swift-version 6 -o "$OUT/b/run" Shared/*.swift "$OUT/b/main.swift" || RC=1
swiftc -O -swift-version 6 -o "$OUT/c/run" Shared/*.swift \
    CleatHelper/MountEngine.swift CleatHelper/HelperStateStore.swift "$OUT/c/main.swift" || RC=1
[ "$RC" -eq 0 ] || { echo "harness build failed"; exit 1; }

echo "### mount-point guard + sanitizer (no volume needed) ###"
"$OUT/c/run" || RC=1
if [ -n "$BSD" ]; then
    echo; echo "### shared logic / argv / ProcessRunner ###"
    "$OUT/a/run" "$BSD" "$OUT/ntfs-3g" || RC=1
    echo; echo "### DiskArbitration / busy detection (UNMOUNTS $BSD) ###"
    "$OUT/b/run" "$BSD" || RC=1
else
    echo; echo "(skipping volume tests — pass a test NTFS bsdname to run them)"
fi
exit $RC
