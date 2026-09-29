#import <opencv2/core.hpp>
#import <opencv2/imgproc.hpp>
#import <opencv2/imgcodecs.hpp>
#import <opencv2/calib3d.hpp>
#import <opencv2/features2d.hpp>
#import <algorithm>
#import <cmath>
#import <unordered_map>
#import <vector>

#import "StarAligner.h"
#import "TimelapseStabilizer.h"

// ─────────────────────────────────────────────
//  星の検出
// ─────────────────────────────────────────────

namespace {

struct Star {
    float x;     // 元画像の画素座標
    float y;
    float flux;  // 背景を除いた明るさの合計
};

/// 基準画像・対象画像それぞれで使う星の最大数（明るい順）
const int kMaxStars = 1500;
/// 対応が取れたとみなす最小の星の数
const int kMinMatches = 12;

NSError *MakeError(NSInteger code, NSString *message) {
    return [NSError errorWithDomain:@"StarAlignerDomain"
                               code:code
                           userInfo:@{NSLocalizedDescriptionKey : message}];
}

/// 線形輝度（CV_32F）から星（点光源）を検出する。
///
/// 地上の岩肌・木々の模様や灯りも局所的な明るい点を多く含むため、次の条件で星だけを残す。
/// - ノイズに比べて十分に明るい孤立点であること
/// - 周りが滑らか（夜空）であること。周り（中心を除いた範囲）の細かな模様の強さがノイズ程度
/// - 半値以上の範囲が小さい（街灯・ぼやけた光・明るい岩の縁のような広がった光ではない）こと
/// - 飽和していないこと
std::vector<Star> DetectStars(const cv::Mat &grayFull, const cv::Mat &skyMaskFull) {
    std::vector<Star> stars;
    if (grayFull.empty()) return stars;

    // 2x2 平均で縮小する（星の検出には十分な解像度で、ノイズも減り高速）
    cv::Mat small;
    cv::resize(grayFull, small, cv::Size(grayFull.cols / 2, grayFull.rows / 2), 0, 0, cv::INTER_AREA);
    if (small.cols < 16 || small.rows < 16) return stars;

    // トップハット: 星より大きな構造（空の明るさのむら・地上の大きな形）を取り除く
    cv::Mat kernel = cv::getStructuringElement(cv::MORPH_ELLIPSE, cv::Size(9, 9));
    cv::Mat top;
    cv::morphologyEx(small, top, cv::MORPH_TOPHAT, kernel);

    // 画像全体のノイズ（中央値絶対偏差）
    std::vector<float> samples;
    samples.reserve((size_t)(small.total() / 16 + 1));
    for (int y = 0; y < top.rows; y += 4) {
        const float *row = top.ptr<float>(y);
        for (int x = 0; x < top.cols; x += 4) samples.push_back(row[x]);
    }
    std::nth_element(samples.begin(), samples.begin() + samples.size() / 2, samples.end());
    const float median = samples[samples.size() / 2];
    for (float &v : samples) v = std::fabs(v - median);
    std::nth_element(samples.begin(), samples.begin() + samples.size() / 2, samples.end());
    double minValue = 0, maxValue = 0;
    cv::minMaxLoc(small, &minValue, &maxValue);
    // ノイズの無い画像（合成画像・量子化で平らな空）でも判定できるよう、最大値の 1/10000 を下限にする
    const float globalSigma = std::max((float)(maxValue * 1e-4) + 1e-6f, 1.4826f * samples[samples.size() / 2]);

    // 周りの細かな模様の強さ: 31x31 の範囲から中心の 7x7 を除き、背景からの差（ノイズの3倍で頭打ち）を平均する。
    // 頭打ちにするのは、近くの明るい星で値が大きくなり、星の多い天の川などを「模様」と誤判定しないため。
    // 夜空ではノイズ程度（約0.8倍）に収まり、岩肌・木々・建物など模様のある場所では大きくなる。
    cv::Mat deviation = cv::abs(top - median);
    cv::min(deviation, 3.0f * globalSigma, deviation);
    cv::Mat outerSum, innerSum;
    cv::boxFilter(deviation, outerSum, CV_32F, cv::Size(31, 31), cv::Point(-1, -1), false);
    cv::boxFilter(deviation, innerSum, CV_32F, cv::Size(7, 7), cv::Point(-1, -1), false);
    cv::Mat texture = (outerSum - innerSum) / (float)(31 * 31 - 7 * 7);

    cv::Mat dilated;
    cv::dilate(top, dilated, cv::getStructuringElement(cv::MORPH_RECT, cv::Size(5, 5)));

    const float saturation = (float)(maxValue * 0.98);

    const int border = 6;
    for (int y = border; y < top.rows - border; y++) {
        const float *topRow = top.ptr<float>(y);
        const float *dilRow = dilated.ptr<float>(y);
        const float *textureRow = texture.ptr<float>(y);
        const float *srcRow = small.ptr<float>(y);
        for (int x = border; x < top.cols - border; x++) {
            const float peak = topRow[x];
            if (peak <= 0 || peak < dilRow[x]) continue;
            if (peak - median < 5.0f * globalSigma) continue;
            // 周りに模様がある（岩肌・木々・建物など）なら地上の点とみなす
            if (textureRow[x] > 1.6f * globalSigma) continue;
            if (srcRow[x] >= saturation) continue;
            if (!skyMaskFull.empty()) {
                const int fx = std::min(skyMaskFull.cols - 1, x * 2), fy = std::min(skyMaskFull.rows - 1, y * 2);
                if (skyMaskFull.at<uchar>(fy, fx) == 0) continue;
            }

            // 半値以上の広がりと重心（11x11 の範囲）
            const float half = peak * 0.5f;
            int area = 0;
            double sum = 0, sx = 0, sy = 0;
            for (int dy = -5; dy <= 5; dy++) {
                const float *r = top.ptr<float>(y + dy);
                for (int dx = -5; dx <= 5; dx++) {
                    const float v = r[x + dx];
                    if (v >= half) area++;
                    if (std::abs(dx) <= 2 && std::abs(dy) <= 2 && v > 0) {
                        sum += v;
                        sx += v * (x + dx);
                        sy += v * (y + dy);
                    }
                }
            }
            if (area > 30 || sum <= 0) continue;

            // 縮小画像の画素 i は元画像の 2i〜2i+1 を覆うため、中心は 2i+0.5
            Star star;
            star.x = (float)(sx / sum) * 2.0f + 0.5f;
            star.y = (float)(sy / sum) * 2.0f + 0.5f;
            star.flux = (float)sum;
            stars.push_back(star);
        }
    }

    std::sort(stars.begin(), stars.end(), [](const Star &a, const Star &b) { return a.flux > b.flux; });
    if ((int)stars.size() > kMaxStars) stars.resize(kMaxStars);
    return stars;
}

// ─────────────────────────────────────────────
//  星の対応付け
// ─────────────────────────────────────────────

/// 基準の星を格子に振り分け、近傍の星を素早く探す
class StarGrid {
public:
    StarGrid(const std::vector<Star> &stars, float cellSize) : stars_(stars), cell_(cellSize) {
        for (size_t i = 0; i < stars.size(); i++) {
            cells_[Key(Cell(stars[i].x), Cell(stars[i].y))].push_back((int)i);
        }
    }

