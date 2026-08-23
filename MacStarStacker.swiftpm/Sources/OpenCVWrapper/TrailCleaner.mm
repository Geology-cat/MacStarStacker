#import <opencv2/core.hpp>
#import <opencv2/imgproc.hpp>
#import <opencv2/imgcodecs.hpp>
#import <opencv2/photo.hpp> // cv::inpaint
#import <vector>
#import <deque>
#import <cmath>
#import <cfloat>
#import <algorithm>
#import <cstdlib>
#import <cstdio>

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
    cv::Rect bounds;
    NSString *type;
    bool isStrobe;
    double evidence;
};

static inline uchar SmallUpperMedian(uchar *values, int count) {
    // 最大6要素なので、汎用nth_elementよりオーバーヘッドの小さい挿入ソートを使う。
    for (int i = 1; i < count; i++) {
        uchar value = values[i];
        int j = i - 1;
        while (j >= 0 && values[j] > value) {
            values[j + 1] = values[j];
            j--;
        }
        values[j + 1] = value;
    }
    return values[count / 2];
}

// 時間中央値とMADを1回の画素走査で同時に求める。
static bool TemporalMedianAndMAD(const std::vector<cv::Mat> &frames,
                                 cv::Mat &median,
                                 cv::Mat &mad) {
    if (frames.empty()) return false;
    const cv::Size size = frames[0].size();
    for (const cv::Mat &frame : frames) {
        if (frame.empty() || frame.type() != CV_8UC1 || frame.size() != size) return false;
    }

    median.create(size, CV_8UC1);
    mad.create(size, CV_8UC1);
    uchar values[8];
    uchar deviations[8];
    for (int y = 0; y < size.height; y++) {
        const uchar *rows[8];
        for (size_t index = 0; index < frames.size(); index++) {
            rows[index] = frames[index].ptr<uchar>(y);
        }
        uchar *medianRow = median.ptr<uchar>(y);
        uchar *madRow = mad.ptr<uchar>(y);
        for (int x = 0; x < size.width; x++) {
            for (size_t index = 0; index < frames.size(); index++) values[index] = rows[index][x];
            uchar center = SmallUpperMedian(values, (int)frames.size());
            medianRow[x] = center;
            for (size_t index = 0; index < frames.size(); index++) {
                deviations[index] = (uchar)std::abs((int)rows[index][x] - (int)center);
            }
            madRow[x] = SmallUpperMedian(deviations, (int)frames.size());
        }
    }
    return true;
}

// カラー画像の時間中央値。補修用なので、解析解像度の画像に対してだけ使用する。
static cv::Mat TemporalMedianColor(const std::vector<cv::Mat> &frames) {
    if (frames.empty()) return cv::Mat();
    const cv::Size size = frames[0].size();
    for (const cv::Mat &frame : frames) {
        if (frame.empty() || frame.type() != CV_8UC3 || frame.size() != size) return cv::Mat();
    }
    cv::Mat result(size, CV_8UC3);
    uchar values[8];
    for (int y = 0; y < result.rows; y++) {
        const cv::Vec3b *rows[8];
        for (size_t index = 0; index < frames.size(); index++) {
            rows[index] = frames[index].ptr<cv::Vec3b>(y);
        }
        cv::Vec3b *resultRow = result.ptr<cv::Vec3b>(y);
        for (int x = 0; x < result.cols; x++) {
            for (int channel = 0; channel < 3; channel++) {
                for (size_t index = 0; index < frames.size(); index++) {
                    values[index] = rows[index][x][channel];
                }
                resultRow[x][channel] = SmallUpperMedian(values, (int)frames.size());
            }
        }
    }
    return result;
}

// 正の時間差分の百分位点を求め、撮影ノイズに応じた最低閾値に使う。
static int UCharPercentile(const cv::Mat &image, double percentile) {
    if (image.empty() || image.type() != CV_8UC1) return 0;
    size_t histogram[256] = {};
    for (int y = 0; y < image.rows; y++) {
        const uchar *row = image.ptr<uchar>(y);
        for (int x = 0; x < image.cols; x++) histogram[row[x]]++;
    }
    size_t target = (size_t)std::ceil(image.total() * std::clamp(percentile, 0.0, 1.0));
    size_t cumulative = 0;
    for (int value = 0; value < 256; value++) {
        cumulative += histogram[value];
        if (cumulative >= target) return value;
    }
    return 255;
}

