#include "LibRawBridge.h"

#include <libraw.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

static void SetError(char *buffer, int32_t length, const char *message, int code) {
    if (!buffer || length <= 0) return;
    if (code != 0) {
        snprintf(buffer, (size_t)length, "%s (%s)", message, libraw_strerror(code));
    } else {
        snprintf(buffer, (size_t)length, "%s", message);
    }
}

static int IsNonZeroMatrix(const float matrix[4][3]) {
    for (int row = 0; row < 3; row++) {
        for (int col = 0; col < 3; col++) {
            if (matrix[row][col] != 0.0f) return 1;
        }
    }
    return 0;
}

/// 有効画素領域の (row, col) にある画素の黒レベル（生の値）。
static double BlackAt(libraw_data_t *lr, int row, int col) {
    int color = libraw_COLOR(lr, row, col);
    double black = (double)lr->color.black;
    if (color >= 0 && color < 4) black += (double)lr->color.cblack[color];
    unsigned rows = lr->color.cblack[4];
    unsigned cols = lr->color.cblack[5];
    if (rows > 0 && cols > 0 && 6 + rows * cols <= LIBRAW_CBLACK_SIZE) {
        black += (double)lr->color.cblack[6 + (row % rows) * cols + (col % cols)];
    }
    return black;
}

static void FillInfo(libraw_data_t *lr, LRRawInfo *info, int unpacked) {
    memset(info, 0, sizeof(*info));
    info->width = lr->sizes.width;
    info->height = lr->sizes.height;
    info->flip = lr->sizes.flip;

    // filters==0: デモザイク済み（リニアDNG等）、filters==9: X-Trans(6x6)。どちらも2x2ベイヤーではない。
    unsigned filters = lr->idata.filters;
    info->isBayer = (filters != 0 && filters != 9 && lr->idata.colors == 3
                     && (!unpacked || lr->rawdata.raw_image != NULL)) ? 1 : 0;

    for (int row = 0; row < 2; row++) {
        for (int col = 0; col < 2; col++) {
            int color = libraw_COLOR(lr, row, col);
            // LibRawの4色目（G2）は緑として扱う
            info->cfaPattern[row * 2 + col] = (uint8_t)(color == 3 ? 1 : (color < 0 ? 1 : color));
            info->blackLevel[row * 2 + col] = BlackAt(lr, row, col);
        }
    }

    // 白レベル: 規格上の線形上限（linear_max）があれば優先し、なければ最大値
    double white = (double)lr->color.maximum;
    double linearMax = 0.0;
    for (int c = 0; c < 4; c++) {
        double value = (double)lr->color.linear_max[c];
        if (value > 0.0 && (linearMax == 0.0 || value < linearMax)) linearMax = value;
    }
    if (linearMax > info->blackLevel[0] && linearMax < white) white = linearMax;
    info->whiteLevel = white;

    // XYZ → カメラ の行列。一般のRAWはcam_xyz（D65基準）、DNGはファイル内の行列を使う。
    if (IsNonZeroMatrix(lr->color.cam_xyz)) {
        for (int i = 0; i < 9; i++) info->colorMatrix1[i] = lr->color.cam_xyz[i / 3][i % 3];
        info->illuminant1 = 21; // D65
    } else if (IsNonZeroMatrix(lr->color.dng_color[0].colormatrix)) {
        for (int i = 0; i < 9; i++) info->colorMatrix1[i] = lr->color.dng_color[0].colormatrix[i / 3][i % 3];
        info->illuminant1 = lr->color.dng_color[0].illuminant;
        if (IsNonZeroMatrix(lr->color.dng_color[1].colormatrix)) {
            info->hasColorMatrix2 = 1;
            for (int i = 0; i < 9; i++) info->colorMatrix2[i] = lr->color.dng_color[1].colormatrix[i / 3][i % 3];
            info->illuminant2 = lr->color.dng_color[1].illuminant;
        }
    }

    float r = lr->color.cam_mul[0], g = lr->color.cam_mul[1], b = lr->color.cam_mul[2];
    if (!(r > 0.0f && g > 0.0f && b > 0.0f)) {
        r = lr->color.pre_mul[0]; g = lr->color.pre_mul[1]; b = lr->color.pre_mul[2];
    }
    if (r > 0.0f && g > 0.0f && b > 0.0f) {
        info->cameraMultipliers[0] = r / g;
        info->cameraMultipliers[1] = 1.0;
        info->cameraMultipliers[2] = b / g;
    } else {
        info->cameraMultipliers[0] = info->cameraMultipliers[1] = info->cameraMultipliers[2] = 1.0;
    }

    snprintf(info->make, sizeof(info->make), "%s", lr->idata.make);
    snprintf(info->model, sizeof(info->model), "%s", lr->idata.model);
}

