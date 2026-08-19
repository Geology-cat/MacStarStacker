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
DMG_STAGING="$PROJ_DIR/.build/dmg_staging"
CONTENTS="$APP_DIR/Contents"
BIN_SRC="$BUILD_DIR/$BIN_NAME"
BUNDLE_SRC="$BUILD_DIR/${BIN_NAME}_MacSequator.bundle"
INFO_PLIST="$PROJ_DIR/Sources/MacSequator/Info.plist"
ICNS_SRC="$PROJ_DIR/Sources/MacSequator/AppIcon.icns"

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
cp "$INFO_PLIST" "$CONTENTS/Info.plist"

# 3. Copy Metal + resource bundle
if [ -d "$BUNDLE_SRC" ]; then
    cp -r "$BUNDLE_SRC" "$CONTENTS/Resources/"
fi

# 4. Copy app icon
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

# 7. Build Gatekeeper Unlock AppleScript Application
echo "=== Building Gatekeeper Unlock AppleScript App ==="
GATEKEEPER_APP="$DMG_STAGING/初回起動（Gatekeeper解除）.app"
rm -rf "$DMG_STAGING"
mkdir -p "$DMG_STAGING"

# AppleScript source code
APPLESCRIPT_SRC="$PROJ_DIR/.build/unlock_gatekeeper.applescript"
cat << 'EOF' > "$APPLESCRIPT_SRC"
tell application "Finder"
	set currentFolder to POSIX path of ((container of (path to me)) as text)
	set localApp to currentFolder & "MacStarStacker.app"
	set installedApp to "/Applications/MacStarStacker.app"
end tell

try
	do shell script "xattr -dr com.apple.quarantine " & quoted form of localApp & " 2>/dev/null || true"
	do shell script "xattr -dr com.apple.quarantine " & quoted form of installedApp & " 2>/dev/null || true"
	
	set res to display dialog "Gatekeeperのセキュリティ制限（未確認の開発元警告）を解除しました。" & return & return & "MacStarStacker を起動しますか？" buttons {"キャンセル", "起動する"} default button "起動する" with title "MacStarStacker 初回起動アシスタント" with icon note
	
	if button returned of res is "起動する" then
		try
			do shell script "open " & quoted form of installedApp
		on error
			do shell script "open " & quoted form of localApp
		end try
	end if
on error errMsg
	display alert "エラーが発生しました" message errMsg as critical
end try
EOF

osacompile -o "$GATEKEEPER_APP" "$APPLESCRIPT_SRC"

# Copy AppIcon to Gatekeeper unlock app if available
if [ -f "$ICNS_SRC" ]; then
    cp "$ICNS_SRC" "$GATEKEEPER_APP/Contents/Resources/applet.icns"
fi

# 8. Assemble DMG Staging Area
echo "=== Preparing DMG Contents ==="
# Copy .app to staging
cp -R "$APP_DIR" "$DMG_STAGING/"

# Create symlink to /Applications
ln -s /Applications "$DMG_STAGING/Applications"

# Create README note for DMG
cat << 'EOF' > "$DMG_STAGING/はじめにお読みください.txt"
MacStarStacker インストール＆初回起動ガイド
=============================================

【インストール方法】
1. 「MacStarStacker.app」を「Applications」フォルダへドラッグ＆ドロップしてください。

【初回起動時の注意（Gatekeeper警告が出る場合）】
macOSのセキュリティ機能により「開発元が未確認のため開けません」と表示された場合は、
同梱の「初回起動（Gatekeeper解除）.app」をダブルクリックして実行してください。
セキュリティ制限が解除され、正常に起動できるようになります。

または、以下のいずれかの方法でも起動可能です：
・「MacStarStacker.app」を右クリック（二本指タップ）し、メニューから「開く」を選択する。
・「システム設定（システム環境設定）」>「プライバシーとセキュリティ」から「このまま開く」をクリックする。

対応OS: macOS 10.12 (Sierra) 〜 macOS 15+ (Sequoia)
EOF

# 9. Create DMG package
echo "=== Packaging DMG image in dist/ ==="
rm -f "$DMG_PATH"
hdiutil create -volname "$APP_NAME" -srcfolder "$DMG_STAGING" -ov -format UDZO "$DMG_PATH" > /dev/null

# Clean staging
rm -rf "$DMG_STAGING" "$APPLESCRIPT_SRC"

echo ""
echo "=== Done! ==="
echo "App bundle: $APP_DIR"
echo "DMG image:  $DMG_PATH"
echo ""
echo "To open: open \"$APP_DIR\""
