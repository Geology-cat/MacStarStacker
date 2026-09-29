#!/bin/bash
# build_app.sh — MacStarStacker .app & .dmg builder
# Output: dist/MacStarStacker.app, dist/MacStarStacker.dmg
set -euo pipefail

PROJ_DIR="$(cd "$(dirname "$0")" && pwd)"
DIST_DIR="$PROJ_DIR/../dist"
# Package.swift の deploymentTarget と合わせる
DEPLOYMENT_TARGET="14.0"
ARCHS=(arm64 x86_64)
BUILD_DIR="$PROJ_DIR/.build/apple/Products/Release"
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

echo "=== Building dependencies (OpenCV / LibRaw) ==="
bash "$PROJ_DIR/../scripts/build_deps.sh" "$DEPLOYMENT_TARGET"

echo "=== Building release binary (${ARCHS[*]}) ==="
cd "$PROJ_DIR"
ARCH_ARGS=()
for ARCH in "${ARCHS[@]}"; do
    ARCH_ARGS+=(--arch "$ARCH")
done
swift build -c release "${ARCH_ARGS[@]}"

echo "=== Assembling .app bundle in dist/ ==="
mkdir -p "$DIST_DIR"
rm -rf "$APP_DIR"
mkdir -p "$CONTENTS/MacOS"
mkdir -p "$CONTENTS/Resources"

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

# 5. 依存ライブラリは静的リンクのため、システム外のdylibを参照していないこと・全アーキテクチャを含むことを確認
EXTERNAL_DYLIBS="$(otool -L "$CONTENTS/MacOS/$APP_NAME" | tail -n +2 | awk '{print $1}' \
    | grep -vE '^(/System/|/usr/lib/)' || true)"
if [ -n "$EXTERNAL_DYLIBS" ]; then
    echo "ERROR: System-external libraries are referenced:" >&2
    echo "$EXTERNAL_DYLIBS" >&2
    exit 1
fi
for ARCH in "${ARCHS[@]}"; do
    if ! lipo "$CONTENTS/MacOS/$APP_NAME" -verify_arch "$ARCH"; then
        echo "ERROR: $ARCH slice is missing" >&2
        exit 1
    fi
done
echo "Architectures: $(lipo -archs "$CONTENTS/MacOS/$APP_NAME")"

# 6. 隔離属性を除去し、アドホック署名を付与
xattr -cr "$APP_DIR" 2>/dev/null || true
codesign --force --deep --sign - "$APP_DIR"
codesign --verify --deep --strict --verbose=2 "$APP_DIR"

# 7. DMG staging area
rm -rf "$DMG_STAGING"
mkdir -p "$DMG_STAGING"
echo "=== Preparing DMG Contents ==="
# Copy .app to staging
cp -R "$APP_DIR" "$DMG_STAGING/"

# Create symlink to /Applications
ln -s /Applications "$DMG_STAGING/Applications"

# Create README note for DMG
cat << EOF > "$DMG_STAGING/はじめにお読みください.txt"
MacStarStacker インストール＆初回起動ガイド
=============================================

【インストール方法】
1. 「MacStarStacker.app」を「Applications」フォルダへドラッグ＆ドロップしてください。

【初回起動時の注意】
本ビルドはAppleのDeveloper IDでは署名・公証されていません。
警告が出た場合は「MacStarStacker.app」を右クリックし、「開く」を選択してください。

対応OS: macOS 14 (Sonoma) 以降
収録アーキテクチャ: Universal（Apple Silicon / Intel のどちらでもネイティブ動作）
EOF

# 8. Create DMG package
echo "=== Packaging DMG image in dist/ ==="
rm -f "$DMG_PATH"
hdiutil create -volname "$APP_NAME" -srcfolder "$DMG_STAGING" -ov -format UDZO "$DMG_PATH" > /dev/null

# Clean staging
rm -rf "$DMG_STAGING"

echo ""
echo "=== Done! ==="
echo "App bundle: $APP_DIR"
echo "DMG image:  $DMG_PATH"
echo ""
echo "To open: open \"$APP_DIR\""