static libraw_data_t *OpenFile(const char *path, int unpack, char *errorMessage, int32_t errorLength) {
    libraw_data_t *lr = libraw_init(0);
    if (!lr) {
        SetError(errorMessage, errorLength, "LibRawを初期化できませんでした", 0);
        return NULL;
    }
    // 画素の最大値から白レベルを推定し直す処理を無効化し、フレーム間で白レベルを一定に保つ
    libraw_set_adjust_maximum_thr(lr, 0.0f);
    int code = libraw_open_file(lr, path);
    if (code != LIBRAW_SUCCESS) {
        SetError(errorMessage, errorLength, "RAWファイルを開けませんでした", code);
        libraw_close(lr);
        return NULL;
    }
    if (!unpack) return lr;
    code = libraw_unpack(lr);
    if (code != LIBRAW_SUCCESS) {
        SetError(errorMessage, errorLength, "RAWデータを展開できませんでした", code);
        libraw_close(lr);
        return NULL;
    }
    return lr;
}

int32_t LRReadInfo(const char *path, LRRawInfo *info, char *errorMessage, int32_t errorLength) {
    // 画素は展開しない（高速）。黒レベル等は展開後に確定する機種があるため、合成には LRReadBayer の値を使う。
    libraw_data_t *lr = OpenFile(path, 0, errorMessage, errorLength);
    if (!lr) return -1;
    FillInfo(lr, info, 0);
    libraw_close(lr);
    return 0;
}

int32_t LRReadBayer(const char *path, LRRawInfo *info, uint16_t **outPixels,
                    char *errorMessage, int32_t errorLength) {
    *outPixels = NULL;
    libraw_data_t *lr = OpenFile(path, 1, errorMessage, errorLength);
    if (!lr) return -1;
    FillInfo(lr, info, 1);
    if (!info->isBayer) {
        SetError(errorMessage, errorLength, "ベイヤー配列のRAWではありません", 0);
        libraw_close(lr);
        return -2;
    }
    int width = lr->sizes.width, height = lr->sizes.height;
    uint16_t *buffer = (uint16_t *)malloc((size_t)width * (size_t)height * sizeof(uint16_t));
    if (!buffer) {
        SetError(errorMessage, errorLength, "メモリを確保できませんでした", 0);
        libraw_close(lr);
        return -3;
    }
    int rawWidth = lr->sizes.raw_width;
    int top = lr->sizes.top_margin, left = lr->sizes.left_margin;
    for (int row = 0; row < height; row++) {
        const uint16_t *source = lr->rawdata.raw_image + (size_t)(row + top) * (size_t)rawWidth + (size_t)left;
        memcpy(buffer + (size_t)row * (size_t)width, source, (size_t)width * sizeof(uint16_t));
    }
    *outPixels = buffer;
    libraw_close(lr);
    return 0;
}

