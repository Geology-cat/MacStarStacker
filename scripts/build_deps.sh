#!/bin/bash
# build_deps.sh — OpenCV / LibRaw を Universal（x86_64 + arm64）の静的ライブラリとしてソースからビルドする。
#
# 使い方: scripts/build_deps.sh [最低対応macOS]   （省略時は Package.swift と同じ値）
# 出力先: MacStarStacker.swiftpm/Vendor/macos<最低対応macOS>/{include,lib}
#
# Homebrew の dylib はビルドしたMacのOSが最低対応OSになり、アーキテクチャも1種類しか含まないため、
# 配布用にはここでビルドした静的ライブラリを使う。
set -euo pipefail

OPENCV_VERSION="4.13.0"
OPENCV_SHA256="1d40ca017ea51c533cf9fd5cbde5b5fe7ae248291ddf2af99d4c17cf8e13017d"
LIBRAW_VERSION="0.22.2"
LIBRAW_SHA256="627928088300ecde6ca91ffd202e189203f04ad61ad12f0fe9dc57b9a7a0fb3c"

DEPLOYMENT_TARGET="${1:-14.0}"
ARCHS=(x86_64 arm64)

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
PACKAGE_DIR="$ROOT_DIR/MacStarStacker.swiftpm"
VENDOR_DIR="$PACKAGE_DIR/Vendor/macos$DEPLOYMENT_TARGET"
WORK_DIR="${DEPS_WORK_DIR:-$PACKAGE_DIR/.build/deps}"
STAMP="opencv=$OPENCV_VERSION libraw=$LIBRAW_VERSION target=$DEPLOYMENT_TARGET script=$(shasum -a 256 "$0" | cut -c1-16)"
JOBS="$(sysctl -n hw.ncpu)"

if [ -f "$VENDOR_DIR/.stamp" ] && [ "$(cat "$VENDOR_DIR/.stamp")" = "$STAMP" ]; then
    echo "依存ライブラリはビルド済みです: $VENDOR_DIR"
    exit 0
fi

for TOOL in cmake ninja curl lipo; do
    command -v "$TOOL" >/dev/null || { echo "ERROR: $TOOL が見つかりません（brew install cmake ninja）" >&2; exit 1; }
done

# arm64 は macOS 11 以降にしか存在しないため、それより低い指定は 11.0 に引き上げる。
min_version_for() {
    local arch="$1"
    if [ "$arch" = "arm64" ] && [ "$(printf '%s\n' "$DEPLOYMENT_TARGET" 11.0 | sort -V | head -1)" = "$DEPLOYMENT_TARGET" ] \
        && [ "$DEPLOYMENT_TARGET" != "11.0" ]; then
        echo "11.0"
    else
        echo "$DEPLOYMENT_TARGET"
    fi
}

download() {
    local url="$1" file="$2" sha="$3"
    if [ ! -f "$file" ]; then
        echo "=== ダウンロード: $url ==="
        curl -fL --retry 3 -o "$file.part" "$url"
        mv "$file.part" "$file"
    fi
    local actual
    actual="$(shasum -a 256 "$file" | awk '{print $1}')"
    if [ "$actual" != "$sha" ]; then
        echo "ERROR: $file のSHA-256が一致しません（期待: $sha / 実際: $actual）" >&2
        rm -f "$file"
        exit 1
    fi
}

mkdir -p "$WORK_DIR"
cd "$WORK_DIR"
download "https://github.com/opencv/opencv/archive/refs/tags/$OPENCV_VERSION.tar.gz" "opencv-$OPENCV_VERSION.tar.gz" "$OPENCV_SHA256"
download "https://github.com/LibRaw/LibRaw/archive/refs/tags/$LIBRAW_VERSION.tar.gz" "LibRaw-$LIBRAW_VERSION.tar.gz" "$LIBRAW_SHA256"
[ -d "opencv-$OPENCV_VERSION" ] || tar xzf "opencv-$OPENCV_VERSION.tar.gz"
[ -d "LibRaw-$LIBRAW_VERSION" ] || tar xzf "LibRaw-$LIBRAW_VERSION.tar.gz"

rm -rf "$VENDOR_DIR"
mkdir -p "$VENDOR_DIR/include" "$VENDOR_DIR/lib"

