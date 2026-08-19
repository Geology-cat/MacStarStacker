#import <opencv2/core.hpp>
#import <opencv2/imgproc.hpp>
#import <opencv2/imgcodecs.hpp>
#import <opencv2/photo.hpp> // cv::inpaint
#import <vector>
#import <cmath>
#import <algorithm>

#import "TrailCleaner.h"

@implementation TrailDetectionResult
@end

@implementation TrailCleaner

// ── Helper: cv::Mat → NSImage ──────────────────────────────────────────
static NSImage *NSImageFromMat(const cv::Mat &cvMat) {
    if (cvMat.empty()) return nil;

    cv::Mat rgbMat;
    if (cvMat.channels() == 1) {
        cv::cvtColor(cvMat, rgbMat, cv::COLOR_GRAY2RGB);
    } else if (cvMat.channels() == 3) {
        cv::cvtColor(cvMat, rgbMat, cv::COLOR_BGR2RGB);
    } else if (cvMat.channels() == 4) {
        cv::cvtColor(cvMat, rgbMat, cv::COLOR_BGRA2RGBA);
    } else {
        return nil;
    }

    NSData *data = [NSData dataWithBytes:rgbMat.data length:rgbMat.elemSize() * rgbMat.total()];
    CGColorSpaceRef colorSpace = CGColorSpaceCreateDeviceRGB();
    CGDataProviderRef provider = CGDataProviderCreateWithCFData((__bridge CFDataRef)data);

    CGBitmapInfo bitmapInfo = (rgbMat.channels() == 4) ? (kCGImageAlphaPremultipliedLast | kCGBitmapByteOrderDefault) : (kCGImageAlphaNone | kCGBitmapByteOrderDefault);

    CGImageRef imageRef = CGImageCreate(
        rgbMat.cols, rgbMat.rows, 8, 8 * rgbMat.channels(), rgbMat.step[0],
        colorSpace, bitmapInfo, provider, NULL, false, kCGRenderingIntentDefault
    );

    NSImage *image = [[NSImage alloc] initWithCGImage:imageRef size:NSMakeSize(rgbMat.cols, rgbMat.rows)];

    CGImageRelease(imageRef);
    CGDataProviderRelease(provider);
    CGColorSpaceRelease(colorSpace);

    return image;
}

// ── Helper: NSImage → cv::Mat ──────────────────────────────────────────
static cv::Mat MatFromNSImage(NSImage *image) {
    if (!image) return cv::Mat();
    CGImageRef cgImage = [image CGImageForProposedRect:nil context:nil hints:nil];
    if (!cgImage) return cv::Mat();

    int width = (int)CGImageGetWidth(cgImage);
    int height = (int)CGImageGetHeight(cgImage);

    cv::Mat mat(height, width, CV_8UC4);
    CGColorSpaceRef colorSpace = CGColorSpaceCreateDeviceRGB();
    CGContextRef context = CGBitmapContextCreate(
        mat.data, width, height, 8, mat.step[0],
        colorSpace, kCGImageAlphaPremultipliedLast | kCGBitmapByteOrder32Big
    );
    CGContextDrawImage(context, CGRectMake(0, 0, width, height), cgImage);
    CGContextRelease(context);
    CGColorSpaceRelease(colorSpace);

    cv::Mat grayMat;
    cv::cvtColor(mat, grayMat, cv::COLOR_RGBA2GRAY);
    return grayMat;
}

// ── Helper: 堅牢な画像読み込み (macOS ImageIO/NSImage 優先) ──
static cv::Mat LoadColorMatFromURL(NSURL *url) {
    if (!url) return cv::Mat();

    NSImage *nsImg = [[NSImage alloc] initWithContentsOfURL:url];
    if (nsImg) {
        CGImageRef cgImage = [nsImg CGImageForProposedRect:nil context:nil hints:nil];
        if (cgImage) {
            int width = (int)CGImageGetWidth(cgImage);
            int height = (int)CGImageGetHeight(cgImage);
            if (width > 0 && height > 0) {
                cv::Mat rgbaMat(height, width, CV_8UC4);
                CGColorSpaceRef colorSpace = CGColorSpaceCreateDeviceRGB();
                CGContextRef context = CGBitmapContextCreate(
                    rgbaMat.data, width, height, 8, rgbaMat.step[0],
                    colorSpace, kCGImageAlphaPremultipliedLast | kCGBitmapByteOrder32Big
                );
                CGContextDrawImage(context, CGRectMake(0, 0, width, height), cgImage);
                CGContextRelease(context);
                CGColorSpaceRelease(colorSpace);

                cv::Mat bgrMat;
                cv::cvtColor(rgbaMat, bgrMat, cv::COLOR_RGBA2BGR);
                return bgrMat;
            }
        }
    }

    return cv::imread(url.path.UTF8String, cv::IMREAD_COLOR);
}

// MARK: - 光跡検出

