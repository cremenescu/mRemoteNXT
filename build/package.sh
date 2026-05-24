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
#  3. Re-sign the bundle ad-hoc (signature is invalidated by install_name_tool).
#  4. Wrap into a drag-to-Applications .dmg via hdiutil.
#
# Usage: ./build/package.sh [version]
#   version defaults to v0.1.0-alpha

set -euo pipefail

VERSION="${1:-v0.1.0-alpha}"
PROJECT_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
BUILD_DIR="$PROJECT_ROOT/.build-release"
DIST_DIR="$PROJECT_ROOT/.dist"
APP_NAME="mRemoteNXT"
DMG_NAME="${APP_NAME}-${VERSION}.dmg"

cd "$PROJECT_ROOT"

echo "==> Cleaning previous output"
rm -rf "$BUILD_DIR" "$DIST_DIR"
mkdir -p "$DIST_DIR"

echo "==> Generating Xcode project"
xcodegen generate >/dev/null

echo "==> Building Release"
xcodebuild -project "$APP_NAME.xcodeproj" -scheme "$APP_NAME" \
  -configuration Release -derivedDataPath "$BUILD_DIR" \
  CODE_SIGN_IDENTITY="-" CODE_SIGNING_ALLOWED=YES \
  build >/dev/null

APP="$BUILD_DIR/Build/Products/Release/$APP_NAME.app"
[ -d "$APP" ] || { echo "ERROR: built app not found at $APP"; exit 1; }
echo "    Built: $APP"

# Stage the .app in DIST_DIR (we mutate it).
cp -R "$APP" "$DIST_DIR/$APP_NAME.app"
APP="$DIST_DIR/$APP_NAME.app"
FRAMEWORKS="$APP/Contents/Frameworks"
mkdir -p "$FRAMEWORKS"

echo "==> Resolving and bundling Homebrew dylibs (recursive)"

# Set of paths considered "external" (need bundling).
is_external() {
  local p="$1"
  case "$p" in
    /opt/homebrew/*|/usr/local/*) return 0 ;;
    *) return 1 ;;
  esac
}

# Returns the canonical path (resolves symlinks like opt/foo -> Cellar/foo/...).
resolve() { python3 -c "import os,sys;print(os.path.realpath(sys.argv[1]))" "$1"; }

# bash 3.2 on macOS has no associative arrays; use plain files as sets.
SEEN_FILE="$(mktemp -t mrng_seen.XXXXXX)"
QUEUE_FILE="$(mktemp -t mrng_queue.XXXXXX)"
trap 'rm -f "$SEEN_FILE" "$QUEUE_FILE"' EXIT

mark_seen() { echo "$1" >> "$SEEN_FILE"; }
is_seen()   { grep -Fxq "$1" "$SEEN_FILE" 2>/dev/null; }

# Seed with all external deps of the main binary.
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

# Walk dependencies transitively (file-based queue; tail -n +N keeps growing).
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

# Copy each to Frameworks/ using its basename.
while IFS= read -r src; do
  base="$(basename "$src")"
  if [ ! -f "$FRAMEWORKS/$base" ]; then
    cp "$src" "$FRAMEWORKS/$base"
    chmod u+w "$FRAMEWORKS/$base"
  fi
done < "$QUEUE_FILE"

echo "==> Rewriting install names with install_name_tool"

# For every bundled lib: set its own id to @rpath/<basename>; rewrite its deps.
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

# Same for the main binary.
while IFS= read -r line; do
  dep="$(echo "$line" | awk '{print $1}')"
  if is_external "$dep"; then
    install_name_tool -change "$dep" "@rpath/$(basename "$(resolve "$dep")")" "$MAIN_BIN" 2>/dev/null || true
  fi
done < <(otool -L "$MAIN_BIN" | tail -n +2)

# Ensure the binary has an rpath pointing into Frameworks/.
# Strip any existing /opt/homebrew rpaths so we don't leak the build host's paths.
EXISTING_RPATHS="$(otool -l "$MAIN_BIN" | awk '/LC_RPATH/{flag=1;next} flag && /path /{print $2; flag=0}')"
for rp in $EXISTING_RPATHS; do
  case "$rp" in
    /opt/homebrew/*|/usr/local/*) install_name_tool -delete_rpath "$rp" "$MAIN_BIN" 2>/dev/null || true ;;
  esac
done
if ! echo "$EXISTING_RPATHS" | grep -q "@executable_path/../Frameworks"; then
  install_name_tool -add_rpath "@executable_path/../Frameworks" "$MAIN_BIN"
fi

echo "==> Re-signing bundle (ad-hoc)"
codesign --force --deep --sign - "$APP" 2>/dev/null

# Sanity: every dependency of the main binary should now be either a system
# framework, an @rpath/... or an absolute /usr/lib/... path. Anything else is a leak.
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

echo "==> Building .dmg"
DMG_STAGE="$DIST_DIR/dmg_stage"
rm -rf "$DMG_STAGE"
mkdir -p "$DMG_STAGE"
cp -R "$APP" "$DMG_STAGE/"
ln -s /Applications "$DMG_STAGE/Applications"
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

# Create dmg.
rm -f "$DIST_DIR/$DMG_NAME"
hdiutil create -volname "$APP_NAME" -srcfolder "$DMG_STAGE" \
  -ov -format UDZO "$DIST_DIR/$DMG_NAME" >/dev/null

rm -rf "$DMG_STAGE"

SIZE="$(du -h "$DIST_DIR/$DMG_NAME" | cut -f1)"
echo ""
echo "==> Done"
echo "    DMG: $DIST_DIR/$DMG_NAME ($SIZE)"
echo "    Upload to GitHub release with:"
echo "      gh release upload $VERSION $DIST_DIR/$DMG_NAME --repo cremenescu/mRemoteNXT"