    /// (x, y) から radius 以内で最も近い星の番号（無ければ -1）
    int Nearest(float x, float y, float radius, float *distance) const {
        const int reach = (int)std::ceil(radius / cell_);
        const long cx = Cell(x), cy = Cell(y);
        int best = -1;
        float bestD2 = radius * radius;
        for (long gy = cy - reach; gy <= cy + reach; gy++) {
            for (long gx = cx - reach; gx <= cx + reach; gx++) {
                auto found = cells_.find(Key(gx, gy));
                if (found == cells_.end()) continue;
                for (int index : found->second) {
                    const float dx = stars_[index].x - x, dy = stars_[index].y - y;
                    const float d2 = dx * dx + dy * dy;
                    if (d2 <= bestD2) {
                        bestD2 = d2;
                        best = index;
                    }
                }
            }
        }
        if (distance) *distance = std::sqrt(bestD2);
        return best;
    }

private:
    long Cell(float v) const { return (long)std::floor(v / cell_); }
    static long long Key(long x, long y) { return ((long long)x << 32) ^ (long long)(y & 0xffffffff); }

    const std::vector<Star> &stars_;
    float cell_;
    std::unordered_map<long long, std::vector<int>> cells_;
};

cv::Point2f Project(const cv::Matx33d &h, float x, float y) {
    const double w = h(2, 0) * x + h(2, 1) * y + h(2, 2);
    if (std::fabs(w) < 1e-12) return cv::Point2f(-1e9f, -1e9f);
    return cv::Point2f((float)((h(0, 0) * x + h(0, 1) * y + h(0, 2)) / w),
                       (float)((h(1, 0) * x + h(1, 1) * y + h(1, 2)) / w));
}

/// 明るい星どうしの位置の差を投票し、最も多い平行移動を求める（初期値が無いとき用）。
/// 地上の点や偶然の組み合わせは票がばらけるため、空全体の動きが最多票になる。
bool VoteTranslation(const std::vector<Star> &target, const std::vector<Star> &base, cv::Point2d *shift) {
    const size_t nt = std::min<size_t>(target.size(), 250), nb = std::min<size_t>(base.size(), 250);
    const double bin = 4.0;
    std::unordered_map<long long, int> votes;
    long long bestKey = 0;
    int bestCount = 0;
    for (size_t i = 0; i < nt; i++) {
        for (size_t j = 0; j < nb; j++) {
            const long bx = (long)std::floor((base[j].x - target[i].x) / bin);
            const long by = (long)std::floor((base[j].y - target[i].y) / bin);
            // 隣の区間との境目で票が割れないよう、周囲の区間にも票を入れる
            for (long oy = 0; oy <= 1; oy++) {
                for (long ox = 0; ox <= 1; ox++) {
                    const long long key = ((long long)(bx - ox) << 32) ^ (long long)((by - oy) & 0xffffffff);
                    const int count = ++votes[key];
                    if (count > bestCount) {
                        bestCount = count;
                        bestKey = key;
                    }
                }
            }
        }
    }
    if (bestCount < 8) return false;
    const long kx = (long)(bestKey >> 32);
    const long ky = (long)(int)(bestKey & 0xffffffff);
    // 最多票の区間（2x2区間）に入る差の平均を取る
    double sx = 0, sy = 0;
    int n = 0;
    for (size_t i = 0; i < nt; i++) {
        for (size_t j = 0; j < nb; j++) {
            const double dx = base[j].x - target[i].x, dy = base[j].y - target[i].y;
            if (dx >= kx * bin && dx < (kx + 2) * bin && dy >= ky * bin && dy < (ky + 2) * bin) {
                sx += dx;
                sy += dy;
                n++;
            }
        }
    }
    if (n == 0) return false;
    *shift = cv::Point2d(sx / n, sy / n);
    return true;
}

/// 変換 h で写した対象の星と基準の星を、互いに最も近いものどうしで対応付ける
void MatchStars(const std::vector<Star> &target, const std::vector<Star> &base, const StarGrid &grid,
                const cv::Matx33d &h, float radius,
                std::vector<cv::Point2f> *fromPoints, std::vector<cv::Point2f> *toPoints) {
    fromPoints->clear();
    toPoints->clear();
    std::vector<int> nearestOfTarget(target.size(), -1);
    std::vector<float> distanceOfTarget(target.size(), 0);
    std::vector<int> bestTargetOfBase(base.size(), -1);
    std::vector<float> bestDistanceOfBase(base.size(), radius + 1);
    for (size_t i = 0; i < target.size(); i++) {
        const cv::Point2f p = Project(h, target[i].x, target[i].y);
        float d = 0;
        const int j = grid.Nearest(p.x, p.y, radius, &d);
        if (j < 0) continue;
        nearestOfTarget[i] = j;
        distanceOfTarget[i] = d;
        if (d < bestDistanceOfBase[j]) {
            bestDistanceOfBase[j] = d;
            bestTargetOfBase[j] = (int)i;
        }
    }
    for (size_t i = 0; i < target.size(); i++) {
        const int j = nearestOfTarget[i];
        if (j < 0 || bestTargetOfBase[j] != (int)i) continue;
        fromPoints->push_back(cv::Point2f(target[i].x, target[i].y));
        toPoints->push_back(cv::Point2f(base[j].x, base[j].y));
    }
}

/// 初期値 h から、探索半径を狭めながら対応付けとホモグラフィ推定を繰り返す
bool Refine(const std::vector<Star> &target, const std::vector<Star> &base, const StarGrid &grid,
            cv::Matx33d *h, NSError **error) {
    const float radii[] = {40.0f, 12.0f, 4.0f};
    std::vector<cv::Point2f> from, to;
    for (float radius : radii) {
        MatchStars(target, base, grid, *h, radius, &from, &to);
        if ((int)from.size() < kMinMatches) {
            if (error) {
                *error = MakeError(3, [NSString stringWithFormat:@"星の対応が取れませんでした（対応した星 %d 個）",
                                                                 (int)from.size()]);
            }
            return false;
        }
        cv::Mat inliers;
        cv::Mat estimated = cv::findHomography(from, to, cv::RANSAC, std::max(1.5, radius * 0.25), inliers, 5000, 0.999);
        if (estimated.empty() || cv::countNonZero(inliers) < kMinMatches) {
            if (error) *error = MakeError(4, @"星の対応から変換を計算できませんでした");
            return false;
        }
        // 最後は外れ値を除いた星すべてで最小二乗に当てはめ直す
        if (radius == radii[2]) {
            std::vector<cv::Point2f> inFrom, inTo;
            for (int k = 0; k < inliers.rows; k++) {
                if (inliers.at<uchar>(k)) {
                    inFrom.push_back(from[k]);
                    inTo.push_back(to[k]);
                }
            }
            cv::Mat leastSquares = cv::findHomography(inFrom, inTo, 0);
            if (!leastSquares.empty()) estimated = leastSquares;
        }
        estimated.convertTo(estimated, CV_64F);
        *h = cv::Matx33d((const double *)estimated.ptr<double>());
    }
    return true;
}

cv::Mat MatFromGray(NSData *gray, NSInteger width, NSInteger height) {
    if (width <= 0 || height <= 0 || gray.length < (NSUInteger)(width * height) * sizeof(float)) return cv::Mat();
    return cv::Mat((int)height, (int)width, CV_32F, (void *)gray.bytes);
}

cv::Mat MaskFromData(NSData *mask, NSInteger width, NSInteger height) {
    if (!mask || mask.length < (NSUInteger)(width * height)) return cv::Mat();
    return cv::Mat((int)height, (int)width, CV_8U, (void *)mask.bytes).clone();
}

/// 画像ファイルを線形に近い輝度（CV_32F）として読む
cv::Mat LoadGray(NSURL *url) {
    cv::Mat image = cv::imread(url.path.UTF8String, cv::IMREAD_UNCHANGED);
    if (image.empty()) return cv::Mat();
    if (image.channels() == 4) cv::cvtColor(image, image, cv::COLOR_BGRA2BGR);
    cv::Mat gray;
    if (image.channels() == 3) {
        cv::cvtColor(image, gray, cv::COLOR_BGR2GRAY);
    } else {
        gray = image;
    }
    gray.convertTo(gray, CV_32F);
    return gray;
}

NSArray<NSNumber *> *ArrayFromMatrix(const cv::Matx33d &h) {
    NSMutableArray<NSNumber *> *values = [NSMutableArray arrayWithCapacity:9];
    for (int row = 0; row < 3; row++) {
        for (int col = 0; col < 3; col++) [values addObject:@(h(row, col))];
    }
    return values;
}

}  // namespace

