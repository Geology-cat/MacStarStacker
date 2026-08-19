#!/bin/bash
# build_app.sh — MacStarStacker .app & .dmg builder
# Output: dist/MacStarStacker.app, dist/MacStarStacker.dmg
set -e

PROJ_DIR="$(cd "$(dirname "$0")" && pwd)"
DIST_DIR="$PROJ_DIR/../dist"
BUILD_DIR="$PROJ_DIR/.build/release"
APP_NAME="MacStarStacker"          # display name of the .app
BIN_NAME="MacSequator"             # SPM executable product name
APP_DIR="$DIST_DIR/${APP_NAME}.app"
DMG_PATH="$DIST_DIR/${APP_NAME}.dmg"
CONTENTS="$APP_DIR/Contents"
BIN_SRC="$BUILD_DIR/$BIN_NAME"
BUNDLE_SRC="$BUILD_DIR/${BIN_NAME}_MacSequator.bundle"
INFO_PLIST="$PROJ_DIR/Sources/MacSequator/Info.plist"

echo "=== Building release binary ==="
cd "$PROJ_DIR"
swift build -c release

echo "=== Assembling .app bundle in dist/ ==="
mkdir -p "$DIST_DIR"
rm -rf "$APP_DIR"
mkdir -p "$CONTENTS/MacOS"
mkdir -p "$CONTENTS/Resources"
mkdir -p "$CONTENTS/Frameworks"

# 1. Copy binary (place it in MacOS/ as the app display name)
cp "$BIN_SRC" "$CONTENTS/MacOS/$APP_NAME"

# 2. Copy Info.plist
cp "$PROJ_DIR/Sources/MacSequator/Info.plist" "$CONTENTS/Info.plist"

# 3. Copy Metal + resource bundle
if [ -d "$BUNDLE_SRC" ]; then
    cp -r "$BUNDLE_SRC" "$CONTENTS/Resources/"
fi

# 4. Copy app icon
ICNS_SRC="$PROJ_DIR/Sources/MacSequator/AppIcon.icns"
if [ -f "$ICNS_SRC" ]; then
    cp "$ICNS_SRC" "$CONTENTS/Resources/AppIcon.icns"
    echo "Icon: AppIcon.icns copied"
fi

# 5. Copy required OpenCV dylibs and fix rpaths
OPENCV_LIB_DIR="$(pkg-config --variable=libdir opencv4 2>/dev/null || echo '/usr/local/opt/opencv/lib')"
echo "=== Copying required OpenCV dylibs from $OPENCV_LIB_DIR ==="

REQUIRED_MODULES=("core" "imgproc" "imgcodecs" "features2d" "calib3d" "flann" "photo")

for MOD in "${REQUIRED_MODULES[@]}"; do
    for DYLIB in "$OPENCV_LIB_DIR"/libopencv_${MOD}*.dylib; do
        [ -f "$DYLIB" ] || continue
        BASENAME="$(basename "$DYLIB")"
        cp -L "$DYLIB" "$CONTENTS/Frameworks/$BASENAME"
        chmod 755 "$CONTENTS/Frameworks/$BASENAME"

        # Update reference in main binary
        install_name_tool -change "$DYLIB" \
            "@executable_path/../Frameworks/$BASENAME" \
            "$CONTENTS/MacOS/$APP_NAME" 2>/dev/null || true

        # Update the dylib's own id
        install_name_tool -id \
            "@loader_path/$BASENAME" \
            "$CONTENTS/Frameworks/$BASENAME" 2>/dev/null || true
    done
done

# Fix inter-dylib dependencies inside Frameworks
for DYLIB_FILE in "$CONTENTS/Frameworks"/libopencv_*.dylib; do
    [ -f "$DYLIB_FILE" ] || continue
    for MOD in "${REQUIRED_MODULES[@]}"; do
        for DEP in "$OPENCV_LIB_DIR"/libopencv_${MOD}*.dylib; do
            [ -f "$DEP" ] || continue
            DEP_BASENAME="$(basename "$DEP")"
            install_name_tool -change "$DEP" \
                "@loader_path/$DEP_BASENAME" \
                "$DYLIB_FILE" 2>/dev/null || true
        done
    done
done

# Add rpath
install_name_tool -add_rpath "@executable_path/../Frameworks" "$CONTENTS/MacOS/$APP_NAME" 2>/dev/null || true

# Copy Swift compatibility libraries for older macOS if needed (macOS 10.12-10.14)
SWIFT_LIB_DIR="$(xcode-select -p)/Toolchains/XcodeDefault.xctoolchain/usr/lib/swift-5.0/macosx"
if [ -d "$SWIFT_LIB_DIR" ]; then
    echo "=== Copying Swift compatibility libraries for macOS 10.12-10.14 ==="
    cp "$SWIFT_LIB_DIR"/libswift*.dylib "$CONTENTS/Frameworks/" 2>/dev/null || true
fi

# 6. Remove quarantine attribute (allows double-click to open)
xattr -cr "$APP_DIR" 2>/dev/null || true

# 7. Create DMG image in dist/
echo "=== Packaging DMG image in dist/ ==="
rm -f "$DMG_PATH"
hdiutil create -volname "$APP_NAME" -srcfolder "$APP_DIR" -ov -format UDZO "$DMG_PATH" > /dev/null

echo ""
echo "=== Done! ==="
echo "App bundle: $APP_DIR"
echo "DMG image:  $DMG_PATH"
echo ""
echo "To open: open \"$APP_DIR\""