+ (NSArray<TrailDetectionResult *> *)detectTrailsInImageURLs:(NSArray<NSURL *> *)imageURLs
                                            progressCallback:(void (^ _Nullable)(double progress, NSString *status))progressCallback {
    NSMutableArray<TrailDetectionResult *> *results = [NSMutableArray array];
    NSInteger total = imageURLs.count;
    if (total < 2) return results;

    // 高速解析のため、各フレームのダウンサンプル画像をメモリキャッシュ
    std::vector<cv::Mat> grayFrames(total);
    std::vector<cv::Mat> colorFrames(total);
    const int targetWidth = 1400; // 解析用解像度

    for (NSInteger i = 0; i < total; i++) {
        if (progressCallback) {
            progressCallback((double)i / (double)total * 0.35, [NSString stringWithFormat:@"フレームを読み込み・解析中 (%ld/%ld)...", (long)(i + 1), (long)total]);
        }

        cv::Mat fullColor = LoadColorMatFromURL(imageURLs[i]);
        if (fullColor.empty()) continue;

        double scale = (double)targetWidth / (double)fullColor.cols;
        if (scale > 1.0) scale = 1.0;

        cv::Mat scaledColor, scaledGray;
        if (scale < 1.0) {
            cv::resize(fullColor, scaledColor, cv::Size(), scale, scale, cv::INTER_AREA);
        } else {
            scaledColor = fullColor;
        }

        cv::cvtColor(scaledColor, scaledGray, cv::COLOR_BGR2GRAY);
        grayFrames[i] = scaledGray;
        colorFrames[i] = scaledColor;
    }

    // 各フレームの時間的差分解析
    for (NSInteger i = 0; i < total; i++) {
        if (progressCallback) {
            progressCallback(0.35 + (double)i / (double)total * 0.65, [NSString stringWithFormat:@"光跡パターンを検出中 (%ld/%ld)...", (long)(i + 1), (long)total]);
        }

        if (grayFrames[i].empty()) continue;

        // 前後フレームとの比較背景を作成
        cv::Mat bgRef;
        if (i > 0 && i < total - 1 && !grayFrames[i - 1].empty() && !grayFrames[i + 1].empty()) {
            cv::min(grayFrames[i - 1], grayFrames[i + 1], bgRef);
        } else if (i > 1 && !grayFrames[i - 1].empty() && !grayFrames[i - 2].empty()) {
            cv::min(grayFrames[i - 1], grayFrames[i - 2], bgRef);
        } else if (i < total - 2 && !grayFrames[i + 1].empty() && !grayFrames[i + 2].empty()) {
            cv::min(grayFrames[i + 1], grayFrames[i + 2], bgRef);
        } else {
            continue;
        }

        // 正の差分: 突発的に明るくなったピクセル
        cv::Mat diff;
        cv::subtract(grayFrames[i], bgRef, diff);

        // 閾値処理（背景ノイズ・星の微小移動を除去）
        cv::Mat thresh;
        cv::threshold(diff, thresh, 25, 255, cv::THRESH_BINARY);

        // モルフォロジー演算（孤立点星像ノイズ除去、線分接続）
        cv::Mat kernel = cv::getStructuringElement(cv::MORPH_ELLIPSE, cv::Size(3, 3));
        cv::morphologyEx(thresh, thresh, cv::MORPH_OPEN, kernel);

        // 直線検出（Hough Lines）
        std::vector<cv::Vec4i> lines;
        cv::HoughLinesP(thresh, lines, 1, CV_PI / 180, 40, 30, 15);

        // 輪郭解析
        std::vector<std::vector<cv::Point>> contours;
        cv::findContours(thresh, contours, cv::RETR_EXTERNAL, cv::CHAIN_APPROX_SIMPLE);

        cv::Mat trailMask = cv::Mat::zeros(grayFrames[i].size(), CV_8UC1);
        bool foundTrail = false;
        NSString *detectedType = @"人工衛星 (直線)";
        bool isLikelyMeteor = false;
        double maxScore = 0.0;

        // 1. 直線検出に基づく光跡
        for (size_t l = 0; l < lines.size(); l++) {
            cv::Vec4i ln = lines[l];
            double len = std::hypot(ln[2] - ln[0], ln[3] - ln[1]);
            if (len > 35.0) {
                cv::line(trailMask, cv::Point(ln[0], ln[1]), cv::Point(ln[2], ln[3]), cv::Scalar(255), 7);
                foundTrail = true;
                maxScore = std::max(maxScore, std::min(1.0, len / 200.0));
            }
        }

        // 2. 輪郭解析（細長いストリーク、または点滅ストロボ）
        for (size_t c = 0; c < contours.size(); c++) {
            double area = cv::contourArea(contours[c]);
            if (area < 15) continue;

            cv::RotatedRect rRect = cv::minAreaRect(contours[c]);
            float w = rRect.size.width;
            float h = rRect.size.height;
            if (w < h) std::swap(w, h);

            float aspect = (h > 0) ? (w / h) : 0;

            // 細長いストリーク（アスペクト比 > 3.0）
            if (aspect > 3.0 && w > 25.0) {
                cv::drawContours(trailMask, contours, (int)c, cv::Scalar(255), cv::FILLED);
                foundTrail = true;

                // 流星判定（輪郭の両端で急峻な輝度勾配・発光バーストがあるか）
                if (aspect > 4.5 && area > 50) {
                    // 流星は片側が太く急に消える特徴
                    isLikelyMeteor = true;
                    detectedType = @"流星の可能性あり (直線光跡)";
                }
            }
        }

        // 3. 点滅ストロボ（飛行機アンチコリジョンライト）の検出
        // 赤/緑成分の強い突発ピクセル
        if (!colorFrames[i].empty()) {
            cv::Mat bgr[3];
            cv::split(colorFrames[i], bgr);
            cv::Mat redExcess, greenExcess;
            cv::subtract(bgr[2], bgr[0], redExcess); // R - B
            cv::subtract(bgr[1], bgr[0], greenExcess); // G - B
            cv::Mat strobeMask;
            cv::bitwise_or(redExcess > 40, greenExcess > 40, strobeMask);
            cv::bitwise_and(strobeMask, thresh, strobeMask);

            int strobeCount = cv::countNonZero(strobeMask);
            if (strobeCount > 20) {
                cv::dilate(strobeMask, strobeMask, cv::getStructuringElement(cv::MORPH_ELLIPSE, cv::Size(7, 7)));
                cv::bitwise_or(trailMask, strobeMask, trailMask);
                foundTrail = true;
                detectedType = @"飛行機 (点滅ストロボ・航跡灯)";
                isLikelyMeteor = false;
            }
        }

        if (foundTrail) {
            // マスクを少し膨張させて光跡の周辺光のにじみもカバー
            cv::dilate(trailMask, trailMask, cv::getStructuringElement(cv::MORPH_ELLIPSE, cv::Size(7, 7)));

            // ハイライト画像の作成（元画像 + 赤色オーバーレイ）
            cv::Mat highlightedColor = colorFrames[i].clone();
            for (int y = 0; y < highlightedColor.rows; y++) {
                for (int x = 0; x < highlightedColor.cols; x++) {
                    if (trailMask.at<uchar>(y, x) > 0) {
                        cv::Vec3b &px = highlightedColor.at<cv::Vec3b>(y, x);
                        px[0] = (uchar)(px[0] * 0.3);        // B
                        px[1] = (uchar)(px[1] * 0.3);        // G
                        px[2] = (uchar)(std::min(255, px[2] + 180)); // R (赤強調)
                    }
                }
            }

            // 簡易除去後プレビュー画像の作成（前後フレームで置換）
            cv::Mat repairedColor = colorFrames[i].clone();
            cv::Mat cleanRef = (i > 0 && !colorFrames[i - 1].empty()) ? colorFrames[i - 1] : ((i < total - 1 && !colorFrames[i + 1].empty()) ? colorFrames[i + 1] : colorFrames[i]);

            cleanRef.copyTo(repairedColor, trailMask);

            TrailDetectionResult *result = [[TrailDetectionResult alloc] init];
            result.frameIndex = i;
            result.filePath = imageURLs[i].path;
            result.maskImage = NSImageFromMat(trailMask);
            result.highlightedImage = NSImageFromMat(highlightedColor);
            result.repairedImage = NSImageFromMat(repairedColor);
            result.detectedType = detectedType;
            result.confidenceScore = maxScore > 0 ? maxScore : 0.85;
            result.isLikelyMeteor = isLikelyMeteor;
            result.isMarkedForRemoval = !isLikelyMeteor; // 流星の可能性が高い場合は初期状態でチェックを外して保護

            [results addObject:result];
        }
    }

    return results;
}