@implementation StarAligner {
    std::vector<Star> _baseStars;
    NSInteger _width;
    NSInteger _height;
}

- (nullable instancetype)initWithBaseGray:(NSData *)gray
                                    width:(NSInteger)width
                                   height:(NSInteger)height
                                  skyMask:(nullable NSData *)skyMask
                                    error:(NSError **)error {
    self = [super init];
    if (!self) return nil;
    cv::Mat image = MatFromGray(gray, width, height);
    if (image.empty()) {
        if (error) *error = MakeError(1, @"位置合わせ用の画素データが不正です");
        return nil;
    }
    _width = width;
    _height = height;
    _baseStars = DetectStars(image, MaskFromData(skyMask, width, height));
    if ((int)_baseStars.size() < kMinMatches) {
        if (error) {
            *error = MakeError(2, [NSString stringWithFormat:@"基準画像で星が十分に見つかりませんでした（%d 個）",
                                                             (int)_baseStars.size()]);
        }
        return nil;
    }
    return self;
}

- (nullable instancetype)initWithBaseImageAtURL:(NSURL *)url
                                        skyMask:(nullable NSData *)skyMask
                                          error:(NSError **)error {
    cv::Mat gray = LoadGray(url);
    if (gray.empty()) {
        if (error) *error = MakeError(1, @"画像を読み込めませんでした");
        return nil;
    }
    if (!gray.isContinuous()) gray = gray.clone();
    NSData *data = [NSData dataWithBytesNoCopy:gray.data length:gray.total() * sizeof(float) freeWhenDone:NO];
    return [self initWithBaseGray:data width:gray.cols height:gray.rows skyMask:skyMask error:error];
}