struct LineContinuityEvidence {
    bool valid;
    double length;
    double continuity;
    double meanResponse;
    double medianResponse;
};

// 線の中心3pxと、その両側4〜6pxの輝度差を全長に沿って積算する。
// 星像が偶然並んだ線は応答が途切れる一方、人工衛星の連続線は高い連続率を保つ。
static LineContinuityEvidence MeasureLineContinuity(const cv::Mat &image,
                                                    const cv::Vec4f &line,
                                                    double responseThreshold) {
    LineContinuityEvidence result = {false, 0, 0, 0, 0};
    if (image.empty() || image.type() != CV_8UC1) return result;

    double dx = line[2] - line[0];
    double dy = line[3] - line[1];
    double length = std::hypot(dx, dy);
    if (length < 1.0) return result;
    dx /= length;
    dy /= length;
    double perpendicularX = -dy;
    double perpendicularY = dx;
    int sampleCount = std::max(2, (int)std::ceil(length) + 1);

    std::vector<double> responses;
    responses.reserve(sampleCount);
    int supportedCount = 0;
    double responseSum = 0;
    for (int sample = 0; sample < sampleCount; sample++) {
        double distance = length * sample / (sampleCount - 1);
        double centerX = line[0] + dx * distance;
        double centerY = line[1] + dy * distance;
        double coreSum = 0;
        double sideSum = 0;
        int coreCount = 0;
        int sideCount = 0;

        for (int offset = -1; offset <= 1; offset++) {
            int x = (int)std::lround(centerX + perpendicularX * offset);
            int y = (int)std::lround(centerY + perpendicularY * offset);
            if (x >= 0 && x < image.cols && y >= 0 && y < image.rows) {
                coreSum += image.at<uchar>(y, x);
                coreCount++;
            }
        }
        for (int offset : {-6, -5, -4, 4, 5, 6}) {
            int x = (int)std::lround(centerX + perpendicularX * offset);
            int y = (int)std::lround(centerY + perpendicularY * offset);
            if (x >= 0 && x < image.cols && y >= 0 && y < image.rows) {
                sideSum += image.at<uchar>(y, x);
                sideCount++;
            }
        }
        if (coreCount < 2 || sideCount < 4) continue;
        double response = coreSum / coreCount - sideSum / sideCount;
        responses.push_back(response);
        responseSum += response;
        if (response >= responseThreshold) supportedCount++;
    }

    if (responses.size() < std::max<size_t>(12, (size_t)std::lround(length * 0.65))) return result;
    std::vector<double> sortedResponses = responses;
    size_t middle = sortedResponses.size() / 2;
    std::nth_element(sortedResponses.begin(), sortedResponses.begin() + middle, sortedResponses.end());
    result.valid = true;
    result.length = length;
    result.continuity = (double)supportedCount / responses.size();
    result.meanResponse = responseSum / responses.size();
    result.medianResponse = sortedResponses[middle];
    return result;
}