# ─────────────────────────────────────────────
#  OpenCV
#  CPUの命令セット（SSE/AVX・NEON）をターゲットごとに判定するため、1回のcmakeで両アーキテクチャを
#  ビルドすることはできない。アーキテクチャごとにビルドして lipo で結合する。
#  libjpeg-turbo のSIMDはnasmの有無でビルド内容が変わるため無効にする（JPEGの読み込みは補助的な用途のみ）。
#  Carotene（ARM専用のHAL）は arm64 にだけ追加のライブラリを生むため無効にする（NEON最適化自体は有効のまま）。
# ─────────────────────────────────────────────
for ARCH in "${ARCHS[@]}"; do
    MIN_VERSION="$(min_version_for "$ARCH")"
    BUILD="$WORK_DIR/opencv-build-$ARCH"
    INSTALL="$WORK_DIR/opencv-install-$ARCH"
    echo "=== OpenCV $OPENCV_VERSION をビルド: $ARCH（macOS $MIN_VERSION 以降） ==="
    rm -rf "$BUILD" "$INSTALL"
    CROSS_ARGS=()
    if [ "$ARCH" != "$(uname -m)" ]; then
        CROSS_ARGS=(-DCMAKE_SYSTEM_NAME=Darwin -DCMAKE_SYSTEM_PROCESSOR="$ARCH")
    fi
    cmake -S "$WORK_DIR/opencv-$OPENCV_VERSION" -B "$BUILD" -G Ninja -Wno-dev \
        -DCMAKE_BUILD_TYPE=Release \
        -DCMAKE_INSTALL_PREFIX="$INSTALL" \
        -DCMAKE_OSX_ARCHITECTURES="$ARCH" \
        -DCMAKE_OSX_DEPLOYMENT_TARGET="$MIN_VERSION" \
        ${CROSS_ARGS[@]+"${CROSS_ARGS[@]}"} \
        -DBUILD_SHARED_LIBS=OFF \
        -DBUILD_LIST=core,imgproc,imgcodecs,features2d,calib3d,flann,photo \
        -DBUILD_TESTS=OFF -DBUILD_PERF_TESTS=OFF -DBUILD_EXAMPLES=OFF -DBUILD_DOCS=OFF \
        -DBUILD_opencv_apps=OFF -DBUILD_JAVA=OFF -DBUILD_OBJC=OFF -DBUILD_opencv_python3=OFF \
        -DOPENCV_GENERATE_PKGCONFIG=OFF \
        -DWITH_IPP=OFF -DWITH_KLEIDICV=OFF -DWITH_ADE=OFF -DWITH_ITT=OFF \
        -DWITH_TBB=OFF -DWITH_OPENMP=OFF -DWITH_OPENCL=OFF -DWITH_LAPACK=OFF -DWITH_EIGEN=OFF \
        -DWITH_PROTOBUF=OFF -DWITH_FFMPEG=OFF -DWITH_AVFOUNDATION=OFF -DWITH_GSTREAMER=OFF \
        -DWITH_1394=OFF -DWITH_OPENEXR=OFF -DWITH_OPENJPEG=OFF -DWITH_JASPER=OFF -DWITH_WEBP=OFF \
        -DWITH_AVIF=OFF -DWITH_JPEGXL=OFF -DWITH_QUIRC=OFF -DWITH_VTK=OFF -DWITH_GTK=OFF -DWITH_QT=OFF \
        -DWITH_JPEG=ON -DBUILD_JPEG=ON -DWITH_PNG=ON -DBUILD_PNG=ON -DWITH_TIFF=ON -DBUILD_TIFF=ON \
        -DENABLE_LIBJPEG_TURBO_SIMD=OFF \
        -DWITH_CAROTENE=OFF \
        -DBUILD_ZLIB=OFF \
        > "$WORK_DIR/opencv-cmake-$ARCH.log" 2>&1
    grep -E "^\s+(Baseline|Dispatched code generation):" "$WORK_DIR/opencv-cmake-$ARCH.log" || true
    cmake --build "$BUILD" --parallel "$JOBS" > "$WORK_DIR/opencv-build-$ARCH.log"
    cmake --install "$BUILD" > /dev/null
    rm -rf "$BUILD"
done