- (NSInteger)baseStarCount {
    return (NSInteger)_baseStars.size();
}

- (NSInteger)width {
    return _width;
}

- (NSInteger)height {
    return _height;
}

- (nullable NSArray<NSNumber *> *)homographyFromGray:(NSData *)gray
                                        initialGuess:(nullable NSArray<NSNumber *> *)initialGuess
                                               error:(NSError **)error {
    cv::Mat image = MatFromGray(gray, _width, _height);
    if (image.empty()) {
        if (error) *error = MakeError(1, @"位置合わせ用の画素データが不正です");
        return nil;
    }
    // 対象画像は空の範囲を限定しない（地上の点は基準の星と対応しないため、対応付けで除かれる）
    const std::vector<Star> targetStars = DetectStars(image, cv::Mat());
    if ((int)targetStars.size() < kMinMatches) {
        if (error) {
            *error = MakeError(2, [NSString stringWithFormat:@"星が十分に見つかりませんでした（%d 個）",
                                                             (int)targetStars.size()]);
        }
        return nil;
    }
    StarGrid grid(_baseStars, 8.0f);

    // 予想（隣のフレームの結果）から始め、だめなら投票で求めた平行移動から始める
    if (initialGuess.count == 9) {
        cv::Matx33d h;
        for (int i = 0; i < 9; i++) h(i / 3, i % 3) = initialGuess[i].doubleValue;
        if (Refine(targetStars, _baseStars, grid, &h, nil)) return ArrayFromMatrix(h);
    }
    cv::Point2d shift;
    if (!VoteTranslation(targetStars, _baseStars, &shift)) {
        if (error) *error = MakeError(3, @"星の対応が取れませんでした");
        return nil;
    }
    cv::Matx33d h(1, 0, shift.x, 0, 1, shift.y, 0, 0, 1);
    if (!Refine(targetStars, _baseStars, grid, &h, error)) return nil;
    return ArrayFromMatrix(h);
}

