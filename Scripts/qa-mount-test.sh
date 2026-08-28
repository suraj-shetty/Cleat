#!/bin/bash
# End-to-end read/write mount test for Cleat.
#
# Operates ONLY on the throwaway 512 MB disk image this QA pass created.
# It never touches "My Passport" or any other disk. It needs root because
# ntfs-3g refuses to mount a block device as an unprivileged user (exit 19).
#
# Run:  sudo bash mount-test.sh <bsdname>      e.g. sudo bash mount-test.sh disk23s1
set -uo pipefail

BSD="${1:?usage: sudo bash mount-test.sh <bsdname>  (e.g. disk23s1)}"
DEV="/dev/$BSD"
MP="/Volumes/QA Test NTFS"
NTFS3G=/usr/local/bin/ntfs-3g
P=0; F=0
ok(){ P=$((P+1)); printf '  \033[32m✓\033[0m %s\n' "$*"; }
no(){ F=$((F+1)); printf '  \033[31m✗\033[0m %s\n' "$*"; }
sec(){ printf '\n\033[1m=== %s ===\033[0m\n' "$*"; }

[ "$(id -u)" -eq 0 ] || { echo "must run under sudo"; exit 2; }

# Guard: refuse to touch anything that is not our 512MB test image.
SIZE=$(diskutil info "$DEV" 2>/dev/null | awk -F'[()]' '/Disk Size/{print $2}' | awk '{print $1}')
LABEL=$(diskutil info "$DEV" 2>/dev/null | awk -F': *' '/Volume Name/{print $2}' | xargs)
if [ "$LABEL" != "QA Test NTFS" ]; then
  echo "REFUSING: $DEV is labelled '$LABEL', not the QA test volume. Aborting."
  exit 2
fi
echo "Target: $DEV  label='$LABEL'  size=${SIZE:-?} bytes"

sec "0b. Clear anything left over from a previous run"
# macOS stacks mounts on the same path, so one umount can reveal an older mount
# underneath. Drain the whole stack, or step 2 mounts on top of a leftover and every
# later step operates on the wrong one.
for _ in 1 2 3 4 5; do
    mount | grep -qF " $MP " || break
    umount "$MP" 2>/dev/null || diskutil unmount force "$MP" >/dev/null 2>&1 || break
    echo "     (cleared a leftover mount at $MP)"
    sleep 1
done
diskutil unmount "$MP 1" >/dev/null 2>&1 && echo "     (cleared a leftover duplicate)"
mount | grep -qF " $MP " && no "could not clear leftovers; re-run after a reboot" || ok "starting from a clean slate"
sleep 1

sec "1. Unmount the macOS read-only FSKit mount"
diskutil unmount "$DEV" >/dev/null 2>&1
mount | grep -q "$DEV " && no "still mounted" || ok "read-only mount cleared"

sec "2. Mount read/write via ntfs-3g + FUSE-T"
mkdir -p "$MP"
"$NTFS3G" "$DEV" "$MP" -o "local,allow_other,auto_xattr,noatime,uid=501,gid=20,umask=022,volname=QA Test NTFS" 2>&1 | sed 's/^/     /'
RC=${PIPESTATUS[0]}
[ "$RC" -eq 0 ] && ok "ntfs-3g exited 0" || no "ntfs-3g exited $RC"
sleep 3
MOUNTLINE=$(mount | grep -F "$MP")
[ -n "$MOUNTLINE" ] && ok "appears in mount table" || no "NOT in mount table"
STACKED=$(mount | grep -cF " $MP ")
[ "$STACKED" -le 1 ] && ok "exactly one mount on the path (not stacked)" || no "$STACKED mounts stacked on $MP"
echo "     $MOUNTLINE"
echo "$MOUNTLINE" | grep -q "read-only" && no "MOUNTED READ-ONLY (the whole point failed)" || ok "mounted read/write"
BACKEND=$(echo "$MOUNTLINE" | grep -oE 'fskit|nfs|webdav' | head -1)
echo "     backend: ${BACKEND:-unknown}"
pgrep -fl "ntfs-3g $DEV" >/dev/null && ok "ntfs-3g daemon is running" || no "no ntfs-3g daemon"

