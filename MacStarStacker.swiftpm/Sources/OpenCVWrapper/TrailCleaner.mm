#import <opencv2/core.hpp>
#import <opencv2/imgproc.hpp>
#import <opencv2/imgcodecs.hpp>
#import <opencv2/photo.hpp> // cv::inpaint
#import <vector>
#import <deque>
#import <cmath>
#import <cfloat>
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

struct TrailCachedFrame {
    NSInteger index;
    cv::Mat color;
    cv::Mat gray;
};

struct TrailCandidate {
    cv::Mat mask;
    NSString *type;
    bool isStrobe;
};

// 近傍フレームの画素中央値を作る。フレーム数は最大6枚に制限する。
static cv::Mat TemporalMedian(const std::vector<cv::Mat> &frames) {
    if (frames.empty()) return cv::Mat();
    cv::Mat result(frames[0].size(), CV_8UC1);
    uchar values[8];
    for (int y = 0; y < result.rows; y++) {
        for (int x = 0; x < result.cols; x++) {
            int count = 0;
            for (const cv::Mat &frame : frames) {
                if (frame.empty() || frame.size() != result.size()) continue;
                values[count++] = frame.at<uchar>(y, x);
            }
            if (count == 0) {
                result.at<uchar>(y, x) = 0;
            } else {
                std::nth_element(values, values + count / 2, values + count);
                result.at<uchar>(y, x) = values[count / 2];
            }
        }
    }
    return result;
}

// カラー画像の時間中央値。補修用なので、解析解像度の画像に対してだけ使用する。
static cv::Mat TemporalMedianColor(const std::vector<cv::Mat> &frames) {
    if (frames.empty()) return cv::Mat();
    cv::Mat result(frames[0].size(), CV_8UC3);
    uchar values[8];
    for (int y = 0; y < result.rows; y++) {
        for (int x = 0; x < result.cols; x++) {
            for (int channel = 0; channel < 3; channel++) {
                int count = 0;
                for (const cv::Mat &frame : frames) {
                    if (frame.empty() || frame.size() != result.size() || frame.channels() != 3) continue;
                    values[count++] = frame.at<cv::Vec3b>(y, x)[channel];
                }
                if (count == 0) {
                    result.at<cv::Vec3b>(y, x)[channel] = 0;
                } else {
                    std::nth_element(values, values + count / 2, values + count);
                    result.at<cv::Vec3b>(y, x)[channel] = values[count / 2];
                }
            }
        }
    }
    return result;
}

static cv::Mat ResizeForTrailAnalysis(const cv::Mat &image, int targetWidth) {
    if (image.empty()) return cv::Mat();
    double scale = std::min(1.0, (double)targetWidth / (double)image.cols);
    if (scale >= 1.0) return image.clone();
    cv::Mat scaled;
    cv::resize(image, scaled, cv::Size(), scale, scale, cv::INTER_AREA);
    return scaled;
}

