#!/bin/bash
# SPDX-License-Identifier: GPL-2.0-or-later
# mRemoteNXT — Copyright (c) 2026 Razvan Cremenescu
#
# Builds a self-contained .app + .dmg for distribution.
#
# Steps:
#  1. xcodebuild Release -> mRemoteNXT.app linked to /opt/homebrew/... dylibs
#  2. Recursively copy every /opt/homebrew/... and /usr/local/... dylib into
#     mRemoteNXT.app/Contents/Frameworks/, rewriting install names with
#     install_name_tool so the bundle has no external Homebrew dependency.
#  3. Sign every bundled dylib AND the main app with Developer ID + hardened
#     runtime + secure timestamp + entitlements. Falls back to ad-hoc signing
#     when the Developer ID cert is not present (local dev builds).
#  4. Wrap into a drag-to-Applications .dmg via hdiutil.
#  5. Sign the .dmg, submit to Apple notary service, staple the ticket and
#     verify Gatekeeper acceptance. Skipped on ad-hoc builds.
#
# Usage: ./build/package.sh [version]
#   version defaults to v0.1.0-alpha
#
# Notarization requires a stored keychain profile named "mRemoteNXT-notary":
#   xcrun notarytool store-credentials mRemoteNXT-notary \
#       --apple-id <your-apple-id> --team-id FU62DHV366 --password <app-pwd>

set -euo pipefail

VERSION="${1:-v0.1.0-alpha}"
PROJECT_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
BUILD_DIR="$PROJECT_ROOT/.build-release"
DIST_DIR="$PROJECT_ROOT/.dist"
APP_NAME="mRemoteNXT"
DMG_NAME="${APP_NAME}-${VERSION}.dmg"
ENTITLEMENTS="$PROJECT_ROOT/build/entitlements.plist"

# Developer ID signing config. Set DEVELOPER_ID="-" via env to force ad-hoc.
DEVELOPER_ID="${DEVELOPER_ID:-Developer ID Application: Vtun Hardware SRL (FU62DHV366)}"
NOTARY_PROFILE="${NOTARY_PROFILE:-mRemoteNXT-notary}"

# Detect whether the Developer ID cert is actually present. If not, fall back
# to ad-hoc signing and skip notarization (useful for local builds).
SIGN_MODE="adhoc"
if [ "$DEVELOPER_ID" != "-" ] && \
   security find-identity -v -p codesigning | grep -qF "$DEVELOPER_ID"; then
    SIGN_MODE="developer-id"
fi

cd "$PROJECT_ROOT"

echo "==> Cleaning previous output"
rm -rf "$BUILD_DIR" "$DIST_DIR"
mkdir -p "$DIST_DIR"

echo "==> Generating Xcode project"
xcodegen generate >/dev/null

echo "==> Building Release (sign mode: $SIGN_MODE)"
if [ "$SIGN_MODE" = "developer-id" ]; then
    # Build unsigned; we sign by hand after install_name_tool surgery anyway.
    # Hardened Runtime is enabled at codesign time via --options runtime.
    xcodebuild -project "$APP_NAME.xcodeproj" -scheme "$APP_NAME" \
      -configuration Release -derivedDataPath "$BUILD_DIR" \
      CODE_SIGN_IDENTITY="-" CODE_SIGNING_ALLOWED=YES \
      build >/dev/null
else
    xcodebuild -project "$APP_NAME.xcodeproj" -scheme "$APP_NAME" \
      -configuration Release -derivedDataPath "$BUILD_DIR" \
      CODE_SIGN_IDENTITY="-" CODE_SIGNING_ALLOWED=YES \
      build >/dev/null
fi

APP="$BUILD_DIR/Build/Products/Release/$APP_NAME.app"
[ -d "$APP" ] || { echo "ERROR: built app not found at $APP"; exit 1; }
echo "    Built: $APP"

# Stage the .app in DIST_DIR (we mutate it).
cp -R "$APP" "$DIST_DIR/$APP_NAME.app"
APP="$DIST_DIR/$APP_NAME.app"
FRAMEWORKS="$APP/Contents/Frameworks"
mkdir -p "$FRAMEWORKS"

echo "==> Resolving and bundling Homebrew dylibs (recursive)"

