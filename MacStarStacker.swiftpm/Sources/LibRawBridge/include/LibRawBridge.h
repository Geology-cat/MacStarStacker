#ifndef LIBRAW_BRIDGE_H
#define LIBRAW_BRIDGE_H

#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

/// LibRawから取り出したRAWファイルのセンサー情報。
/// 座標はすべて「有効画素領域（visible area）」の左上を原点とする。
typedef struct {
    /// 有効画素領域の幅・高さ
    int32_t width;
    int32_t height;
    /// 2x2ベイヤー配列を持つか（X-Trans・デモザイク済みDNG・モノクロは0）
    int32_t isBayer;
    /// 有効領域左上から (0,0) (0,1) (1,0) (1,1) の位置の色。0=R, 1=G, 2=B
    uint8_t cfaPattern[4];
    /// LibRawのflip値（0, 3, 5, 6）
    int32_t flip;
    /// 上記4位置の黒レベル（生の値）
    double blackLevel[4];
    /// 白レベル（飽和値、生の値）
    double whiteLevel;
    /// XYZ → カメラRGB の行列（DNGのColorMatrix）と光源
    double colorMatrix1[9];
    int32_t illuminant1;
    int32_t hasColorMatrix2;
    double colorMatrix2[9];
    int32_t illuminant2;
    /// 撮影時ホワイトバランス係数（R, G, B。Gを1に正規化）
    double cameraMultipliers[3];
    char make[64];
    char model[128];
} LRRawInfo;

/// メタデータとセンサー情報だけを読む（画素は展開しないため高速）。成功時0。
int32_t LRReadInfo(const char *path, LRRawInfo *info, char *errorMessage, int32_t errorLength);

/// ベイヤー配列の生データ（黒レベルを含む生の値）を有効画素領域だけ返す（width * height 要素）。
/// *outPixels は LRFree で解放する。成功時0。ベイヤー配列でない場合は失敗を返す。
int32_t LRReadBayer(const char *path, LRRawInfo *info, uint16_t **outPixels,
                    char *errorMessage, int32_t errorLength);

/// カメラ色空間のままデモザイクした16bitリニアRGB（ホワイトバランス・色変換・トーンカーブなし）を返す。
/// 黒レベルを引き、白レベルを65535に合わせる。回転はしない。
/// replacementBayer が非NULLなら、デモザイク前に有効画素領域の生データをこの値（黒レベル込みの生の値、
/// width * height 要素）で置き換える（キャリブレーション済みデータのデモザイク用）。
/// *outRGB は LRFree で解放する。成功時0。
int32_t LRDemosaicCameraRGB(const char *path, const uint16_t *replacementBayer, LRRawInfo *info,
                            uint16_t **outRGB, int32_t *outWidth, int32_t *outHeight,
                            char *errorMessage, int32_t errorLength);

/// 撮影時ホワイトバランス・sRGB色空間・sRGBガンマで現像した16bit RGB（回転なし）を返す。
/// brightness は明るさの倍率（1.0で等倍）。*outRGB は LRFree で解放する。成功時0。
int32_t LRRenderSRGB(const char *path, double brightness, uint16_t **outRGB, int32_t *outWidth, int32_t *outHeight,
                     char *errorMessage, int32_t errorLength);

void LRFree(void *pointer);

#ifdef __cplusplus
}
#endif

#endif