cp -R "$WORK_DIR/opencv-install-${ARCHS[0]}/include/opencv4" "$VENDOR_DIR/include/"
# ヘッダーはアーキテクチャに依存しないはずだが、念のため差分がないことを確認する
for ARCH in "${ARCHS[@]:1}"; do
    if ! diff -rq "$WORK_DIR/opencv-install-${ARCHS[0]}/include" "$WORK_DIR/opencv-install-$ARCH/include" > /dev/null; then
        echo "ERROR: OpenCVのヘッダーがアーキテクチャ間で異なります" >&2
        exit 1
    fi
done
# 両アーキテクチャで同じ構成のライブラリができていることを確認する（片方にしかないとリンクできない）
for ARCH in "${ARCHS[@]:1}"; do
    if ! diff <(cd "$WORK_DIR/opencv-install-${ARCHS[0]}" && find lib -name '*.a' | sort) \
              <(cd "$WORK_DIR/opencv-install-$ARCH" && find lib -name '*.a' | sort); then
        echo "ERROR: OpenCVのライブラリ構成がアーキテクチャ間で異なります" >&2
        exit 1
    fi
done
while IFS= read -r LIB; do
    INPUTS=()
    for ARCH in "${ARCHS[@]}"; do
        INPUTS+=("$WORK_DIR/opencv-install-$ARCH/$LIB")
    done
    lipo -create "${INPUTS[@]}" -output "$VENDOR_DIR/lib/$(basename "$LIB")"
done < <(cd "$WORK_DIR/opencv-install-${ARCHS[0]}" && find lib -name '*.a' | sort)
for ARCH in "${ARCHS[@]}"; do
    rm -rf "$WORK_DIR/opencv-install-$ARCH"
done

# ─────────────────────────────────────────────
#  LibRaw
#  色変換はLibRaw内蔵の行列で行うため LCMS は使わない。システムの zlib でDeflate圧縮DNGに対応する。
#  （libjpeg を入れないため、非可逆圧縮DNGは読めない）
# ─────────────────────────────────────────────
echo "=== LibRaw $LIBRAW_VERSION をビルド ==="
LIBRAW_SRC="$WORK_DIR/LibRaw-$LIBRAW_VERSION"
for ARCH in "${ARCHS[@]}"; do
    MIN_VERSION="$(min_version_for "$ARCH")"
    OBJ_DIR="$WORK_DIR/libraw-obj-$ARCH"
    rm -rf "$OBJ_DIR"
    mkdir -p "$OBJ_DIR"
    # Makefile.dist のスレッド対応版（libraw_r.a = *.mt.o）のルールからソース一覧を取り出す
    while IFS= read -r SOURCE; do
        OBJECT="$OBJ_DIR/$(echo "$SOURCE" | tr '/' '_' | sed 's/\.cpp$/.o/')"
        echo "clang++ -c -O3 -w -arch $ARCH -mmacosx-version-min=$MIN_VERSION -I. -DUSE_ZLIB -o '$OBJECT' '$SOURCE'"
    done < <(awk '/^object\/[^ ]*\.mt\.o: /{print $2}' "$LIBRAW_SRC/Makefile.dist" | sort -u) > "$OBJ_DIR/commands.txt"
    [ -s "$OBJ_DIR/commands.txt" ] || { echo "ERROR: LibRawのソース一覧を取得できません" >&2; exit 1; }
    # パスが長いと xargs -I の長さ制限を超えるため、1行を1つの sh -c に渡す
    (cd "$LIBRAW_SRC" && tr '\n' '\0' < "$OBJ_DIR/commands.txt" | xargs -0 -n 1 -P "$JOBS" sh -c)
    libtool -static -no_warning_for_no_symbols -o "$OBJ_DIR/libraw_r.a" "$OBJ_DIR"/*.o
done
LIBRAW_INPUTS=()
for ARCH in "${ARCHS[@]}"; do
    LIBRAW_INPUTS+=("$WORK_DIR/libraw-obj-$ARCH/libraw_r.a")
done
lipo -create "${LIBRAW_INPUTS[@]}" -output "$VENDOR_DIR/lib/libraw_r.a"
mkdir -p "$VENDOR_DIR/include/libraw"
cp "$LIBRAW_SRC"/libraw/*.h "$VENDOR_DIR/include/libraw/"
for ARCH in "${ARCHS[@]}"; do
    rm -rf "$WORK_DIR/libraw-obj-$ARCH"
done

echo "$STAMP" > "$VENDOR_DIR/.stamp"
echo ""
echo "=== 完了: $VENDOR_DIR ==="
ls "$VENDOR_DIR/lib"