static cv::Vec4f ExtendAndClipLine(const cv::Vec4f &line,
                                   double extension,
                                   const cv::Size &size) {
    double dx = line[2] - line[0];
    double dy = line[3] - line[1];
    double length = std::max(1.0, std::hypot(dx, dy));
    dx /= length;
    dy /= length;
    return cv::Vec4f(
        (float)std::clamp(line[0] - dx * extension, 0.0, (double)(size.width - 1)),
        (float)std::clamp(line[1] - dy * extension, 0.0, (double)(size.height - 1)),
        (float)std::clamp(line[2] + dx * extension, 0.0, (double)(size.width - 1)),
        (float)std::clamp(line[3] + dy * extension, 0.0, (double)(size.height - 1))
    );
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
    // 4K画像の1〜2px幅の微弱線を潰さないよう、解析幅を2Kまで保つ。
    const int targetWidth = 2048;
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

        // 5枚以上ある連番では前後2枚ずつを持たない端フレームを判定しない。
        // 片側だけの時間中央値は星像の移動を光跡と誤認しやすいため。
        if (total >= 5 && (i < 2 || i >= total - 2)) continue;

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
        cv::Mat bgRef, madRef;
        if (!TemporalMedianAndMAD(neighbors, bgRef, madRef)) continue;

        cv::Mat diff;
        cv::subtract(currentGray, bgRef, diff);
        cv::Mat thresh = cv::Mat::zeros(diff.size(), CV_8UC1);
        // 清浄な画像では5階調差を維持し、実写の高感度ノイズやJPEG揺らぎが
        // 多い画像では正差分の95百分位まで自動的にノイズ床を上げる。
        const int globalNoiseFloor = std::max(5, UCharPercentile(diff, 0.95));
        for (int y = 0; y < diff.rows; y++) {
            const uchar *diffRow = diff.ptr<uchar>(y);
            const uchar *madRow = madRef.ptr<uchar>(y);
            uchar *thresholdRow = thresh.ptr<uchar>(y);
            for (int x = 0; x < diff.cols; x++) {
                int delta = diffRow[x];
                int mad = madRow[x];
                // 静穏領域では5階調差まで拾い、変動領域ではMADに応じて
                // 自動的に閾値を上げる。従来の最低12で消えていた微弱衛星線を保つ。
                int threshold = std::max(globalNoiseFloor, 3 + (int)std::lround(2.5 * mad));
                if (delta >= threshold) thresholdRow[x] = 255;
            }
        }

        // 1px幅の衛星線を消すOPEN処理は行わず、小さな切れ目の接続だけ行う。
        cv::Mat kernel = cv::getStructuringElement(cv::MORPH_ELLIPSE, cv::Size(3, 3));
        cv::morphologyEx(thresh, thresh, cv::MORPH_CLOSE, kernel);

        // 画面の大部分が同時に明るくなった場合は露出変動・ヘッドライト等とみなし、
        // Hough線でフレーム全体を誤って消さない。局所的な光跡だけを候補化する。
        double foregroundFraction = (double)cv::countNonZero(thresh) / (double)(thresh.rows * thresh.cols);
        if (foregroundFraction > 0.20) continue;

        // 輪郭解析
        std::vector<std::vector<cv::Point>> contours;
        cv::findContours(thresh, contours, cv::RETR_EXTERNAL, cv::CHAIN_APPROX_SIMPLE);

        // 星像・JPEGノイズなどの小さな塊をHough入力から除外する。
        // 1px幅の直線は面積が0になるため、面積ではなく回転矩形の長さと縦横比で残す。
        cv::Mat lineSearchMask = cv::Mat::zeros(thresh.size(), CV_8UC1);
        for (size_t c = 0; c < contours.size(); c++) {
            cv::RotatedRect rRect = cv::minAreaRect(contours[c]);
            double longSpan = std::max(rRect.size.width, rRect.size.height);
            double shortSpan = std::max(1.0, (double)std::min(rRect.size.width, rRect.size.height));
            if (longSpan >= 6.0 && longSpan / shortSpan >= 1.8) {
                cv::drawContours(lineSearchMask, contours, (int)c, cv::Scalar(255), cv::FILLED);
            }
        }

        // 直線検出（Hough Lines）。前処理済みマスクを使い、高感度設定の計算量と誤候補を抑える。
        std::vector<cv::Vec4i> lines;
        cv::HoughLinesP(lineSearchMask, lines, 1, CV_PI / 360, 14, 18, 10);

        std::vector<TrailCandidate> candidates;
        auto addCandidate = [&](const cv::Mat &inputMask, NSString *type, bool isStrobe, double evidence) {
            if (inputMask.empty() || cv::countNonZero(inputMask) == 0) return;
            cv::Mat mask = inputMask.clone();
            std::vector<cv::Point> nonZeroPoints;
            cv::findNonZero(mask, nonZeroPoints);
            if (nonZeroPoints.empty()) return;
            cv::Rect bounds = cv::boundingRect(nonZeroPoints);
            cv::Rect paddedBounds(
                std::max(0, bounds.x - 3),
                std::max(0, bounds.y - 3),
                std::min(mask.cols, bounds.x + bounds.width + 3) - std::max(0, bounds.x - 3),
                std::min(mask.rows, bounds.y + bounds.height + 3) - std::max(0, bounds.y - 3)
            );
            for (TrailCandidate &candidate : candidates) {
                cv::Rect candidatePadded(
                    std::max(0, candidate.bounds.x - 3),
                    std::max(0, candidate.bounds.y - 3),
                    std::min(mask.cols, candidate.bounds.x + candidate.bounds.width + 3) - std::max(0, candidate.bounds.x - 3),
                    std::min(mask.rows, candidate.bounds.y + candidate.bounds.height + 3) - std::max(0, candidate.bounds.y - 3)
                );
                cv::Rect intersection = paddedBounds & candidatePadded;
                if (intersection.empty()) continue;
                cv::Mat expanded;
                cv::dilate(mask, expanded, cv::getStructuringElement(cv::MORPH_ELLIPSE, cv::Size(7, 7)));
                cv::Mat existingExpanded;
                cv::dilate(candidate.mask, existingExpanded, cv::getStructuringElement(cv::MORPH_ELLIPSE, cv::Size(7, 7)));
                cv::Mat overlap;
                cv::bitwise_and(expanded(intersection), existingExpanded(intersection), overlap);
                if (cv::countNonZero(overlap) > 0) {
                    cv::bitwise_or(candidate.mask, mask, candidate.mask);
                    candidate.bounds |= bounds;
                    candidate.isStrobe = candidate.isStrobe || isStrobe;
                    candidate.evidence = std::max(candidate.evidence, evidence);
                    if (isStrobe) {
                        candidate.type = type;
                    } else if ([type containsString:@"低コントラスト"]
                               && ![candidate.type containsString:@"低コントラスト"]) {
                        // 厳密経路の断片を補助経路が延長した場合は、低コントラスト補完を表示する。
                        candidate.type = type;
                    }
                    return;
                }
            }
            candidates.push_back({mask, bounds, type, isStrobe, evidence});
        };

        // 1. 直線検出に基づく候補。支持画素率と周辺との輝度差を再検証し、
        // 閾値を下げてもランダムノイズや広い明暗境界を拾いにくくする。
        cv::Mat validatedLineMask = cv::Mat::zeros(currentGray.size(), CV_8UC1);
        for (size_t l = 0; l < lines.size(); l++) {
            cv::Vec4i ln = lines[l];
            double len = std::hypot(ln[2] - ln[0], ln[3] - ln[1]);
            if (len < 18.0) continue;

            int left = std::max(0, std::min(ln[0], ln[2]) - 6);
            int top = std::max(0, std::min(ln[1], ln[3]) - 6);
            int right = std::min(currentGray.cols, std::max(ln[0], ln[2]) + 7);
            int bottom = std::min(currentGray.rows, std::max(ln[1], ln[3]) + 7);
            cv::Rect roi(left, top, right - left, bottom - top);
            cv::Point start(ln[0] - left, ln[1] - top);
            cv::Point end(ln[2] - left, ln[3] - top);
            cv::Mat lineMask = cv::Mat::zeros(roi.size(), CV_8UC1);
            cv::line(lineMask, start, end, cv::Scalar(255), 3);
            cv::Mat supported;
            cv::bitwise_and(lineMask, thresh(roi), supported);
            int linePixels = cv::countNonZero(lineMask);
            int supportPixels = cv::countNonZero(supported);
            double supportRatio = linePixels > 0 ? (double)supportPixels / (double)linePixels : 0.0;
            if (supportPixels < std::max(8, (int)std::lround(len * 0.20)) || supportRatio < 0.16) continue;

            cv::Mat wideMask = cv::Mat::zeros(roi.size(), CV_8UC1);
            cv::line(wideMask, start, end, cv::Scalar(255), 11);
            cv::Mat sideMask;
            cv::subtract(wideMask, lineMask, sideMask);
            double coreSignal = cv::mean(diff(roi), supported)[0];
            double sideSignal = cv::countNonZero(sideMask) > 0 ? cv::mean(diff(roi), sideMask)[0] : 0.0;
            if (coreSignal < 5.0 || coreSignal < sideSignal + 2.0) continue;

            cv::line(validatedLineMask, cv::Point(ln[0], ln[1]), cv::Point(ln[2], ln[3]), cv::Scalar(255), 3);
        }

        // 2. 輪郭解析（細長いストリーク、または点滅ストロボ）
        for (size_t c = 0; c < contours.size(); c++) {
            double area = cv::contourArea(contours[c]);
            if (area < 8) continue;

            cv::RotatedRect rRect = cv::minAreaRect(contours[c]);
            float w = rRect.size.width;
            float h = rRect.size.height;
            if (w < h) std::swap(w, h);

            float aspect = (h > 0) ? (w / h) : 0;

            // Houghで分断された細長いストリークも輪郭経路で拾う。
            if (aspect > 3.0 && w > 18.0) {
                cv::Mat contourMask = cv::Mat::zeros(currentGray.size(), CV_8UC1);
                cv::drawContours(contourMask, contours, (int)c, cv::Scalar(255), cv::FILLED);
                cv::Mat expandedMask, sideMask;
                cv::dilate(contourMask, expandedMask, cv::getStructuringElement(cv::MORPH_ELLIPSE, cv::Size(9, 9)));
                cv::subtract(expandedMask, contourMask, sideMask);
                double coreSignal = cv::mean(diff, contourMask)[0];
                double sideSignal = cv::countNonZero(sideMask) > 0 ? cv::mean(diff, sideMask)[0] : 0.0;
                if (coreSignal >= 5.0 && coreSignal >= sideSignal + 2.0) {
                    cv::bitwise_or(validatedLineMask, contourMask, validatedLineMask);
                }
            }
        }

        // 同一光跡から得た多数のHough線を一度だけ連結し、候補数とメモリ量を抑える。
        cv::morphologyEx(
            validatedLineMask,
            validatedLineMask,
            cv::MORPH_CLOSE,
            cv::getStructuringElement(cv::MORPH_ELLIPSE, cv::Size(5, 5))
        );
        std::vector<std::vector<cv::Point>> validatedContours;
        cv::findContours(validatedLineMask, validatedContours, cv::RETR_EXTERNAL, cv::CHAIN_APPROX_SIMPLE);
        // ノイズ床が高い画像では、短い星像・圧縮模様を人工衛星と誤認しやすい。
        // 清浄画像の18px感度は維持しつつ、ノイズ量に比例して信頼できる最短長を伸ばす。
        const double minimumReliableLength = std::min(
            60.0,
            18.0 + std::max(0, globalNoiseFloor - 5) * 2.5
        );
        for (size_t c = 0; c < validatedContours.size(); c++) {
            cv::RotatedRect componentRect = cv::minAreaRect(validatedContours[c]);
            double length = std::max(componentRect.size.width, componentRect.size.height);
            if (length < minimumReliableLength) continue;
            cv::Mat componentMask = cv::Mat::zeros(currentGray.size(), CV_8UC1);
            cv::drawContours(componentMask, validatedContours, (int)c, cv::Scalar(255), cv::FILLED);
            double evidence = std::min(1.0, 0.35 + std::min(0.50, length / 400.0));
            addCandidate(componentMask, @"人工衛星 (微弱・細長い光跡)", false, evidence);
        }

        // 3. 低い画素閾値と線方向の積算を組み合わせる高感度経路。
        // 画素単体ではノイズ床を下回っていても、全長に連続する微弱線を拾う。
        size_t integratedLineCount = 0;
        size_t weakHoughLineCount = 0;
        cv::Mat weakThresholdMask = cv::Mat::zeros(diff.size(), CV_8UC1);
        const int weakGlobalFloor = std::max(3, (int)std::lround(globalNoiseFloor * 0.65));
        for (int y = 0; y < diff.rows; y++) {
            const uchar *diffRow = diff.ptr<uchar>(y);
            const uchar *madRow = madRef.ptr<uchar>(y);
            uchar *weakRow = weakThresholdMask.ptr<uchar>(y);
            for (int x = 0; x < diff.cols; x++) {
                int localFloor = std::max(
                    weakGlobalFloor,
                    1 + (int)std::lround(0.75 * madRow[x])
                );
                if (diffRow[x] >= localFloor) weakRow[x] = 255;
            }
        }
        cv::morphologyEx(weakThresholdMask, weakThresholdMask, cv::MORPH_CLOSE, kernel);
        double weakForegroundFraction = (double)cv::countNonZero(weakThresholdMask)
            / (double)(weakThresholdMask.rows * weakThresholdMask.cols);
        if (weakForegroundFraction <= 0.30) {
            std::vector<std::vector<cv::Point>> weakContours;
            cv::findContours(weakThresholdMask, weakContours, cv::RETR_EXTERNAL, cv::CHAIN_APPROX_SIMPLE);
            cv::Mat weakLineSearchMask = cv::Mat::zeros(weakThresholdMask.size(), CV_8UC1);
            for (size_t c = 0; c < weakContours.size(); c++) {
                cv::RotatedRect rRect = cv::minAreaRect(weakContours[c]);
                double longSpan = std::max(rRect.size.width, rRect.size.height);
                double shortSpan = std::max(1.0, (double)std::min(rRect.size.width, rRect.size.height));
                if (longSpan >= 6.0 && longSpan / shortSpan >= 1.8) {
                    cv::drawContours(weakLineSearchMask, weakContours, (int)c, cv::Scalar(255), cv::FILLED);
                }
            }

            std::vector<cv::Vec4i> weakLines;
            cv::HoughLinesP(weakLineSearchMask, weakLines, 1, CV_PI / 360, 12, 18, 14);
            weakHoughLineCount = weakLines.size();
            double imageDiagonal = std::hypot(currentGray.cols, currentGray.rows);
            double minimumIntegratedLength = std::max(24.0, imageDiagonal * 0.008);
            for (const cv::Vec4i &integerLine : weakLines) {
                cv::Vec4f line(
                    integerLine[0], integerLine[1], integerLine[2], integerLine[3]
                );
                double length = std::hypot(line[2] - line[0], line[3] - line[1]);
                if (length < minimumIntegratedLength) continue;
                LineContinuityEvidence spatialEvidence = MeasureLineContinuity(currentGray, line, 2.0);
                LineContinuityEvidence temporalEvidence = MeasureLineContinuity(diff, line, 2.0);
                if (!spatialEvidence.valid || !temporalEvidence.valid) continue;
                if (spatialEvidence.continuity < 0.78 || temporalEvidence.continuity < 0.78) continue;
                if (spatialEvidence.medianResponse < 1.5 || temporalEvidence.medianResponse < 1.5) continue;
                if (temporalEvidence.meanResponse < std::max(2.5, weakGlobalFloor * 0.25)) continue;

                cv::Vec4f extended = ExtendAndClipLine(line, 5.0, currentGray.size());
                cv::Mat integratedMask = cv::Mat::zeros(currentGray.size(), CV_8UC1);
                cv::line(
                    integratedMask,
                    cv::Point((int)std::lround(extended[0]), (int)std::lround(extended[1])),
                    cv::Point((int)std::lround(extended[2]), (int)std::lround(extended[3])),
                    cv::Scalar(255),
                    3
                );
                double evidence = std::min(
                    1.0,
                    0.30
                        + std::min(0.25, length / 300.0)
                        + std::min(0.20, temporalEvidence.continuity * 0.20)
                        + std::min(0.20, temporalEvidence.meanResponse / 60.0)
                );
                addCandidate(integratedMask, @"人工衛星 (低コントラスト・線積算)", false, evidence);
                integratedLineCount++;
            }
        }

        // 4. 単一フレームの局所コントラストから短い線分も抽出する。
        // 時間差分でも同じ線が連続して明るい場合だけ採用し、地形境界や恒星を除外する。
        size_t lowContrastSegmentCount = 0;
        cv::Mat localContrast, enhancedContrast;
        cv::morphologyEx(
            currentGray,
            localContrast,
            cv::MORPH_TOPHAT,
            cv::getStructuringElement(cv::MORPH_ELLIPSE, cv::Size(9, 9))
        );
        localContrast.convertTo(enhancedContrast, CV_8UC1, 4.0);
        cv::Ptr<cv::LineSegmentDetector> lineSegmentDetector = cv::createLineSegmentDetector(
            cv::LSD_REFINE_STD,
            0.8,
            0.6,
            1.0,
            22.5,
            0.0,
            0.6,
            1024
        );
        std::vector<cv::Vec4f> lowContrastLines;
        lineSegmentDetector->detect(enhancedContrast, lowContrastLines);
        for (const cv::Vec4f &line : lowContrastLines) {
            double length = std::hypot(line[2] - line[0], line[3] - line[1]);
            if (length < 18.0) continue;
            LineContinuityEvidence spatialEvidence = MeasureLineContinuity(currentGray, line, 2.0);
            LineContinuityEvidence temporalEvidence = MeasureLineContinuity(diff, line, 2.0);
            if (!spatialEvidence.valid || !temporalEvidence.valid) continue;
            if (spatialEvidence.continuity < 0.78 || temporalEvidence.continuity < 0.75) continue;
            if (spatialEvidence.medianResponse < 2.0 || temporalEvidence.medianResponse < 2.0) continue;
            if (temporalEvidence.meanResponse < std::max(2.5, globalNoiseFloor * 0.20)) continue;

            cv::Vec4f extended = ExtendAndClipLine(line, 6.0, currentGray.size());
            cv::Mat segmentMask = cv::Mat::zeros(currentGray.size(), CV_8UC1);
            cv::line(
                segmentMask,
                cv::Point((int)std::lround(extended[0]), (int)std::lround(extended[1])),
                cv::Point((int)std::lround(extended[2]), (int)std::lround(extended[3])),
                cv::Scalar(255),
                3
            );
            double evidence = std::min(
                1.0,
                0.28
                    + std::min(0.22, length / 180.0)
                    + std::min(0.22, temporalEvidence.continuity * 0.22)
                    + std::min(0.20, temporalEvidence.meanResponse / 60.0)
            );
            addCandidate(segmentMask, @"人工衛星 (低コントラスト短線)", false, evidence);
            lowContrastSegmentCount++;
        }

        // 5. 点滅ストロボ（飛行機アンチコリジョンライト）の検出
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
                addCandidate(component, @"飛行機 (点滅ストロボ・航跡灯)", true, 0.75);
            }
        }

        if (std::getenv("MACSTARSTACKER_TRAIL_DEBUG")) {
            std::fprintf(
                stderr,
                "TRAIL_DEBUG frame=%ld noise=%d foreground=%.4f weakFloor=%d weakForeground=%.4f contours=%zu lines=%zu weakLines=%zu lsdLines=%zu integrated=%zu lsd=%zu candidates=%zu\n",
                (long)i,
                globalNoiseFloor,
                foregroundFraction,
                weakGlobalFloor,
                weakForegroundFraction,
                contours.size(),
                lines.size(),
                weakHoughLineCount,
                lowContrastLines.size(),
                integratedLineCount,
                lowContrastSegmentCount,
                candidates.size()
            );
        }
        if (candidates.empty()) continue;
        cv::Mat previewBase = TemporalMedianColor(neighborColors);
        NSImage *originalPreview = NSImageFromMat(currentColor);
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
            double confidence = std::max(candidate.evidence,
                std::min(1.0, std::max(0.0, (double)candidateW / 300.0)));

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
            std::vector<cv::Point> highlightedPoints;
            cv::findNonZero(trailMask, highlightedPoints);
            for (const cv::Point &point : highlightedPoints) {
                cv::Vec3b &px = highlightedColor.at<cv::Vec3b>(point);
                px[0] = (uchar)(px[0] * 0.3);        // B
                px[1] = (uchar)(px[1] * 0.3);        // G
                px[2] = (uchar)(std::min(255, px[2] + 180)); // R (赤強調)
            }

            // 前後複数枚の中央値でプレビューを作る。単一前フレームの転写を避ける。
            cv::Mat repairedColor = currentColor.clone();
            if (!previewBase.empty() && previewBase.size() == currentColor.size()) {
                previewBase.copyTo(repairedColor, trailMask);
            }

            TrailDetectionResult *result = [[TrailDetectionResult alloc] init];
            result.frameIndex = i;
            result.filePath = imageURLs[i].path;
            result.originalImage = originalPreview;
            result.maskImage = NSImageFromMat(trailMask);
            result.highlightedImage = NSImageFromMat(highlightedColor);
            result.repairedImage = NSImageFromMat(repairedColor);
            result.detectedBounds = NSMakeRect(
                candidate.bounds.x,
                candidate.bounds.y,
                candidate.bounds.width,
                candidate.bounds.height
            );
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