sec "3. Write / read / rename / delete"
T="$MP/qa-$$"
if echo "hello ntfs" > "$T.txt" 2>/dev/null; then ok "create file"; else no "create file"; fi
[ "$(cat "$T.txt" 2>/dev/null)" = "hello ntfs" ] && ok "read back matches" || no "read back mismatch"
echo "appended" >> "$T.txt" 2>/dev/null && [ "$(wc -l < "$T.txt")" -eq 2 ] && ok "append" || no "append"
mv "$T.txt" "$T-renamed.txt" 2>/dev/null && ok "rename" || no "rename"
mkdir -p "$T-dir/nested" 2>/dev/null && ok "mkdir nested" || no "mkdir nested"
printf 'x%.0s' $(seq 1 100000) > "$T-dir/nested/big.bin" 2>/dev/null && ok "write 100KB" || no "write 100KB"
[ "$(stat -f%z "$T-dir/nested/big.bin" 2>/dev/null)" = "100000" ] && ok "size correct" || no "size wrong"
# unicode + spaces, the names that break naive quoting
UF="$MP/qa spaces 'and' \"quotes\" ünïcode $$.txt"
echo ok > "$UF" 2>/dev/null && [ "$(cat "$UF")" = "ok" ] && ok "unicode/spaces/quotes filename" || no "unicode/spaces/quotes filename"
rm -f "$UF" 2>/dev/null && ok "delete unicode file" || no "delete unicode file"
sec "   throughput (100 MB, cache-defeating)"
dd if=/dev/zero of="$T-dir/speed.bin" bs=1m count=100 2>&1 | tail -1 | sed 's/^/     write: /'
sync
dd if="$T-dir/speed.bin" of=/dev/null bs=1m 2>&1 | tail -1 | sed 's/^/     read:  /'
rm -rf "$T-dir" "$T-renamed.txt" 2>/dev/null && ok "recursive delete" || no "recursive delete"

sec "4. Busy-volume refusal (must NOT force-unmount)"
# Hold the volume open with ONE fd owned by this script. No background subshells:
# a killed subshell can leave its `sleep` child alive with a cwd inside the mount,
# which keeps the volume busy and makes the *next* step fail for the wrong reason.
exec 9<"$MP" || no "could not open the mount point"
umount "$MP" 2>&1 | sed 's/^/     /'
UMRC=${PIPESTATUS[0]}
[ "$UMRC" -ne 0 ] && ok "busy unmount refused (rc=$UMRC)" || no "BUSY VOLUME WAS UNMOUNTED — data-loss risk"
mount | grep -qF "$MP" && ok "…and the volume is still mounted" || no "…but the volume went away anyway"
exec 9<&-
sleep 2

sec "5. Clean unmount once idle"
# Diagnostic, NOT an assertion. A FUSE-T mount is served by its own daemons
# (ntfs-3g, and go-nfsv4 on the NFS backend), and lsof reports those as holders of
# the mount point even though they are the filesystem rather than a user of it.
# The unmount below is the real verdict: if it succeeds, the volume was idle.
if command -v lsof >/dev/null 2>&1; then
    HOLDERS=$(lsof +D "$MP" 2>/dev/null | tail -n +2 | awk -v mp="$MP" '$NF != mp')
    if [ -n "$HOLDERS" ]; then
        echo "     open handles reported by lsof (informational):"
        echo "$HOLDERS" | awk '{print "       " $1 " (pid " $2 ") -> " $NF}' | sort -u | head -8
    else
        echo "     lsof reports no open handles"
    fi
fi
umount "$MP" 2>&1 | sed 's/^/     /'
sleep 2
mount | grep -qF "$MP" && no "still mounted after unmount" || ok "unmounted cleanly"
sleep 3
pgrep -f "ntfs-3g $DEV" >/dev/null && no "ntfs-3g daemon still running" || ok "ntfs-3g exited on its own (not killed)"
rmdir "$MP" 2>/dev/null && ok "mount point removed" || echo "     (mount point left in place)"

sec "6. Data survived: filesystem integrity"
# ntfsfix needs the device NOT mounted. Checking while macOS holds it produces a
# bogus "Volume is corrupt" that only means "could not open the device".
if mount | grep -q "$DEV "; then
    echo "     device still mounted; skipping ntfsfix (its verdict would be meaningless)"
else
    OUT=$(/usr/local/bin/ntfsfix -n "$DEV" 2>&1)
    echo "$OUT" | sed 's/^/     /'
    if echo "$OUT" | grep -qi "Resource busy"; then
        no "could not open device to check integrity"
    elif echo "$OUT" | grep -qiE "volume is corrupt|had errors"; then
        no "FILESYSTEM REPORTS CORRUPTION"
    else
        ok "filesystem is clean"
    fi
fi
echo "     remounting read-only to confirm macOS still accepts it"
diskutil mount "$DEV" >/dev/null 2>&1
sleep 2
mount | grep -q "$DEV " && ok "macOS remounted it" || no "macOS could NOT remount it"

printf '\n──────────────────────────────\n'
printf 'PASS %s   FAIL %s\n' "$P" "$F"
