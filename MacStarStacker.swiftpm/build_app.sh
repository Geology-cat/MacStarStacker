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

# かんたんインストーラ（コピー・Gatekeeperの解除・初回起動を行うAppleScript）
osacompile -o "$DMG_STAGING/かんたんインストーラ.scpt" "$PROJ_DIR/../scripts/かんたんインストーラ.applescript"

# 使い方ガイド（docs/manual/build.sh で作ったPDF。無ければ入れない）
GUIDE_PDF="$PROJ_DIR/../docs/MacStarStacker使い方ガイド.pdf"
if [ -f "$GUIDE_PDF" ]; then
    cp "$GUIDE_PDF" "$DMG_STAGING/"
else
    echo "WARNING: $GUIDE_PDF がありません（DMGに使い方ガイドを入れません）" >&2
fi

# Create README note for DMG
cat << EOF > "$DMG_STAGING/はじめにお読みください.txt"
MacStarStacker インストール＆初回起動ガイド
=============================================

【かんたんインストール（おすすめ）】
1. 「かんたんインストーラ.scpt」をダブルクリックして開きます（スクリプトエディタが開きます）。
2. ウインドウ上部の ▶（実行）ボタンを押し、「インストール」を選んでください。
   「アプリケーション」フォルダへのコピー、初回起動の確認（Gatekeeper）の解除、起動までを行います。
   「アプリケーション」フォルダに書き込めないときは、管理者のパスワードを求められます。

【手動でインストールする場合】
1. 「MacStarStacker.app」を「Applications」フォルダへドラッグ＆ドロップしてください。
2. 本ビルドはAppleのDeveloper IDでは署名・公証されていません。初回起動で止められたときは:
   ・macOS 15 以降: メッセージの「完了」を押して閉じ、システム設定 → プライバシーとセキュリティ の
     下の方にある「このまま開く」を押してください。
   ・macOS 14 以前: 「MacStarStacker.app」を右クリックし、「開く」を選択してください。

【使い方】
「MacStarStacker使い方ガイド.pdf」に、画面の見方から新星景モードまで、画面の写真付きで説明しています。

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
