#!/bin/bash
# build_app.sh — MacStarStacker .app & .dmg builder
# Output: dist/MacStarStacker.app, dist/MacStarStacker.dmg
set -euo pipefail

PROJ_DIR="$(cd "$(dirname "$0")" && pwd)"
DIST_DIR="$PROJ_DIR/../dist"
# Package.swift の deploymentTarget と合わせる
DEPLOYMENT_TARGET="10.13"
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

# 5. macOS 10.14.4 より前のOSにはSwiftランタイムが無いため、アプリに同梱する（x86_64のみ。arm64はmacOS 11以降）。
#    実行ファイルの LC_RPATH は /usr/lib/swift が @executable_path/../Frameworks より先に並ぶため、
#    新しいOSではOS内蔵のランタイムが使われ、同梱分は macOS 10.13〜10.14.3 でだけ読み込まれる。
SWIFT_BACKDEPLOY_DIR="$(xcode-select -p)/Toolchains/XcodeDefault.xctoolchain/usr/lib/swift-5.0/macosx"
if [ ! -f "$SWIFT_BACKDEPLOY_DIR/libswiftCore.dylib" ]; then
    echo "ERROR: Swift runtime for back-deployment not found: $SWIFT_BACKDEPLOY_DIR" >&2
    echo "       Xcode 16.x を使ってください（新しいXcodeでは10.13向けの同梱用ランタイムが無い可能性があります）" >&2
    exit 1
fi
mkdir -p "$CONTENTS/Frameworks"
xcrun swift-stdlib-tool --copy --platform macosx \
    --scan-executable "$CONTENTS/MacOS/$APP_NAME" \
    --source-libraries "$SWIFT_BACKDEPLOY_DIR" \
    --destination "$CONTENTS/Frameworks"
install_name_tool -add_rpath "@executable_path/../Frameworks" "$CONTENTS/MacOS/$APP_NAME"
echo "Embedded Swift runtime: $(ls "$CONTENTS/Frameworks" | wc -l | tr -d ' ') libraries"

RPATHS="$(otool -arch x86_64 -l "$CONTENTS/MacOS/$APP_NAME" | awk '/LC_RPATH/{getline; getline; print $2}')"
if [ "$(echo "$RPATHS" | grep -n '^/usr/lib/swift$' | cut -d: -f1)" -gt \
     "$(echo "$RPATHS" | grep -n '^@executable_path/../Frameworks$' | cut -d: -f1)" ]; then
    echo "ERROR: /usr/lib/swift must precede @executable_path/../Frameworks in LC_RPATH:" >&2
    echo "$RPATHS" >&2
    exit 1
fi

# 6. 依存ライブラリは静的リンクのため、システム外のdylibを参照していないこと・全アーキテクチャを含むことを確認
# システムのライブラリと、同梱したSwiftランタイム以外への参照を出力する
list_external_dylibs() {
    local ARCH DEP
    for ARCH in "${ARCHS[@]}"; do
        otool -arch "$ARCH" -L "$CONTENTS/MacOS/$APP_NAME" | tail -n +2 | awk '{print $1}'
    done | sort -u | while IFS= read -r DEP; do
        case "$DEP" in
            /System/*|/usr/lib/*) ;;
            @rpath/libswift*) [ -f "$CONTENTS/Frameworks/${DEP#@rpath/}" ] || echo "$DEP" ;;
            *) echo "$DEP" ;;
        esac
    done
}
EXTERNAL_DYLIBS="$(list_external_dylibs)"
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

# 7. 隔離属性を除去し、アドホック署名を付与
xattr -cr "$APP_DIR" 2>/dev/null || true
codesign --force --deep --sign - "$APP_DIR"
codesign --verify --deep --strict --verbose=2 "$APP_DIR"

# 8. DMG staging area
rm -rf "$DMG_STAGING"
mkdir -p "$DMG_STAGING"
echo "=== Preparing DMG Contents ==="
# Copy .app to staging
cp -R "$APP_DIR" "$DMG_STAGING/"

# Create symlink to /Applications
ln -s /Applications "$DMG_STAGING/Applications"

# かんたんインストーラ（コピー・Gatekeeperの解除・初回起動を行うAppleScript）
osacompile -o "$DMG_STAGING/かんたんインストーラ.scpt" "$PROJ_DIR/../scripts/かんたんインストーラ.applescript"

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
2. 本ビルドはAppleのDeveloper IDでは署名・公証されていません。
   初回起動で警告が出た場合は「MacStarStacker.app」を右クリックし、「開く」を選択してください。

対応OS: macOS 10.13 (High Sierra) 以降（Apple Silicon Mac は macOS 11 以降）
収録アーキテクチャ: Universal（Apple Silicon / Intel のどちらでもネイティブ動作）

【古いMacでの注意】
・Metal非対応のMac（おおむね2011年以前）では、GPUを使わずCPUで合成するため時間がかかります。
・H.265/HEVCの動画書き出しは、HEVCのハードウェアエンコーダーを持つMacでのみ選択できます。
EOF

# 9. Create DMG package
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