- (nullable NSArray<NSNumber *> *)homographyForImageAtURL:(NSURL *)url
                                             initialGuess:(nullable NSArray<NSNumber *> *)initialGuess
                                                    error:(NSError **)error {
    cv::Mat gray = LoadGray(url);
    if (gray.empty() || gray.cols != _width || gray.rows != _height) {
        if (error) *error = MakeError(1, @"位置合わせする画像を読み込めないか、基準画像と大きさが違います");
        return nil;
    }
    if (!gray.isContinuous()) gray = gray.clone();
    NSData *data = [NSData dataWithBytesNoCopy:gray.data length:gray.total() * sizeof(float) freeWhenDone:NO];
    return [self homographyFromGray:data initialGuess:initialGuess error:error];
}

@end

// ─────────────────────────────────────────────
//  タイムラプスの揺れ補正（星を除いた地上の風景で合わせる）
// ─────────────────────────────────────────────

namespace {

/// 特徴点を探す画像の長辺（揺れ補正には十分で、フル解像度より大幅に速い）
const int kStabilizerMaxSide = 1600;

/// 薄明から夜まで明るさが変わっても特徴点が安定して取れるよう、明るさの分布で 8bit に揃える
cv::Mat NormalizeForFeatures(const cv::Mat &gray) {
    std::vector<float> samples;
    samples.reserve(gray.total() / 16 + 1);
    for (int y = 0; y < gray.rows; y += 4) {
        const float *row = gray.ptr<float>(y);
        for (int x = 0; x < gray.cols; x += 4) samples.push_back(row[x]);
    }
    const size_t lowIndex = samples.size() / 200, highIndex = samples.size() - 1 - samples.size() / 200;
    std::nth_element(samples.begin(), samples.begin() + lowIndex, samples.end());
    const float low = samples[lowIndex];
    std::nth_element(samples.begin(), samples.begin() + highIndex, samples.end());
    const float high = std::max(low + 1e-6f, samples[highIndex]);
    cv::Mat scaled = (gray - low) / (high - low);
    cv::max(scaled, 0.0, scaled);
    cv::min(scaled, 1.0, scaled);
    cv::sqrt(scaled, scaled);  // 暗い地上の模様も拾えるよう持ち上げる
    cv::Mat result;
    scaled.convertTo(result, CV_8U, 255.0);
    return result;
}

}  // namespace