// MARK: - インペイント修復

+ (nullable NSImage *)inpaintImageAtURL:(NSURL *)targetURL
                              withMask:(NSImage *)maskImage
                         prevFrameURL:(nullable NSURL *)prevURL
                         nextFrameURL:(nullable NSURL *)nextURL {
    cv::Mat targetColor = LoadColorMatFromURL(targetURL);
    if (targetColor.empty()) return nil;

    cv::Mat maskGray = MatFromNSImage(maskImage);
    if (maskGray.empty()) return NSImageFromMat(targetColor);

    // マスクサイズが異なる場合は元画像サイズにリサイズ
    if (maskGray.size() != targetColor.size()) {
        cv::resize(maskGray, maskGray, targetColor.size(), 0, 0, cv::INTER_NEAREST);
    }

    cv::Mat cleanRef;
    if (prevURL) {
        cleanRef = LoadColorMatFromURL(prevURL);
    }
    if (cleanRef.empty() && nextURL) {
        cleanRef = LoadColorMatFromURL(nextURL);
    }

    cv::Mat result = targetColor.clone();

    if (!cleanRef.empty() && cleanRef.size() == targetColor.size()) {
        // 前後フレームからピクセルを置換
        cleanRef.copyTo(result, maskGray);
    } else {
        // 周囲からインペイント
        cv::inpaint(targetColor, maskGray, result, 5, cv::INPAINT_TELEA);
    }

    return NSImageFromMat(result);
}

@end
