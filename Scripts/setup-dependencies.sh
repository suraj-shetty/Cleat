#!/bin/bash
#
# One-time dependency setup for Cleat.
#
#   FUSE-T          userspace FUSE, no kernel extension  (installed from a signed .pkg)
#   ntfs-3g         NTFS read/write engine, built from source against FUSE-T
#
# Run it:   Scripts/setup-dependencies.sh
#
# This script makes changes OUTSIDE this project directory and will say exactly
# what they are before it makes them. It needs your password twice: once for the
# FUSE-T package installer, once for `make install` into /usr/local.
#
# It does NOT touch SIP, Startup Security Utility, kernel extensions, your signing
# identities, or any disk. Everything it does is reversible — see UNDO at the bottom.
#
set -euo pipefail

cd "$(dirname "$0")/.."
ROOT="$PWD"
SRC_DIR="${NTFS3G_SRC_DIR:-$ROOT/build/ntfs-3g-src}"
ASSUME_YES="${ASSUME_YES:-no}"
[ "${1:-}" = "--yes" ] && ASSUME_YES=yes

bold()  { printf '\033[1m%s\033[0m\n' "$*"; }
info()  { printf '  %s\n' "$*"; }
good()  { printf '  \033[32m✓\033[0m %s\n' "$*"; }
warn()  { printf '  \033[33m!\033[0m %s\n' "$*"; }
bad()   { printf '  \033[31m✗\033[0m %s\n' "$*"; }
step()  { printf '\n\033[1m==> %s\033[0m\n' "$*"; }

confirm() {
    [ "$ASSUME_YES" = yes ] && return 0
    printf '\n%s [y/N] ' "$1"
    read -r reply </dev/tty
    case "$reply" in [yY]*) return 0 ;; *) echo "Aborted."; exit 1 ;; esac
}

# ---------------------------------------------------------------- preflight

step "Checking this machine"

OS_MAJOR=$(sw_vers -productVersion | cut -d. -f1)
info "macOS $(sw_vers -productVersion) on $(uname -m)"
if [ "$OS_MAJOR" -lt 15 ]; then
    bad "Cleat needs macOS 15 or later."
    exit 1
fi

if ! command -v brew >/dev/null 2>&1; then
    bad "Homebrew is not installed. Get it from https://brew.sh and re-run this."
    exit 1
fi
good "Homebrew at $(command -v brew)"

# Build tools ntfs-3g's autotools build needs. libgcrypt is required even though
# crypto support is off by default: configure.ac expands AM_PATH_LIBGCRYPT at
# autoreconf time regardless, and without the macro the generated configure is not
# valid shell.
# Detected by what the build actually needs rather than by formula name, because
# Homebrew renames things (pkg-config is now an alias for pkgconf) and a formula-name
# check would ask to reinstall something that is already there.
BREW_PREFIX="$(brew --prefix)"
MISSING_TOOLS=()
command -v autoconf    >/dev/null 2>&1 || MISSING_TOOLS+=(autoconf)
command -v automake    >/dev/null 2>&1 || MISSING_TOOLS+=(automake)
command -v glibtoolize >/dev/null 2>&1 || MISSING_TOOLS+=(libtool)
command -v pkg-config  >/dev/null 2>&1 || MISSING_TOOLS+=(pkg-config)
[ -f "$BREW_PREFIX/share/aclocal/libgcrypt.m4" ] || MISSING_TOOLS+=(libgcrypt)

FUSE_T_INSTALLED=no
[ -f /usr/local/lib/libfuse-t.dylib ] && FUSE_T_INSTALLED=yes

# ---------------------------------------------------------------- the plan

step "What this will change on your system"

