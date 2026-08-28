# Cleat

A SwiftUI menu-bar app for macOS that mounts NTFS drives with full read/write
access on Apple Silicon — with **no kernel extension**, and without ever asking
you to disable SIP or change Startup Security Utility settings.

Targets macOS 15 Sequoia and macOS 26 Tahoe, arm64. Built for direct distribution
as a notarized DMG.

---

## How it works

macOS can read NTFS but not write it. On macOS 26 the built-in driver is an FSKit
(`UserFS`) module at `/System/Library/Filesystems/ntfs.fs`, which mounts NTFS
volumes read-only. Cleat:

1. Notices the drive through DiskArbitration when you plug it in.
2. Unmounts the read-only volume macOS created — a third-party FSKit module or the
   built-in one will already have claimed the device, and `ntfs-3g` cannot open it
   for writing until that mount is gone.
3. Confirms the device really is NTFS by reading its boot sector.
4. Runs `ntfs-3g` on top of **FUSE-T**, a userspace FUSE implementation with no
   kernel component. On macOS 26 it asks for FUSE-T's FSKit backend
   (`-o backend=fskit`), which integrates properly with Finder and
   DiskArbitration; on macOS 15 it uses FUSE-T's NFSv4 loopback backend.

The backend choice is the only behavioural difference between the two OS versions.
The UI is identical.

### Why not macFUSE

macFUSE is a kernel extension. On Apple Silicon, approving one requires booting
into Reduced Security, which is explicitly out of scope here. FUSE-T needs no
kext and no security-policy changes.

---

## Dependencies

Two, both installed by you, not by this app:

| Dependency | Why |
|---|---|
| **FUSE-T** ≥ 1.1.0 (1.2.7 current as of June 2026) | Userspace FUSE. Ships `libfuse-t.dylib` in `/usr/local/lib` and headers in `/usr/local/include/fuse`. FSKit backend requires 1.1.0+ and macOS 26. |
| **ntfs-3g, built against FUSE-T** | The actual NTFS read/write engine. |

### The trap this app is built to catch

`brew install ntfs-3g-mac` gives you an ntfs-3g that links against
`libfuse.2.dylib` — **macFUSE**. It looks correct to `which ntfs-3g` and fails only
at mount time. Cleat runs `otool -L` on every ntfs-3g it finds and refuses to
use a macFUSE-linked one, naming the problem in the Setup window instead of failing
silently.

### Installing

```bash
Scripts/setup-dependencies.sh
```

It prints exactly what it will change before it changes anything, asks once, and
needs your password twice — for the FUSE-T package installer and for `make install`
into `/usr/local`. It touches no kernel extension, no SIP setting, no signing
identity, and no disk, and the last lines of the script are the commands to undo it.

Build-time-only Homebrew formulae it may add: `autoconf`, `automake`, `libtool`,
`pkg-config`, `libgcrypt`. `libgcrypt` is needed even though ntfs-3g's crypto support
is off by default, because `configure.ac` expands `AM_PATH_LIBGCRYPT` at autoreconf
time regardless of whether that branch ever runs.

Doing it by hand instead:

```bash
# 1. FUSE-T
sudo mkdir -p /usr/local/include
brew install macos-fuse-t/homebrew-cask/fuse-t

# 2. On macOS 26 only: open /Applications/fuse-t.app once, then enable FUSE-T under
#    System Settings › General › Login Items & Extensions › File System Extensions.
#    Optional — without it the app falls back to the NFS backend, which also works.

# 3. ntfs-3g, built against FUSE-T
brew install autoconf automake libtool pkg-config libgcrypt
git clone https://github.com/macos-fuse-t/ntfs-3g && cd ntfs-3g
export CPPFLAGS="-I/usr/local/include/fuse"
export LDFLAGS="-L/usr/local/lib -lfuse-t -Wl,-rpath,/usr/local/lib"
export ACLOCAL_PATH="$(brew --prefix)/share/aclocal:$ACLOCAL_PATH"
./autogen.sh
./configure --prefix=/usr/local --exec-prefix=/usr/local \
            --with-fuse=external --sbindir=/usr/local/bin --bindir=/usr/local/bin
make -j"$(sysctl -n hw.ncpu)"
sudo make install

# 4. Confirm it linked against the right FUSE — this is the whole ballgame
otool -L /usr/local/bin/ntfs-3g | grep fuse    # must show libfuse-t
```

