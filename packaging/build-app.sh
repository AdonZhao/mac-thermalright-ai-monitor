#!/usr/bin/env bash
# build-app.sh — build MacTR and assemble it into a self-contained .app bundle.
#
#   ./packaging/build-app.sh
#   MACTR_VERSION=2.0.0 ./packaging/build-app.sh    # override the bundle version
#   SWIFT=/path/to/swift ./packaging/build-app.sh   # pin the toolchain
#
# Output: dist/MacTR AI.app
#
# The bundle carries its own copy of libusb, so users do not need Homebrew. The
# app is ad-hoc signed only (no Developer ID), which is enough for macOS to run
# it locally but still trips Gatekeeper on download — see README.

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$REPO_ROOT"

APP_NAME="MacTR AI"
DIST="$REPO_ROOT/dist"
APP="$DIST/$APP_NAME.app"

# ---------------------------------------------------------------- toolchain
# A broken/partial Command Line Tools install makes the stock `swift` fail while
# parsing Package.swift, so fall back to the Homebrew toolchain rather than
# dying with a confusing manifest error.
pick_swift() {
    if [[ -n "${SWIFT:-}" ]]; then echo "$SWIFT"; return; fi
    if command -v swift >/dev/null 2>&1 && swift --version >/dev/null 2>&1; then
        command -v swift; return
    fi
    if [[ -x /opt/homebrew/opt/swift/bin/swift ]]; then
        echo /opt/homebrew/opt/swift/bin/swift; return
    fi
    echo "error: no working swift toolchain found" >&2
    exit 1
}
SWIFT_BIN="$(pick_swift)"
echo "==> toolchain: $SWIFT_BIN"
"$SWIFT_BIN" --version 2>/dev/null | head -1 || true

# ---------------------------------------------------------------- build
echo "==> building release"
"$SWIFT_BIN" build -c release
BIN="$("$SWIFT_BIN" build -c release --show-bin-path)/MacTR"
[[ -x "$BIN" ]] || { echo "error: binary not found at $BIN" >&2; exit 1; }

# ---------------------------------------------------------------- assemble
echo "==> assembling $APP_NAME.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources" "$APP/Contents/Frameworks"

cp "$BIN" "$APP/Contents/MacOS/MacTR"
cp packaging/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"
cp Sources/MacTR/Resources/Info.plist "$APP/Contents/Info.plist"
printf 'APPL????' > "$APP/Contents/PkgInfo"

# Keep the bundle version in lockstep with the release tag when CI passes one in.
if [[ -n "${MACTR_VERSION:-}" ]]; then
    echo "==> stamping version $MACTR_VERSION"
    /usr/libexec/PlistBuddy -c "Set :CFBundleShortVersionString $MACTR_VERSION" \
        "$APP/Contents/Info.plist"
    /usr/libexec/PlistBuddy -c "Set :CFBundleVersion $MACTR_VERSION" \
        "$APP/Contents/Info.plist"
fi

# ---------------------------------------------------------------- vendor dylibs
# Anything not under /System, /usr/lib or already @rpath-relative came from a
# package manager and will not exist on the user's machine. Discover them from
# the binary instead of hardcoding a Homebrew prefix, so this also works on an
# Intel runner (/usr/local) or a non-standard brew root.
echo "==> vendoring non-system dylibs"

# macOS ships bash 3.2, so no `mapfile` — read the list line by line. The loop
# body runs in this shell (not a subshell) because the redirect is on `done`.
external_deps() {
    otool -L "$1" | tail -n +2 | awk '{print $1}' \
        | grep -Ev '^(/System/|/usr/lib/|@rpath/|@executable_path/|@loader_path/)' || true
}

found=0
while IFS= read -r dep; do
    [[ -n "$dep" ]] || continue
    found=1
    base="$(basename "$dep")"
    echo "    $dep -> @rpath/$base"
    cp -L "$dep" "$APP/Contents/Frameworks/$base"
    chmod u+w "$APP/Contents/Frameworks/$base"
    # The copy still advertises its Homebrew install name; rewrite it, then point
    # the executable at the bundled copy.
    install_name_tool -id "@rpath/$base" "$APP/Contents/Frameworks/$base"
    install_name_tool -change "$dep" "@rpath/$base" "$APP/Contents/MacOS/MacTR"
done < <(external_deps "$APP/Contents/MacOS/MacTR")
[[ $found -eq 1 ]] || echo "    (none)"

install_name_tool -add_rpath "@executable_path/../Frameworks" \
    "$APP/Contents/MacOS/MacTR" 2>/dev/null || true

# Toolchains bake their own absolute path into an LC_RPATH (Homebrew's Swift adds
# /opt/homebrew/Cellar/swift/...). Nothing resolves through it — the Swift runtime
# is ABI-stable and comes from /usr/lib/swift — but shipping a build-machine path
# in a public binary is noise, and it makes a local build diverge from CI's.
while IFS= read -r rp; do
    case "$rp" in
        /System/*|/usr/lib/*) ;;                      # system, legitimate
        @*) ;;                                        # bundle-relative, ours
        /*) echo "    dropping rpath $rp"
            install_name_tool -delete_rpath "$rp" "$APP/Contents/MacOS/MacTR" \
                2>/dev/null || true ;;
    esac
done < <(otool -l "$APP/Contents/MacOS/MacTR" | awk '/LC_RPATH/{f=1} f&&/ path /{print $2; f=0}')

# ---------------------------------------------------------------- sign
# Ad-hoc. Sign nested code before the outer bundle, otherwise the outer seal is
# computed over unsigned contents and fails verification.
echo "==> ad-hoc signing"
for lib in "$APP/Contents/Frameworks/"*; do
    [[ -e "$lib" ]] || continue
    codesign --force --timestamp=none --sign - "$lib"
done
codesign --force --timestamp=none --sign - "$APP"

# ---------------------------------------------------------------- verify
echo "==> verifying"
codesign --verify --deep --strict --verbose=2 "$APP"

leaked="$(external_deps "$APP/Contents/MacOS/MacTR")"
if [[ -n "$leaked" ]]; then
    echo "error: bundle still references machine-local dylibs:" >&2
    echo "$leaked" >&2
    exit 1
fi

echo "==> done: $APP"
du -sh "$APP" | awk '{print "    size: " $1}'