is_external() {
  local p="$1"
  case "$p" in
    /opt/homebrew/*|/usr/local/*) return 0 ;;
    *) return 1 ;;
  esac
}

resolve() { python3 -c "import os,sys;print(os.path.realpath(sys.argv[1]))" "$1"; }

# bash 3.2 on macOS has no associative arrays; use plain files as sets.
SEEN_FILE="$(mktemp -t mrng_seen.XXXXXX)"
QUEUE_FILE="$(mktemp -t mrng_queue.XXXXXX)"
trap 'rm -f "$SEEN_FILE" "$QUEUE_FILE"' EXIT

mark_seen() { echo "$1" >> "$SEEN_FILE"; }
is_seen()   { grep -Fxq "$1" "$SEEN_FILE" 2>/dev/null; }

seed_from() {
  local bin="$1"
  local line dep real
  while IFS= read -r line; do
    dep="$(echo "$line" | awk '{print $1}')"
    if is_external "$dep"; then
      real="$(resolve "$dep")"
      if ! is_seen "$real"; then
        mark_seen "$real"
        echo "$real" >> "$QUEUE_FILE"
      fi
    fi
  done < <(otool -L "$bin" | tail -n +2)
}

MAIN_BIN="$APP/Contents/MacOS/$APP_NAME"
seed_from "$MAIN_BIN"

processed=0
while :; do
  total=$(wc -l < "$QUEUE_FILE" | tr -d ' ')
  [ "$processed" -ge "$total" ] && break
  processed=$((processed+1))
  dep="$(sed -n "${processed}p" "$QUEUE_FILE")"
  seed_from "$dep"
done

count=$(wc -l < "$QUEUE_FILE" | tr -d ' ')
echo "    Found $count external dylibs to bundle"

while IFS= read -r src; do
  base="$(basename "$src")"
  if [ ! -f "$FRAMEWORKS/$base" ]; then
    cp "$src" "$FRAMEWORKS/$base"
    chmod u+w "$FRAMEWORKS/$base"
  fi
done < "$QUEUE_FILE"

# OpenSSL legacy provider — NOT a link-time dependency (loaded at runtime via
# OSSL_PROVIDER_load in RDPCore.c), so the recursive resolver above never sees
# it. Bundle it by hand into Frameworks/ (flat, so the rewrite + sign loops
# below treat it like any other bundled dylib). It supplies MD4, which NTLM /
# NLA needs to authenticate against non-AD (workgroup) Windows hosts such as an
# EC2 Windows instance; without it RDP dies at NLA with a misleading
# ERRCONNECT_CONNECT_TRANSPORT_FAILED. RDPClient.initCrypto points OpenSSL's
# module search path at Frameworks/ at launch.
OSSL_LEGACY_SRC="$(resolve /opt/homebrew/lib/ossl-modules/legacy.dylib)"
if [ -f "$OSSL_LEGACY_SRC" ]; then
  cp "$OSSL_LEGACY_SRC" "$FRAMEWORKS/legacy.dylib"
  chmod u+w "$FRAMEWORKS/legacy.dylib"
  echo "    Bundled OpenSSL legacy provider (MD4 for NTLM): legacy.dylib"
else
  echo "ERROR: OpenSSL legacy provider not found at /opt/homebrew/lib/ossl-modules/legacy.dylib"
  echo "       RDP NTLM auth to non-AD Windows hosts would break. Install openssl@3 (brew install openssl@3)."
  exit 1
fi

echo "==> Rewriting install names with install_name_tool"

for lib in "$FRAMEWORKS"/*.dylib; do
  base="$(basename "$lib")"
  install_name_tool -id "@rpath/$base" "$lib" 2>/dev/null || true
  while IFS= read -r line; do
    dep="$(echo "$line" | awk '{print $1}')"
    [ "$dep" = "$lib" ] && continue
    if is_external "$dep"; then
      install_name_tool -change "$dep" "@rpath/$(basename "$(resolve "$dep")")" "$lib" 2>/dev/null || true
    fi
  done < <(otool -L "$lib" | tail -n +2)
done

while IFS= read -r line; do
  dep="$(echo "$line" | awk '{print $1}')"
  if is_external "$dep"; then
    install_name_tool -change "$dep" "@rpath/$(basename "$(resolve "$dep")")" "$MAIN_BIN" 2>/dev/null || true
  fi
done < <(otool -L "$MAIN_BIN" | tail -n +2)

EXISTING_RPATHS="$(otool -l "$MAIN_BIN" | awk '/LC_RPATH/{flag=1;next} flag && /path /{print $2; flag=0}')"
for rp in $EXISTING_RPATHS; do
  case "$rp" in
    /opt/homebrew/*|/usr/local/*) install_name_tool -delete_rpath "$rp" "$MAIN_BIN" 2>/dev/null || true ;;
  esac
done
if ! echo "$EXISTING_RPATHS" | grep -q "@executable_path/../Frameworks"; then
  install_name_tool -add_rpath "@executable_path/../Frameworks" "$MAIN_BIN"
fi

# Sanity check before signing.
echo "==> Verifying no Homebrew leaks"
LEAKS="$(otool -L "$MAIN_BIN" | tail -n +2 | awk '{print $1}' | grep -E '^/opt/|^/usr/local/' || true)"
if [ -n "$LEAKS" ]; then
  echo "ERROR: main binary still references Homebrew paths:"
  echo "$LEAKS"
  exit 1
fi
for lib in "$FRAMEWORKS"/*.dylib; do
  LEAKS="$(otool -L "$lib" | tail -n +2 | awk '{print $1}' | grep -E '^/opt/|^/usr/local/' || true)"
  if [ -n "$LEAKS" ]; then
    echo "ERROR: $(basename "$lib") still references Homebrew paths:"
    echo "$LEAKS"
    exit 1
  fi
done
echo "    OK — bundle is self-contained"

if [ "$SIGN_MODE" = "developer-id" ]; then
    echo "==> Signing bundle with Developer ID + hardened runtime"
    # Sign every bundled dylib first (inside-out), then the main binary, then
    # the .app wrapper with entitlements. --options runtime enables Hardened
    # Runtime; --timestamp embeds an Apple secure timestamp (required for
    # notarization).
    for lib in "$FRAMEWORKS"/*.dylib; do
        codesign --force --sign "$DEVELOPER_ID" \
                 --options runtime --timestamp \
                 "$lib"
    done
    codesign --force --sign "$DEVELOPER_ID" \
             --options runtime --timestamp \
             --entitlements "$ENTITLEMENTS" \
             "$MAIN_BIN"
    codesign --force --sign "$DEVELOPER_ID" \
             --options runtime --timestamp \
             --entitlements "$ENTITLEMENTS" \
             "$APP"

    echo "==> Verifying signature"
    codesign --verify --deep --strict --verbose=2 "$APP"
else
    echo "==> Re-signing bundle (ad-hoc — no Developer ID present)"
    codesign --force --deep --sign - "$APP" 2>/dev/null
fi

echo "==> Building .dmg"
DMG_STAGE="$DIST_DIR/dmg_stage"
rm -rf "$DMG_STAGE"
mkdir -p "$DMG_STAGE"
cp -R "$APP" "$DMG_STAGE/"
ln -s /Applications "$DMG_STAGE/Applications"

if [ "$SIGN_MODE" = "developer-id" ]; then
    cat > "$DMG_STAGE/INSTALL.txt" <<EOF
mRemoteNXT — install

1. Drag mRemoteNXT.app into the Applications folder shortcut.
2. Open mRemoteNXT.app from /Applications.

The app is signed and notarized by Apple — no Gatekeeper warning.

Sources: https://github.com/cremenescu/mRemoteNXT
License: GPL-2.0-or-later
EOF
else
    cat > "$DMG_STAGE/INSTALL.txt" <<EOF
mRemoteNXT — install

1. Drag mRemoteNXT.app into the Applications folder shortcut.
2. The first launch shows a Gatekeeper warning because the app is
   ad-hoc signed (no paid Apple Developer ID). To clear it, run once:

       xattr -dr com.apple.quarantine /Applications/mRemoteNXT.app

3. Open mRemoteNXT.app from /Applications.

Sources: https://github.com/cremenescu/mRemoteNXT
License: GPL-2.0-or-later
EOF
fi

rm -f "$DIST_DIR/$DMG_NAME"
hdiutil create -volname "$APP_NAME" -srcfolder "$DMG_STAGE" \
  -ov -format UDZO "$DIST_DIR/$DMG_NAME" >/dev/null

rm -rf "$DMG_STAGE"

if [ "$SIGN_MODE" = "developer-id" ]; then
    echo "==> Signing .dmg"
    codesign --force --sign "$DEVELOPER_ID" --timestamp "$DIST_DIR/$DMG_NAME"

    echo "==> Submitting to Apple notary service (this can take a few minutes)"
    if ! xcrun notarytool submit "$DIST_DIR/$DMG_NAME" \
            --keychain-profile "$NOTARY_PROFILE" \
            --wait; then
        echo "ERROR: notarization failed. Pull the log with:"
        echo "  xcrun notarytool history --keychain-profile $NOTARY_PROFILE"
        echo "  xcrun notarytool log <submission-id> --keychain-profile $NOTARY_PROFILE"
        exit 1
    fi

    echo "==> Stapling notarization ticket"
    xcrun stapler staple "$DIST_DIR/$DMG_NAME"

    echo "==> Verifying with Gatekeeper"
    spctl --assess --type open --context context:primary-signature -vv "$DIST_DIR/$DMG_NAME"
fi

SIZE="$(du -h "$DIST_DIR/$DMG_NAME" | cut -f1)"
echo ""
echo "==> Done (sign mode: $SIGN_MODE)"
echo "    DMG: $DIST_DIR/$DMG_NAME ($SIZE)"
echo "    Upload to GitHub release with:"
echo "      gh release upload $VERSION $DIST_DIR/$DMG_NAME --repo cremenescu/mRemoteNXT"