The app's Setup window shows the same commands with a Copy button and re-checks after
you run them. The app itself never runs Homebrew or `sudo` on your behalf.

---

## Architecture

```
Cleat.app
├── Contents/MacOS/Cleat            SwiftUI menu-bar app (LSUIElement)
├── Contents/MacOS/CleatHelper       privileged launchd daemon
└── Contents/Library/LaunchDaemons/
    └── com.cleat.helper.plist       registered via SMAppService
```

**Why a helper.** Opening `/dev/diskNsM` for writing requires root: the device nodes
are `root:operator` and an ordinary admin account is not in `operator`. Rather than
run the whole UI privileged, all disk work lives in a ~400-line daemon registered
with `SMAppService.daemon(plistName:)`. No `SMJobBless`, no authorisation right, no
files written outside the app bundle — macOS asks you to approve the item once in
Login Items & Extensions.

**Trust between the two.** Both ends pin the other with
`NSXPCConnection.setCodeSigningRequirement`, built from the signing team read out of
the running binary's own signature at runtime. Requirement strings are compiled with
`SecRequirementCreateWithString` first, because `setCodeSigningRequirement` raises an
uncatchable Objective-C exception on a malformed string rather than throwing.

| File | Role |
|---|---|
| `Shared/HelperProtocol.swift` | XPC surface, request/response types, `BSDName` validation |
| `Shared/NTFS3GInvocation.swift` | Builds and re-parses ntfs-3g argument vectors |
| `Shared/DiskArbitrationBridge.swift` | Synchronous unmount/eject with typed errors |
| `Shared/MountTable.swift` | `getmntinfo` + `KERN_PROC`/`KERN_PROCARGS2` process inspection |
| `Shared/NTFSProbe.swift` | Boot-sector NTFS check |
| `CleatHelper/MountEngine.swift` | The privileged mount/unmount/eject flow |
| `Cleat/Services/DependencyChecker.swift` | FUSE-T / ntfs-3g / FSKit / FDA / helper status |
| `Cleat/Services/AppModel.swift` | Reconciles hardware state with helper state |

### Disk-safety model

- **Nothing is ever forced.** Unmount uses `unmount(2)` without `MNT_FORCE` and
  `DADiskUnmount` without `kDADiskUnmountOptionForce`. `EBUSY` is reported to you as
  "in use", never worked around.
- **Orphaned processes are reported, not killed.** After an unmount the helper waits
  up to 10 s for `ntfs-3g` to exit. If it hasn't, you get its PID and a message —
  no `SIGKILL` behind your back.
- **The device is verified before it is written.** `ntfs-3g` is only ever pointed at
  a device whose boot sector reads `NTFS    ` at offset 3.
- **Nothing is ever formatted, erased, or repartitioned.** There is no code path
  that could.
- **No shell, anywhere.** Every external binary is launched by absolute path through
  a real `argv`. A volume named `Evil,backend=nfs,allow_other=1;rm -rf /` collapses
  into one inert `volname=` value — commas and `=` are stripped precisely because
  `-o` takes a comma-separated list.
- **Disk identifiers are validated by shape.** `BSDName.isValid` accepts only
  `disk4`, `disk4s1`, `disk3s1s1`; anything else never reaches a device path.

### Known rough edges, handled

- **FUSE-T's NFS backend doesn't show up in the Finder sidebar.** The volume is
  browsable at `/Volumes/<name>`. Rows mounted this way are tagged `NFS` in the menu
  with an explanation, and "Open" reveals the mount point in Finder.
- **DiskArbitration doesn't associate a FUSE mount with its block device.** So
  "which device is this mount?" is answered from the `ntfs-3g` process's argument
  vector, with a root-owned JSON file at
  `/Library/Application Support/Cleat/helper-state.json` as a fallback for when
  launchd has restarted the helper.
- **NTFS volumes often have no `DAVolumeUUID`.** Per-volume preferences use the UUID
  when macOS publishes one and fall back to volume name + capacity when it doesn't —
  both computable the moment the drive appears, without root and without mounting it.
- **Busy volumes report `0xC010`, not `kDAReturnBusy`.** macOS 26's FSKit-backed NTFS
  mounts return POSIX errors encoded as `0xC000 | errno`. Both encodings are decoded.