+ (NSArray<TrailDetectionResult *> *)detectTrailsInImageURLs:(NSArray<NSURL *> *)imageURLs
                                            progressCallback:(void (^ _Nullable)(double progress, NSString *status))progressCallback {
    NSMutableArray<TrailDetectionResult *> *results = [NSMutableArray array];
    NSInteger total = imageURLs.count;
    // 前後フレームが必要なため、2枚では解析しない。
    if (total < 3) return results;

    // 数千枚でもメモリが増え続けないよう、前後3枚だけをリングキャッシュする。
    const int targetWidth = 1400;
    std::deque<TrailCachedFrame> cache;
    auto loadCachedFrame = [&](NSInteger index) -> TrailCachedFrame * {
        if (index < 0 || index >= total) return nullptr;
        for (TrailCachedFrame &cached : cache) {
            if (cached.index == index) return &cached;
        }

        cv::Mat color = ResizeForTrailAnalysis(LoadColorMatFromURL(imageURLs[index]), targetWidth);
        TrailCachedFrame item;
        item.index = index;
        item.color = color;
        if (!color.empty()) cv::cvtColor(color, item.gray, cv::COLOR_BGR2GRAY);
        cache.push_back(std::move(item));
        while (cache.size() > 7) cache.pop_front();
        return &cache.back();
    };

    for (NSInteger i = 0; i < total; i++) {
        if (progressCallback) {
            progressCallback(0.35 + (double)i / (double)total * 0.65, [NSString stringWithFormat:@"光跡パターンを検出中 (%ld/%ld)...", (long)(i + 1), (long)total]);
        }

        while (!cache.empty() && cache.front().index < i - 3) cache.pop_front();
        TrailCachedFrame *current = loadCachedFrame(i);
        if (!current || current->gray.empty() || current->color.empty()) continue;
        cv::Mat currentColor = current->color;
        cv::Mat currentGray = current->gray;

        std::vector<cv::Mat> neighbors;
        std::vector<cv::Mat> neighborColors;
        for (NSInteger offset : {-3, -2, -1, 1, 2, 3}) {
            TrailCachedFrame *neighbor = loadCachedFrame(i + offset);
            if (!neighbor || neighbor->gray.empty() || neighbor->color.empty()) continue;
            // 異なる縦横比のフレームを暗黙にmin/subtractするとクラッシュするため除外する。
            if (neighbor->gray.size() != currentGray.size()) continue;
            neighbors.push_back(neighbor->gray);
            neighborColors.push_back(neighbor->color);
        }
        if (neighbors.size() < 2) continue;

        // 前後複数枚の中央値とMADで、露出変動と局所ノイズに適応する。
        cv::Mat bgRef = TemporalMedian(neighbors);
        cv::Mat madRef = cv::Mat::zeros(bgRef.size(), CV_8UC1);
        uchar deviations[8];
        for (int y = 0; y < bgRef.rows; y++) {
            for (int x = 0; x < bgRef.cols; x++) {
                int count = 0;
                uchar center = bgRef.at<uchar>(y, x);
                for (const cv::Mat &neighbor : neighbors) {
                    deviations[count++] = (uchar)std::abs((int)neighbor.at<uchar>(y, x) - (int)center);
                }
                std::nth_element(deviations, deviations + count / 2, deviations + count);
                madRef.at<uchar>(y, x) = deviations[count / 2];
            }
        }

        cv::Mat diff;
        cv::subtract(currentGray, bgRef, diff);
        cv::Mat thresh = cv::Mat::zeros(diff.size(), CV_8UC1);
        for (int y = 0; y < diff.rows; y++) {
            for (int x = 0; x < diff.cols; x++) {
                int delta = diff.at<uchar>(y, x);
                int threshold = std::max(12, 6 + (int)std::lround(4.0 * madRef.at<uchar>(y, x)));
                if (delta > threshold) thresh.at<uchar>(y, x) = 255;
            }
        }

        // モルフォロジー演算（孤立点星像ノイズ除去、線分接続）
        cv::Mat kernel = cv::getStructuringElement(cv::MORPH_ELLIPSE, cv::Size(3, 3));
        cv::morphologyEx(thresh, thresh, cv::MORPH_OPEN, kernel);
        cv::morphologyEx(thresh, thresh, cv::MORPH_CLOSE, kernel);

        // 画面の大部分が同時に明るくなった場合は露出変動・ヘッドライト等とみなし、
        // Hough線でフレーム全体を誤って消さない。局所的な光跡だけを候補化する。
        double foregroundFraction = (double)cv::countNonZero(thresh) / (double)(thresh.rows * thresh.cols);
        if (foregroundFraction > 0.20) continue;

        // 直線検出（Hough Lines）
        std::vector<cv::Vec4i> lines;
        cv::HoughLinesP(thresh, lines, 1, CV_PI / 180, 32, 30, 12);

        // 輪郭解析
        std::vector<std::vector<cv::Point>> contours;
        cv::findContours(thresh, contours, cv::RETR_EXTERNAL, cv::CHAIN_APPROX_SIMPLE);

        std::vector<TrailCandidate> candidates;
        auto addCandidate = [&](const cv::Mat &inputMask, NSString *type, bool isStrobe) {
            if (inputMask.empty() || cv::countNonZero(inputMask) == 0) return;
            cv::Mat mask = inputMask.clone();
            cv::Mat expanded;
            cv::dilate(mask, expanded, cv::getStructuringElement(cv::MORPH_ELLIPSE, cv::Size(3, 3)));
            for (TrailCandidate &candidate : candidates) {
                cv::Mat existingExpanded;
                cv::dilate(candidate.mask, existingExpanded, cv::getStructuringElement(cv::MORPH_ELLIPSE, cv::Size(3, 3)));
                cv::Mat overlap;
                cv::bitwise_and(expanded, existingExpanded, overlap);
                if (cv::countNonZero(overlap) > 0) {
                    cv::bitwise_or(candidate.mask, mask, candidate.mask);
                    candidate.isStrobe = candidate.isStrobe || isStrobe;
                    if (isStrobe) candidate.type = type;
                    return;
                }
            }
            candidates.push_back({mask, type, isStrobe});
        };

        // 1. 直線検出に基づく候補。線幅は解析解像度で3pxに抑える。
        for (size_t l = 0; l < lines.size(); l++) {
            cv::Vec4i ln = lines[l];
            double len = std::hypot(ln[2] - ln[0], ln[3] - ln[1]);
            if (len > 35.0) {
                cv::Mat lineMask = cv::Mat::zeros(currentGray.size(), CV_8UC1);
                cv::line(lineMask, cv::Point(ln[0], ln[1]), cv::Point(ln[2], ln[3]), cv::Scalar(255), 3);
                addCandidate(lineMask, @"人工衛星 (直線)", false);
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
            if (aspect > 2.5 && w > 25.0) {
                cv::Mat contourMask = cv::Mat::zeros(currentGray.size(), CV_8UC1);
                cv::drawContours(contourMask, contours, (int)c, cv::Scalar(255), cv::FILLED);
                addCandidate(contourMask, @"人工衛星 (直線)", false);
            }
        }

        // 3. 点滅ストロボ（飛行機アンチコリジョンライト）の検出
        // 赤/緑成分の強い突発ピクセル
        if (!currentColor.empty()) {
            cv::Mat bgr[3];
            cv::split(currentColor, bgr);
            cv::Mat redExcess, greenExcess;
            cv::subtract(bgr[2], bgr[0], redExcess); // R - B
            cv::subtract(bgr[1], bgr[0], greenExcess); // G - B
            cv::Mat strobeMask;
            cv::bitwise_or(redExcess > 40, greenExcess > 40, strobeMask);
            cv::bitwise_and(strobeMask, thresh, strobeMask);
            std::vector<std::vector<cv::Point>> strobeContours;
            cv::findContours(strobeMask, strobeContours, cv::RETR_EXTERNAL, cv::CHAIN_APPROX_SIMPLE);
            for (const auto &strobeContour : strobeContours) {
                if (cv::contourArea(strobeContour) < 8.0) continue;
                cv::Mat component = cv::Mat::zeros(currentGray.size(), CV_8UC1);
                cv::drawContours(component, std::vector<std::vector<cv::Point>>{strobeContour}, 0, cv::Scalar(255), cv::FILLED);
                addCandidate(component, @"飛行機 (点滅ストロボ・航跡灯)", true);
            }
        }

        cv::Mat previewBase = TemporalMedianColor(neighborColors);
        for (TrailCandidate &candidate : candidates) {
            cv::Mat trailMask = candidate.mask.clone();
            cv::dilate(trailMask, trailMask, cv::getStructuringElement(cv::MORPH_ELLIPSE, cv::Size(3, 3)));
            std::vector<cv::Point> points;
            cv::findNonZero(candidate.mask, points);
            if (points.empty()) continue;
            cv::RotatedRect candidateRect = cv::minAreaRect(points);
            float candidateW = std::max(candidateRect.size.width, candidateRect.size.height);
            float candidateH = std::min(candidateRect.size.width, candidateRect.size.height);
            float candidateAspect = candidateH > 0 ? candidateW / candidateH : 0;
            double confidence = std::min(1.0, std::max(0.0, (double)candidateW / 180.0));

            // 軸方向の両端の輝度非対称性を実測する。単なる細長さだけでは流星扱いしない。
            bool isLikelyMeteor = false;
            if (!candidate.isStrobe && candidateAspect > 4.5 && points.size() > 50) {
                cv::Vec4f fitted;
                cv::fitLine(points, fitted, cv::DIST_L2, 0, 0.01, 0.01);
                cv::Point2f origin(fitted[2], fitted[3]);
                cv::Point2f axis(fitted[0], fitted[1]);
                double minProjection = DBL_MAX, maxProjection = -DBL_MAX;
                for (const cv::Point &point : points) {
                    double projection = (point.x - origin.x) * axis.x + (point.y - origin.y) * axis.y;
                    minProjection = std::min(minProjection, projection);
                    maxProjection = std::max(maxProjection, projection);
                }
                double span = std::max(1.0, maxProjection - minProjection);
                double lowSum = 0, highSum = 0; int lowCount = 0, highCount = 0;
                for (const cv::Point &point : points) {
                    double projection = (point.x - origin.x) * axis.x + (point.y - origin.y) * axis.y;
                    uchar value = currentGray.at<uchar>(point);
                    if (projection < minProjection + span * 0.25) { lowSum += value; lowCount++; }
                    if (projection > maxProjection - span * 0.25) { highSum += value; highCount++; }
                }
                double lowMean = lowCount > 0 ? lowSum / lowCount : 0;
                double highMean = highCount > 0 ? highSum / highCount : 0;
                double asymmetry = std::abs(lowMean - highMean) / std::max(1.0, lowMean + highMean);
                isLikelyMeteor = asymmetry > 0.65;
            }

            NSString *detectedType = candidate.type;
            if (isLikelyMeteor) detectedType = @"流星の可能性あり (要確認)";
            // ハイライト画像の作成（元画像 + 赤色オーバーレイ）
            cv::Mat highlightedColor = currentColor.clone();
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

            // 前後複数枚の中央値でプレビューを作る。単一前フレームの転写を避ける。
            cv::Mat repairedColor = currentColor.clone();
            if (!previewBase.empty() && previewBase.size() == currentColor.size()) {
                previewBase.copyTo(repairedColor, trailMask);
            }

            TrailDetectionResult *result = [[TrailDetectionResult alloc] init];
            result.frameIndex = i;
            result.filePath = imageURLs[i].path;
            result.maskImage = NSImageFromMat(trailMask);
            result.highlightedImage = NSImageFromMat(highlightedColor);
            result.repairedImage = NSImageFromMat(repairedColor);
            result.detectedType = detectedType;
            result.confidenceScore = confidence;
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
    return [self inpaintImageAtURL:targetURL withMasks:(maskImage ? @[maskImage] : @[]) prevFrameURL:prevURL nextFrameURL:nextURL];
}

+ (nullable NSImage *)inpaintImageAtURL:(NSURL *)targetURL
                              withMasks:(NSArray<NSImage *> *)maskImages
                          prevFrameURL:(nullable NSURL *)prevURL
                          nextFrameURL:(nullable NSURL *)nextURL {
    cv::Mat targetColor = LoadColorMatFromURL(targetURL);
    if (targetColor.empty()) return nil;

    cv::Mat maskGray;
    for (NSImage *maskImage in maskImages) {
        cv::Mat oneMask = MatFromNSImage(maskImage);
        if (oneMask.empty()) continue;
        if (oneMask.size() != targetColor.size()) {
            cv::resize(oneMask, oneMask, targetColor.size(), 0, 0, cv::INTER_NEAREST);
        }
        if (maskGray.empty()) maskGray = cv::Mat::zeros(targetColor.size(), CV_8UC1);
        cv::bitwise_or(maskGray, oneMask, maskGray);
    }
    if (maskGray.empty()) return NSImageFromMat(targetColor);

    cv::Mat prevColor = prevURL ? LoadColorMatFromURL(prevURL) : cv::Mat();
    cv::Mat nextColor = nextURL ? LoadColorMatFromURL(nextURL) : cv::Mat();
    cv::Mat cleanRef;
    bool prevValid = !prevColor.empty() && prevColor.size() == targetColor.size();
    bool nextValid = !nextColor.empty() && nextColor.size() == targetColor.size();
    if (prevValid && nextValid) {
        // 前後両方を使い、片側の雲やフリッカーをそのまま転写しない。
        cv::addWeighted(prevColor, 0.5, nextColor, 0.5, 0.0, cleanRef);
    } else if (prevValid) {
        cleanRef = prevColor;
    } else if (nextValid) {
        cleanRef = nextColor;
    }

    cv::Mat result = targetColor.clone();

    if (!cleanRef.empty() && cleanRef.size() == targetColor.size()) {
        // マスク境界だけをフェザーし、参照フレーム自体はぼかさない。
        cv::Mat featherMask;
        cv::GaussianBlur(maskGray, featherMask, cv::Size(5, 5), 0.0);
        for (int y = 0; y < result.rows; y++) {
            for (int x = 0; x < result.cols; x++) {
                float alpha = featherMask.at<uchar>(y, x) / 255.0f;
                if (alpha <= 0.0f) continue;
                cv::Vec3b src = result.at<cv::Vec3b>(y, x);
                cv::Vec3b ref = cleanRef.at<cv::Vec3b>(y, x);
                for (int c = 0; c < 3; c++) {
                    result.at<cv::Vec3b>(y, x)[c] = (uchar)std::lround(src[c] * (1.0f - alpha) + ref[c] * alpha);
                }
            }
        }
    } else {
        // 周囲からインペイント
        cv::inpaint(targetColor, maskGray, result, 5, cv::INPAINT_TELEA);
    }

    return NSImageFromMat(result);
}

@end