@implementation TimelapseStabilizer {
    cv::Mat _previousDescriptors;
    std::vector<cv::KeyPoint> _previousKeypoints;
    cv::Size _previousSize;
    cv::Matx33d _cumulative;
    bool _hasPrevious;
    NSInteger _failedFrameCount;
}

- (instancetype)init {
    self = [super init];
    if (self) {
        _cumulative = cv::Matx33d::eye();
        _hasPrevious = false;
        _failedFrameCount = 0;
    }
    return self;
}

- (NSInteger)failedFrameCount {
    return _failedFrameCount;
}

- (nullable NSArray<NSNumber *> *)homographyForImageAtURL:(NSURL *)url error:(NSError **)error {
    cv::Mat gray = LoadGray(url);
    if (gray.empty()) {
        if (error) *error = MakeError(1, @"画像を読み込めませんでした");
        return nil;
    }
    const double scale = std::min(1.0, (double)kStabilizerMaxSide / (double)std::max(gray.cols, gray.rows));
    cv::Mat small;
    if (scale < 1.0) {
        cv::resize(gray, small, cv::Size(), scale, scale, cv::INTER_AREA);
    } else {
        small = gray;
    }

    // 星（日周運動で地上と違う動きをする）の周りを特徴点の対象から外す
    cv::Mat mask(small.size(), CV_8U, cv::Scalar(255));
    for (const Star &star : DetectStars(small, cv::Mat())) {
        cv::circle(mask, cv::Point(cvRound(star.x), cvRound(star.y)), 6, cv::Scalar(0), cv::FILLED);
    }

    // 高感度の夜空のノイズが特徴点にならないよう、軽くぼかしてから探し、強い特徴点だけを使う
    cv::Mat normalized = NormalizeForFeatures(small);
    cv::GaussianBlur(normalized, normalized, cv::Size(0, 0), 1.5);
    cv::Ptr<cv::AKAZE> akaze = cv::AKAZE::create();
    std::vector<cv::KeyPoint> keypoints;
    akaze->detect(normalized, keypoints, mask);
    cv::KeyPointsFilter::retainBest(keypoints, 4000);
    cv::Mat descriptors;
    akaze->compute(normalized, keypoints, descriptors);

    if (_hasPrevious && small.size() == _previousSize) {
        bool matched = false;
        if (!descriptors.empty() && !_previousDescriptors.empty()) {
            cv::BFMatcher matcher(cv::NORM_HAMMING, true);
            std::vector<cv::DMatch> matches;
            matcher.match(descriptors, _previousDescriptors, matches);
            if (matches.size() >= 15) {
                std::vector<cv::Point2f> from, to;
                for (const cv::DMatch &m : matches) {
                    from.push_back(keypoints[m.queryIdx].pt);
                    to.push_back(_previousKeypoints[m.trainIdx].pt);
                }
                cv::Mat inliers;
                cv::Mat h = cv::findHomography(from, to, cv::RANSAC, 2.0, inliers, 5000, 0.999);
                const int inlierCount = inliers.empty() ? 0 : cv::countNonZero(inliers);
                if (!h.empty() && inlierCount >= 15 && inlierCount >= (int)(matches.size() * 0.2)) {
                    h.convertTo(h, CV_64F);
                    const cv::Matx33d stepSmall((const double *)h.ptr<double>());
                    // 縮小画像での変換を元の解像度へ戻す: H = S^-1 * h * S（S は縮小倍率）
                    const cv::Matx33d s(scale, 0, 0, 0, scale, 0, 0, 0, 1);
                    const cv::Matx33d sInverse(1.0 / scale, 0, 0, 0, 1.0 / scale, 0, 0, 0, 1);
                    const cv::Matx33d step = sInverse * stepSmall * s;
                    // 隣のフレームとの差として大きすぎる動き（画像幅の2割超）は誤推定とみなす
                    const cv::Point2f center = Project(step, gray.cols * 0.5f, gray.rows * 0.5f);
                    if (std::hypot(center.x - gray.cols * 0.5f, center.y - gray.rows * 0.5f) < gray.cols * 0.2) {
                        _cumulative = _cumulative * step;
                        matched = true;
                    }
                }
            }
        }
        if (!matched) _failedFrameCount++;
    } else if (_hasPrevious) {
        // 大きさの違うフレームは合わせられない
        _failedFrameCount++;
    }

    _previousKeypoints = keypoints;
    _previousDescriptors = descriptors;
    _previousSize = small.size();
    _hasPrevious = true;
    return ArrayFromMatrix(_cumulative);
}

@end