if [ ${#MISSING_TOOLS[@]} -gt 0 ]; then
    info "Homebrew formulae to install (build-time only, not needed at runtime):"
    for tool in "${MISSING_TOOLS[@]}"; do info "    • $tool"; done
else
    good "All build tools already installed"
fi

if [ "$FUSE_T_INSTALLED" = no ]; then
    info "Homebrew cask to install:"
    info "    • fuse-t 1.2.7 — runs a signed .pkg that writes to /usr/local/lib,"
    info "      /usr/local/include/fuse, /Library/Application Support/fuse-t,"
    info "      and /Applications/fuse-t.app. Needs your password."
else
    good "FUSE-T already installed"
fi

info "Source build:"
info "    • clone https://github.com/macos-fuse-t/ntfs-3g into"
info "      $SRC_DIR"
info "    • sudo make install → /usr/local/bin/ntfs-3g and friends. Needs your password."

warn "No kernel extension is installed. SIP and Startup Security are not touched."

confirm "Proceed?"

# ---------------------------------------------------------------- build tools

if [ ${#MISSING_TOOLS[@]} -gt 0 ]; then
    step "Installing build tools"
    brew install "${MISSING_TOOLS[@]}"
    good "Build tools installed"
fi

# ---------------------------------------------------------------- FUSE-T

step "Installing FUSE-T"

if [ "$FUSE_T_INSTALLED" = yes ]; then
    good "Already present at /usr/local/lib/libfuse-t.dylib"
else
    # The .pkg wants /usr/local/include to exist before it will lay down headers.
    sudo mkdir -p /usr/local/include
    brew install macos-fuse-t/homebrew-cask/fuse-t
fi

if [ -f /usr/local/lib/libfuse-t.dylib ]; then
    good "libfuse-t.dylib present"
else
    bad "libfuse-t.dylib is still missing — the package did not install correctly."
    exit 1
fi

if [ -d /usr/local/include/fuse ]; then
    good "FUSE headers present at /usr/local/include/fuse"
else
    bad "/usr/local/include/fuse is missing; ntfs-3g cannot be built against FUSE-T."
    info "Try: sudo mkdir -p /usr/local/include && brew reinstall macos-fuse-t/homebrew-cask/fuse-t"
    exit 1
fi

# ---------------------------------------------------------------- FSKit (macOS 26+)

if [ "$OS_MAJOR" -ge 26 ]; then
    step "FSKit backend (macOS 26+)"
    if pluginkit -m -A -v -p FSModule 2>/dev/null | grep -qi 'fuse-t'; then
        good "FUSE-T's FSKit module is registered"
    else
        warn "FUSE-T's FSKit module is not enabled yet."
        info "Open /Applications/fuse-t.app once, then turn FUSE-T on under"
        info "System Settings › General › Login Items & Extensions › File System Extensions."
        info "This is optional: without it Cleat falls back to FUSE-T's NFS backend,"
        info "which also works but may not show the drive in the Finder sidebar."
    fi
fi

# ---------------------------------------------------------------- ntfs-3g

step "Building ntfs-3g against FUSE-T"

mkdir -p "$(dirname "$SRC_DIR")"
if [ -d "$SRC_DIR/.git" ]; then
    info "Refreshing existing clone at $SRC_DIR"
    git -C "$SRC_DIR" fetch --depth 1 origin
    git -C "$SRC_DIR" reset --hard FETCH_HEAD
else
    rm -rf "$SRC_DIR"
    git clone --depth 1 https://github.com/macos-fuse-t/ntfs-3g "$SRC_DIR"
fi
good "Source at $(git -C "$SRC_DIR" log -1 --format='%h %ad' --date=short)"

cd "$SRC_DIR"

# These are what actually point the build at FUSE-T. configure's --with-fuse=external
# path only asks pkg-config for a `fuse` module, which FUSE-T does not necessarily
# register, so the include and link paths are supplied by hand.
export CPPFLAGS="-I/usr/local/include/fuse"
export LDFLAGS="-L/usr/local/lib -lfuse-t -Wl,-rpath,/usr/local/lib"
export PATH="$BREW_PREFIX/bin:$PATH"
# autoreconf has to find libgcrypt.m4; without it the generated configure contains an
# unexpanded AM_PATH_LIBGCRYPT and is not valid shell.
export ACLOCAL_PATH="$BREW_PREFIX/share/aclocal${ACLOCAL_PATH:+:$ACLOCAL_PATH}"

info "ACLOCAL_PATH=$ACLOCAL_PATH"
info "CPPFLAGS=$CPPFLAGS"
info "LDFLAGS=$LDFLAGS"

./autogen.sh
./configure \
    --prefix=/usr/local \
    --exec-prefix=/usr/local \
    --with-fuse=external \
    --sbindir=/usr/local/bin \
    --bindir=/usr/local/bin

make -j"$(sysctl -n hw.ncpu)"
sudo make install

cd "$ROOT"

# ---------------------------------------------------------------- verify

step "Verifying"

FAILED=no

NTFS3G=/usr/local/bin/ntfs-3g
if [ -x "$NTFS3G" ]; then
    good "ntfs-3g installed at $NTFS3G"
else
    bad "ntfs-3g is not at $NTFS3G"
    FAILED=yes
fi

# The check that matters, and the one Cleat itself performs: a macFUSE-linked
# ntfs-3g looks fine to `which` and fails only at mount time.
if [ -x "$NTFS3G" ]; then
    LINKAGE=$(otool -L "$NTFS3G")
    if grep -q 'libfuse-t' <<<"$LINKAGE"; then
        good "Linked against FUSE-T"
    elif grep -qE 'libfuse\.2\.dylib|macfuse|libosxfuse' <<<"$LINKAGE"; then
        bad "Linked against macFUSE, not FUSE-T. This build is unusable here."
        info "$LINKAGE"
        FAILED=yes
    else
        bad "No FUSE library found in its link list:"
        info "$LINKAGE"
        FAILED=yes
    fi
    info "$("$NTFS3G" --version 2>&1 | head -1)"
fi

# A Homebrew ntfs-3g earlier on PATH would shadow this one for anything that resolves
# by name. Cleat always uses an absolute path, so this is only a heads-up.
FIRST_ON_PATH=$(command -v ntfs-3g || true)
if [ -n "$FIRST_ON_PATH" ] && [ "$FIRST_ON_PATH" != "$NTFS3G" ]; then
    warn "\`ntfs-3g\` on your PATH resolves to $FIRST_ON_PATH, not the build just installed."
    info "Cleat picks the FUSE-T-linked one by absolute path, so this is harmless."
    info "To remove the macFUSE-linked one: brew uninstall ntfs-3g-mac"
fi

echo
if [ "$FAILED" = no ]; then
    bold "Done. Open Cleat, hit Re-check in Setup, and every row should be green."
    bold "Then install the privileged helper from that same window."
else
    bold "Setup did not complete. See the errors above."
    exit 1
fi

# ---------------------------------------------------------------- UNDO
#
#   sudo make uninstall            # from inside "$SRC_DIR", removes ntfs-3g
#   brew uninstall --cask fuse-t   # removes FUSE-T and its pkg receipts
#   brew uninstall autoconf automake libgcrypt pkg-config
#   rm -rf "$SRC_DIR"