int32_t LRDemosaicCameraRGB(const char *path, const uint16_t *replacementBayer, LRRawInfo *info,
                            uint16_t **outRGB, int32_t *outWidth, int32_t *outHeight,
                            char *errorMessage, int32_t errorLength) {
    *outRGB = NULL;
    libraw_data_t *lr = OpenFile(path, 1, errorMessage, errorLength);
    if (!lr) return -1;
    FillInfo(lr, info, 1);

    if (replacementBayer) {
        if (!info->isBayer) {
            SetError(errorMessage, errorLength, "ベイヤー配列でないRAWは置き換えられません", 0);
            libraw_close(lr);
            return -2;
        }
        int width = lr->sizes.width, height = lr->sizes.height, rawWidth = lr->sizes.raw_width;
        int top = lr->sizes.top_margin, left = lr->sizes.left_margin;
        for (int row = 0; row < height; row++) {
            uint16_t *destination = lr->rawdata.raw_image + (size_t)(row + top) * (size_t)rawWidth + (size_t)left;
            memcpy(destination, replacementBayer + (size_t)row * (size_t)width, (size_t)width * sizeof(uint16_t));
        }
    }

    // カメラ色空間のまま（色変換なし）、ホワイトバランスなし、ガンマ・自動明るさなし、回転なし
    libraw_set_output_color(lr, 0);
    libraw_set_output_bps(lr, 16);
    libraw_set_gamma(lr, 0, 1.0f);
    libraw_set_gamma(lr, 1, 1.0f);
    libraw_set_no_auto_bright(lr, 1);
    libraw_set_highlight(lr, 0);
    for (int c = 0; c < 4; c++) libraw_set_user_mul(lr, c, 1.0f);
    lr->params.use_camera_wb = 0;
    lr->params.use_auto_wb = 0;
    lr->params.user_flip = 0;
    lr->params.user_sat = (int)info->whiteLevel;

    int code = libraw_dcraw_process(lr);
    if (code != LIBRAW_SUCCESS) {
        SetError(errorMessage, errorLength, "RAWを現像できませんでした", code);
        libraw_close(lr);
        return -4;
    }
    int errorCode = 0;
    libraw_processed_image_t *image = libraw_dcraw_make_mem_image(lr, &errorCode);
    if (!image || image->colors != 3 || image->bits != 16) {
        SetError(errorMessage, errorLength, "現像結果を取得できませんでした", errorCode);
        if (image) libraw_dcraw_clear_mem(image);
        libraw_close(lr);
        return -5;
    }
    size_t count = (size_t)image->width * (size_t)image->height * 3;
    uint16_t *buffer = (uint16_t *)malloc(count * sizeof(uint16_t));
    if (!buffer) {
        SetError(errorMessage, errorLength, "メモリを確保できませんでした", 0);
        libraw_dcraw_clear_mem(image);
        libraw_close(lr);
        return -6;
    }
    memcpy(buffer, image->data, count * sizeof(uint16_t));
    *outRGB = buffer;
    *outWidth = image->width;
    *outHeight = image->height;
    libraw_dcraw_clear_mem(image);
    libraw_close(lr);
    return 0;
}

int32_t LRRenderSRGB(const char *path, double brightness, uint16_t **outRGB, int32_t *outWidth, int32_t *outHeight,
                     char *errorMessage, int32_t errorLength) {
    *outRGB = NULL;
    libraw_data_t *lr = OpenFile(path, 1, errorMessage, errorLength);
    if (!lr) return -1;
    // 撮影時ホワイトバランス・sRGB・sRGBガンマで素直に現像する（自動明るさ補正なし、回転なし）
    libraw_set_output_color(lr, 1);
    libraw_set_output_bps(lr, 16);
    libraw_set_gamma(lr, 0, 1.0f / 2.4f);
    libraw_set_gamma(lr, 1, 12.92f);
    libraw_set_no_auto_bright(lr, 1);
    libraw_set_bright(lr, (float)(brightness > 0 ? brightness : 1.0));
    lr->params.use_camera_wb = 1;
    lr->params.user_flip = 0;
    int code = libraw_dcraw_process(lr);
    if (code != LIBRAW_SUCCESS) {
        SetError(errorMessage, errorLength, "RAWを現像できませんでした", code);
        libraw_close(lr);
        return -2;
    }
    int errorCode = 0;
    libraw_processed_image_t *image = libraw_dcraw_make_mem_image(lr, &errorCode);
    if (!image || image->colors != 3 || image->bits != 16) {
        SetError(errorMessage, errorLength, "現像結果を取得できませんでした", errorCode);
        if (image) libraw_dcraw_clear_mem(image);
        libraw_close(lr);
        return -3;
    }
    size_t count = (size_t)image->width * (size_t)image->height * 3;
    uint16_t *buffer = (uint16_t *)malloc(count * sizeof(uint16_t));
    if (buffer) memcpy(buffer, image->data, count * sizeof(uint16_t));
    *outRGB = buffer;
    *outWidth = image->width;
    *outHeight = image->height;
    libraw_dcraw_clear_mem(image);
    libraw_close(lr);
    return buffer ? 0 : -4;
}

void LRFree(void *pointer) {
    free(pointer);
}
