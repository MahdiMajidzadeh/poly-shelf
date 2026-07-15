#!/bin/bash
# Builds PolyShelf.app with SwiftPM only (no Xcode required).
# Output: dist/PolyShelf.app — ad-hoc signed, sandboxed, read-only file access.
set -euo pipefail

cd "$(dirname "$0")/.."
CONFIG="${1:-release}"
# Override the bundle version via env (CI passes the git tag). Patched into the
# built Info.plist before codesign so the signature stays valid.
VERSION="${MARKETING_VERSION:-0.1.0}"

echo "▸ swift build -c $CONFIG"
swift build -c "$CONFIG"

BUILD_DIR=".build/$CONFIG"
APP="dist/PolyShelf.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"

cp "$BUILD_DIR/PolyShelf" "$APP/Contents/MacOS/PolyShelf"
# SwiftPM resource bundles (tag dictionary etc.) — Bundle.module finds them
# in Contents/Resources of the main bundle. -L: $BUILD_DIR is a symlink.
find -L "$BUILD_DIR" -maxdepth 1 -name '*.bundle' -exec cp -R {} "$APP/Contents/Resources/" \;
# App icon — CFBundleIconFile (below) resolves AppIcon.icns in Contents/Resources.
cp PolyShelf/Support/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"

cat > "$APP/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
	<key>CFBundleExecutable</key>
	<string>PolyShelf</string>
	<key>CFBundleIconFile</key>
	<string>AppIcon</string>
	<key>CFBundleIdentifier</key>
	<string>com.mahdimajidzadeh.polyshelf</string>
	<key>CFBundleName</key>
	<string>Poly Shelf</string>
	<key>CFBundleDisplayName</key>
	<string>Poly Shelf</string>
	<key>CFBundlePackageType</key>
	<string>APPL</string>
	<key>CFBundleShortVersionString</key>
	<string>0.1.0</string>
	<key>CFBundleVersion</key>
	<string>1</string>
	<key>LSMinimumSystemVersion</key>
	<string>14.0</string>
	<key>LSApplicationCategoryType</key>
	<string>public.app-category.graphics-design</string>
	<key>NSPrincipalClass</key>
	<string>NSApplication</string>
	<key>NSHighResolutionCapable</key>
	<true/>
</dict>
</plist>
PLIST

/usr/libexec/PlistBuddy -c "Set :CFBundleShortVersionString $VERSION" "$APP/Contents/Info.plist"

echo "▸ codesign (ad-hoc, sandboxed)"
codesign --force --sign - \
    --entitlements PolyShelf/Support/PolyShelf.entitlements \
    --options runtime \
    "$APP"

codesign --display --entitlements - "$APP" 2>&1 | grep -E 'app-sandbox|read-only' || true
echo "✓ Built $APP"