- **Other NTFS drivers can claim the disk first** by registering a lower
  `FSProbeOrder` than Apple's `ntfs.fs` (which is 2000). The Setup window names any
  it finds in `/Library/Filesystems`; the mount flow unmounts whatever claimed the
  device before attaching its own.

---

## Building

Requires Xcode 26 and Swift 6.

```bash
xcodegen generate     # only if you edited project.yml
xcodebuild -project Cleat.xcodeproj -scheme Cleat -configuration Debug build
```

`Cleat.xcodeproj` is generated from `project.yml`, and is committed, so
XcodeGen is optional.

Set your Team ID in `Config/Signing.xcconfig` before distributing. With it blank the
project signs to run locally, and the helper falls back to an identifier-only client
check — enough for development, **not** enough for a shipped build. The helper logs a
warning when it is in that state.

```bash
DEVELOPMENT_TEAM=XXXXXXXXXX \
SIGN_IDENTITY="Developer ID Application: … (XXXXXXXXXX)" \
NOTARY_PROFILE=my-notary-profile \
  Scripts/build-dmg.sh
```

The script contains no credentials and creates no signing identity.

---

## Verification status

Verified on this machine (macOS 26.3, Apple Silicon, Xcode 26.6), against FUSE-T 1.2.7
and an `ntfs-3g 2022.10.3` built from `macos-fuse-t/ntfs-3g` and linked against
`libfuse-t` (confirmed with `otool -L` *and* `DYLD_PRINT_LIBRARIES`, since a
macFUSE-linked build looks identical to `which` and only fails at mount time).

Automated: **138 checks, all passing**. Re-run them with `Tests/QA/run.sh <bsdname>`.
They live outside the Xcode project on purpose — they need a live NTFS volume and a
real process table, so they run by hand against a throwaway image rather than on every
build.

- Both configurations build clean under Swift 6 strict concurrency, zero warnings.
- The helper is embedded at `Contents/MacOS/CleatHelper` with its launchd plist in
  `Contents/Library/LaunchDaemons`, a correct embedded `__TEXT,__info_plist`, and
  refuses to run outside launchd.
- Injection safety proven end to end, not just in unit tests: a hostile label
  (`Evil,backend=nfs,allow_other=1;rm -rf /\nfoo`) is passed through argument
  construction to a real spawned process and read back out of the kernel via
  `KERN_PROCARGS2`. Nine options in, nine out; `backend` not overridden, `allow_other`
  not duplicated. There is no shell anywhere in the codebase — no `/bin/sh`,
  `system()`, or `popen()` — so shell metacharacters in a label are inert.
- Path traversal: 14 hostile volume labels (`../../etc`, `/etc/passwd`, `..`, NUL bytes,
  400 characters) all resolve to a path directly under `/Volumes`. This matters because
  the helper `mkdir`s and `chown`s that path as root.
- Busy detection verified live, including the macOS 26 FSKit path where DiskArbitration
  reports `EBUSY` as `0xC010` rather than `kDAReturnBusy`. Refused while a descriptor
  was open, succeeded once released, tolerated a redundant second unmount.
- **Read/write mount verified end to end** (`Scripts/qa-mount-test.sh`): mounted
  read/write via ntfs-3g + FUSE-T, then create, read-back, append, rename, nested
  `mkdir`, a 100 MB write, and filenames with unicode, spaces and quotes — all correct.
  Unmounted cleanly with `ntfs-3g` exiting on its own rather than being killed, and
  `ntfsfix -n` afterwards reported the volume clean (`$MFT` and `$MFTMirr` processed
  successfully, NTFS 3.1), so a full write cycle leaves the filesystem intact.
- Crash regression: five mount/unmount cycles and three full device attach/detach cycles
  against the running app, with no new crash reports.

**Not verified:** eject-after-mount against real removable hardware — the test rig is a
disk image, which ejects through a different path than a USB enclosure. The UI has not
been visually inspected; this environment has no screen-recording permission, though the
app launches and runs without crashing.

### Notes from testing

- `ntfs-3g` refuses to mount a block device as an unprivileged user (exit 19). This is
  expected and is precisely why the privileged helper exists.
- macOS stacks mounts on the same path. A FUSE mount left behind by a crash can be
  silently mounted *over*, so `makeMountPoint` picks a suffixed name rather than
  reusing a path that is already a mount point.
- On the NFS backend, `lsof +D` lists FUSE-T's own daemons as holders of the mount
  point. They are the filesystem, not users of it; a successful unmount is the only
  reliable idle check.
