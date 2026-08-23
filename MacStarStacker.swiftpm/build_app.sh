#!/bin/bash
# build_app.sh — MacStarStacker .app & .dmg builder
# Output: dist/MacStarStacker.app, dist/MacStarStacker.dmg
set -euo pipefail

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
BUILD_ARCH="$(uname -m)"

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

# 5. Homebrew/OpenCV の非システム依存ライブラリを再帰的に同梱
OPENCV_LIB_DIR="$(pkg-config --variable=libdir opencv4 2>/dev/null || echo '/usr/local/opt/opencv/lib')"
BREW_PREFIX="$(brew --prefix 2>/dev/null || dirname "$(dirname "$OPENCV_LIB_DIR")")"
echo "=== Bundling non-system dylibs from $BREW_PREFIX ==="

REQUIRED_MODULES=("core" "imgproc" "imgcodecs" "features2d" "calib3d" "flann" "photo")

for MOD in "${REQUIRED_MODULES[@]}"; do
    DYLIB="$(find "$OPENCV_LIB_DIR" -maxdepth 1 -name "libopencv_${MOD}.*.dylib" -print | sort | tail -1)"
    if [ -z "$DYLIB" ]; then
        echo "ERROR: OpenCV module not found: $MOD" >&2
        exit 1
    fi
    cp -L "$DYLIB" "$CONTENTS/Frameworks/$(basename "$DYLIB")"
done

BREW_DYLIB_INDEX="$PROJ_DIR/.build/brew_dylib_index.txt"
find -L "$BREW_PREFIX/opt" -type f -name '*.dylib' -print > "$BREW_DYLIB_INDEX"

resolve_dependency() {
    local dep="$1"
    local basename_dep
    basename_dep="$(basename "$dep")"

    if [[ "$dep" == /* ]] && [ -f "$dep" ]; then
        printf '%s\n' "$dep"
        return 0
    fi
    if [[ "$dep" == @rpath/* ]]; then
        # 事前作成した索引を使い、間接依存ごとのHomebrew全探索を避ける。
        awk -v suffix="/lib/$basename_dep" 'index($0, suffix) == length($0) - length(suffix) + 1 { print; exit }' "$BREW_DYLIB_INDEX"
        return 0
    fi
    return 1
}

# 新しい依存が見つからなくなるまで、コピーと参照書き換えを繰り返す。
while :; do
    BEFORE_COUNT="$(find "$CONTENTS/Frameworks" -maxdepth 1 -type f | wc -l | tr -d ' ')"
    TARGETS=("$CONTENTS/MacOS/$APP_NAME")
    while IFS= read -r FRAMEWORK_DYLIB; do
        TARGETS+=("$FRAMEWORK_DYLIB")
    done < <(find "$CONTENTS/Frameworks" -maxdepth 1 -type f -name '*.dylib' -print | sort)

    for TARGET in "${TARGETS[@]}"; do
        while IFS= read -r DEP; do
            case "$DEP" in
                /System/*|/usr/lib/*) continue ;;
            esac

            SRC="$(resolve_dependency "$DEP" || true)"
            [ -n "$SRC" ] || continue
            DEP_BASENAME="$(basename "$SRC")"
            DEST="$CONTENTS/Frameworks/$DEP_BASENAME"
            if [ ! -f "$DEST" ]; then
                cp -L "$SRC" "$DEST"
                chmod 755 "$DEST"
            fi

            if [ "$TARGET" = "$CONTENTS/MacOS/$APP_NAME" ]; then
                NEW_DEP="@executable_path/../Frameworks/$DEP_BASENAME"
            else
                NEW_DEP="@loader_path/$DEP_BASENAME"
            fi
            install_name_tool -change "$DEP" "$NEW_DEP" "$TARGET"
        done < <(otool -L "$TARGET" | tail -n +2 | awk '{print $1}')
    done

    AFTER_COUNT="$(find "$CONTENTS/Frameworks" -maxdepth 1 -type f | wc -l | tr -d ' ')"
    [ "$BEFORE_COUNT" = "$AFTER_COUNT" ] && break
done

for DYLIB_FILE in "$CONTENTS/Frameworks"/*.dylib; do
    install_name_tool -id "@rpath/$(basename "$DYLIB_FILE")" "$DYLIB_FILE"
done

install_name_tool -add_rpath "@executable_path/../Frameworks" "$CONTENTS/MacOS/$APP_NAME" 2>/dev/null || true

UNBUNDLED="$(
    find "$CONTENTS/MacOS" "$CONTENTS/Frameworks" -type f -perm -111 -print0 |
    while IFS= read -r -d '' TARGET; do
        otool -L "$TARGET" 2>/dev/null | tail -n +2 | awk '{print $1}'
    done | grep -E '^(/usr/local|/opt/homebrew)/' || true
)"
if [ -n "$UNBUNDLED" ]; then
    echo "ERROR: Unbundled libraries remain:" >&2
    echo "$UNBUNDLED" >&2
    exit 1
fi

UNRESOLVED_RPATH="$(
    find "$CONTENTS/MacOS" "$CONTENTS/Frameworks" -type f -perm -111 -print0 |
    while IFS= read -r -d '' TARGET; do
        TARGET_BASENAME="$(basename "$TARGET")"
        while IFS= read -r DEP; do
            [[ "$DEP" == @rpath/* ]] || continue
            DEP_BASENAME="$(basename "$DEP")"
            # dylib自身のLC_ID_DYLIBと、OSが供給するSwiftランタイムは除外する。
            [ "$DEP_BASENAME" = "$TARGET_BASENAME" ] && continue
            [ -f "$CONTENTS/Frameworks/$DEP_BASENAME" ] && continue
            [ -f "/usr/lib/swift/$DEP_BASENAME" ] && continue
            printf '%s -> %s\n' "$TARGET_BASENAME" "$DEP"
        done < <(otool -L "$TARGET" 2>/dev/null | tail -n +2 | awk '{print $1}')
    done
)"
if [ -n "$UNRESOLVED_RPATH" ]; then
    echo "ERROR: Unresolved @rpath libraries remain:" >&2
    echo "$UNRESOLVED_RPATH" >&2
    exit 1
fi

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
収録アーキテクチャ: ${BUILD_ARCH}（Universalバイナリではありません）
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
