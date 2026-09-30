#import <opencv2/core.hpp>
#import <opencv2/imgproc.hpp>
#import <algorithm>
#import <cmath>
#import <vector>

#import "Nightscape.h"

namespace {

/// 空と地上を判定する画像の長辺（GrabCut の計算量を抑える）
const int kAnalysisMaxSide = 1000;
/// 境界を画像の輪郭に沿わせる（ガイドフィルタ）ときの画像の長辺
const int kGuideMaxSide = 3000;
/// 判定用の画像から細かな構造（星や模様）を取り出すときに除く、なだらかな明るさのぼかしの大きさ（判定用の解像度のpx）
const double kDetailSigma = 2.0;
/// GrabCut の乱数の種（同じ入力なら毎回同じ判定にする）
const uint64_t kGrabCutSeed = 0x4E6967687473ULL;
/// 塗った手がかりの縁の幅（判定用の画像の長辺に対する割合）。縁は「おそらくその側」として本当の境界に吸い付かせる
const double kHintRimFraction = 0.02;
/// 空の手がかりどうしをつなぐ距離（判定用の画像の長辺に対する割合）。これでつないで上辺に届かず、面積も小さいものは除く
const double kSkySeedLinkFraction = 0.02;
/// 上辺に届かなくても空の手がかりとして残す面積（判定用の画像に対する割合）
const double kSkySeedMinimumArea = 0.005;

NSError *NightscapeError(NSInteger code, NSString *message) {
    return [NSError errorWithDomain:@"NightscapeDomain" code:code userInfo:@{NSLocalizedDescriptionKey : message}];
}

cv::Matx33d MatrixFromArray(NSArray<NSNumber *> *values) {
    cv::Matx33d m = cv::Matx33d::eye();
    if (values.count != 9) return m;
    for (int i = 0; i < 9; i++) m(i / 3, i % 3) = values[i].doubleValue;
    return m;
}

/// 元の解像度の変換を、scale 倍に縮小した画像の変換にする（S * H * S^-1）
cv::Matx33d ScaleHomography(const cv::Matx33d &h, double scale) {
    const cv::Matx33d s(scale, 0, 0, 0, scale, 0, 0, 0, 1);
    const cv::Matx33d sInverse(1.0 / scale, 0, 0, 0, 1.0 / scale, 0, 0, 0, 1);
    return s * h * sInverse;
}

/// 変換 h で基準画像の座標へ移し、画像の内側だった画素を1とする
cv::Mat WarpValidity(const cv::Size &size, const cv::Matx33d &h) {
    cv::Mat ones(size, CV_32F, cv::Scalar(1));
    cv::Mat warped;
    cv::warpPerspective(ones, warped, h, size, cv::INTER_LINEAR, cv::BORDER_CONSTANT, cv::Scalar(0));
    cv::Mat valid;
    cv::threshold(warped, valid, 0.999, 1.0, cv::THRESH_BINARY);
    return valid;
}

/// 暗い夜空でも輪郭が見えるよう、明るさの分布で 0〜1 に揃えて持ち上げる（asinh）
cv::Mat StretchForDisplay(const cv::Mat &image) {
    std::vector<float> samples;
    samples.reserve(image.total() * image.channels() / 7 + 1);
    const float *data = image.ptr<float>();
    const size_t count = image.total() * image.channels();
    for (size_t i = 0; i < count; i += 7) samples.push_back(data[i]);
    if (samples.empty()) return image.clone();
    const size_t lowIndex = samples.size() / 100, highIndex = samples.size() - 1 - samples.size() / 500;
    std::nth_element(samples.begin(), samples.begin() + lowIndex, samples.end());
    const float low = samples[lowIndex];
    std::nth_element(samples.begin(), samples.begin() + highIndex, samples.end());
    const float high = std::max(low + 1e-6f, samples[highIndex]);
    cv::Mat normalized = (image - low) / (high - low);
    cv::max(normalized, 0.0, normalized);
    cv::min(normalized, 1.0, normalized);
    cv::Mat stretched(normalized.size(), normalized.type());
    const float k = 10.0f, denominator = std::asinh(k);
    const float *src = normalized.ptr<float>();
    float *dst = stretched.ptr<float>();
    const size_t total = normalized.total() * normalized.channels();
    for (size_t i = 0; i < total; i++) dst[i] = std::asinh(src[i] * k) / denominator;
    return stretched;
}

/// 星や星の軌跡のような、明るく細い構造を取り除く（オープニング）。
/// 暗い細い構造（空を背にした木の幹・枝）は残るため、空と地上の輪郭は保たれる。
cv::Mat RemoveBrightThinStructures(const cv::Mat &image, int size) {
    cv::Mat opened;
    cv::morphologyEx(image, opened, cv::MORPH_OPEN, cv::getStructuringElement(cv::MORPH_ELLIPSE, cv::Size(size, size)));
    return opened;
}

float Median(const cv::Mat &image) {
    std::vector<float> values(image.begin<float>(), image.end<float>());
    if (values.empty()) return 0;
    std::nth_element(values.begin(), values.begin() + values.size() / 2, values.end());
    return values[values.size() / 2];
}

/// 小さな飛び地（全体の割合 minFraction 未満の連結領域）を反対側に塗り替える
void RemoveSmallIslands(cv::Mat &binary, double minFraction) {
    const double minArea = binary.total() * minFraction;
    for (int pass = 0; pass < 2; pass++) {
        cv::Mat target = pass == 0 ? binary.clone() : (255 - binary);
        cv::Mat labels, stats, centroids;
        const int count = cv::connectedComponentsWithStats(target, labels, stats, centroids, 8);
        for (int label = 1; label < count; label++) {
            if (stats.at<int>(label, cv::CC_STAT_AREA) >= minArea) continue;
            binary.setTo(pass == 0 ? 0 : 255, labels == label);
        }
    }
}

/// カラー画像を案内にしたガイドフィルタ（色の違いで境界を決める。明るさが同じでも色が違えば分かれる）
cv::Mat ColorGuidedFilter(const cv::Mat &guide, const cv::Mat &p, int radius, double eps) {
    const cv::Size window(2 * radius + 1, 2 * radius + 1);
    std::vector<cv::Mat> I;
    cv::split(guide, I);
    cv::Mat meanP;
    cv::boxFilter(p, meanP, CV_32F, window);
    cv::Mat meanI[3], covIP[3];
    for (int c = 0; c < 3; c++) {
        cv::boxFilter(I[c], meanI[c], CV_32F, window);
        cv::Mat corr;
        cv::boxFilter(I[c].mul(p), corr, CV_32F, window);
        covIP[c] = corr - meanI[c].mul(meanP);
    }
    cv::Mat var[3][3];
    for (int i = 0; i < 3; i++) {
        for (int j = i; j < 3; j++) {
            cv::Mat corr;
            cv::boxFilter(I[i].mul(I[j]), corr, CV_32F, window);
            var[i][j] = corr - meanI[i].mul(meanI[j]);
            if (i != j) var[j][i] = var[i][j];
        }
    }
    cv::Mat a[3] = {cv::Mat(p.size(), CV_32F), cv::Mat(p.size(), CV_32F), cv::Mat(p.size(), CV_32F)};
    cv::parallel_for_(cv::Range(0, p.rows), [&](const cv::Range &rows) {
        for (int y = rows.start; y < rows.end; y++) {
            for (int x = 0; x < p.cols; x++) {
                cv::Matx33d sigma;
                for (int i = 0; i < 3; i++) {
                    for (int j = 0; j < 3; j++) sigma(i, j) = var[i][j].at<float>(y, x) + (i == j ? eps : 0);
                }
                const cv::Vec3d cov(covIP[0].at<float>(y, x), covIP[1].at<float>(y, x), covIP[2].at<float>(y, x));
                const cv::Vec3d coefficient = sigma.inv() * cov;
                for (int c = 0; c < 3; c++) a[c].at<float>(y, x) = (float)coefficient[c];
            }
        }
    });
    cv::Mat b = meanP.clone();
    for (int c = 0; c < 3; c++) b -= a[c].mul(meanI[c]);
    cv::Mat q;
    cv::boxFilter(b, q, CV_32F, window);
    for (int c = 0; c < 3; c++) {
        cv::Mat meanA;
        cv::boxFilter(a[c], meanA, CV_32F, window);
        q += meanA.mul(I[c]);
    }
    return q;
}

/// 空の手がかり（255）のうち、link px の範囲でつないだとき画面の上辺に届くか、面積が十分にあるものだけを残す
cv::Mat KeepConnectedSky(const cv::Mat &seedSky, int link) {
    cv::Mat joined;
    cv::dilate(seedSky, joined, cv::getStructuringElement(cv::MORPH_ELLIPSE, cv::Size(2 * link + 1, 2 * link + 1)));
    cv::Mat labels;
    const int count = cv::connectedComponents(joined, labels, 8, CV_32S);
    std::vector<int> area(count, 0);
    std::vector<bool> keep(count, false);
    for (int y = 0; y < seedSky.rows; y++) {
        const uchar *seed = seedSky.ptr<uchar>(y);
        const int *label = labels.ptr<int>(y);
        for (int x = 0; x < seedSky.cols; x++) if (seed[x]) area[label[x]]++;
    }
    const int *top = labels.ptr<int>(0);
    for (int x = 0; x < seedSky.cols; x++) keep[top[x]] = true;
    const double minimumArea = kSkySeedMinimumArea * (double)seedSky.total();
    for (int i = 1; i < count; i++) if (area[i] >= minimumArea) keep[i] = true;
    keep[0] = false;
    cv::Mat result = cv::Mat::zeros(seedSky.size(), CV_8U);
    for (int y = 0; y < seedSky.rows; y++) {
        const uchar *seed = seedSky.ptr<uchar>(y);
        const int *label = labels.ptr<int>(y);
        uchar *out = result.ptr<uchar>(y);
        for (int x = 0; x < seedSky.cols; x++) if (seed[x] && keep[label[x]]) out[x] = 255;
    }
    return result;
}

/// 空と地上の手がかりから、画像の輪郭を壁にして塗り広げる（分水嶺）。空の割合 255 を返す。
/// 地上はふつう画面の下辺に、空は上辺につながるため、下辺（空の手がかりの所を除く）を地上、上辺（地上の手がかりの
/// 近くを除く）を空の起点にも加える。手がかりの無い所は、輪郭を越えずにたどり着ける側になる
cv::Mat FloodFromSeeds(const cv::Mat &image8, const cv::Mat &seedSky, const cv::Mat &seedGround) {
    const int rows = seedSky.rows, cols = seedSky.cols;
    cv::Mat markers = cv::Mat::zeros(seedSky.size(), CV_32S);
    markers.setTo(1, seedSky & ~seedGround);
    markers.setTo(2, seedGround);
    const int edge = std::max(1, (int)std::lround(0.002 * std::max(rows, cols)));
    const cv::Rect bottom(0, rows - edge, cols, edge), top(0, 0, cols, edge);
    cv::Mat bottomMarkers = markers(bottom);
    bottomMarkers.setTo(2, seedSky(bottom) == 0);
    cv::Mat nearGround;
    const int reach = std::max(2, (int)std::lround(0.01 * std::max(rows, cols)));
    cv::dilate(seedGround, nearGround, cv::getStructuringElement(cv::MORPH_ELLIPSE, cv::Size(2 * reach + 1, 2 * reach + 1)));
    cv::Mat topMarkers = markers(top);
    topMarkers.setTo(1, (topMarkers == 0) & (nearGround(top) == 0));
    cv::watershed(image8, markers);
    cv::Mat sky = markers == 1;
    // 分水嶺の境界（-1）は、まわりに空があれば空にする
    cv::Mat border = markers == -1, grown;
    cv::dilate(sky, grown, cv::Mat::ones(3, 3, CV_8U));
    grown.copyTo(sky, border);
    return sky;
}

/// 塗った手がかり（255）の内側（縁を rim px 除いた所）。keepThin なら、縁を除くと消えてしまう細い塗りはそのまま残す
cv::Mat HintCore(const cv::Mat &painted, int rim, bool keepThin) {
    cv::Mat core;
    cv::erode(painted, core, cv::getStructuringElement(cv::MORPH_ELLIPSE, cv::Size(2 * rim + 1, 2 * rim + 1)));
    if (!keepThin) return core;
    cv::Mat labels;
    const int count = cv::connectedComponents(painted, labels, 8, CV_32S);
    std::vector<bool> hasCore(count, false);
    for (int y = 0; y < core.rows; y++) {
        const uchar *c = core.ptr<uchar>(y);
        const int *l = labels.ptr<int>(y);
        for (int x = 0; x < core.cols; x++) if (c[x]) hasCore[l[x]] = true;
    }
    for (int y = 0; y < core.rows; y++) {
        uchar *c = core.ptr<uchar>(y);
        const int *l = labels.ptr<int>(y);
        for (int x = 0; x < core.cols; x++) if (l[x] > 0 && !hasCore[l[x]]) c[x] = 255;
    }
    return core;
}

/// 境界から band px 以内だけを、高い解像度の色と輪郭で決め直す（GrabCut を境界を含む小さな区画ごとに行う）。
/// 区画ごとに色の分布を学ぶため、水平線の空と海のように全体では似た色でも、その場所での違いで分けられる。
/// fixedSky・fixedGround（255）は決め直さない
cv::Mat RefineBoundaryInTiles(const cv::Mat &guide01, const cv::Mat &binarySky, const cv::Mat &fixedSky,
                              const cv::Mat &fixedGround, int band) {
    cv::Mat image;
    guide01.convertTo(image, CV_8UC3, 255.0);
    cv::Mat nearBoundary;
    cv::morphologyEx(binarySky, nearBoundary, cv::MORPH_GRADIENT,
                     cv::getStructuringElement(cv::MORPH_ELLIPSE, cv::Size(2 * band + 1, 2 * band + 1)));
    nearBoundary.setTo(0, fixedSky | fixedGround);
    cv::Mat refined = binarySky.clone();
    const int tile = 384, margin = 48;
    std::vector<cv::Rect> tiles;
    for (int y = 0; y < binarySky.rows; y += tile) {
        for (int x = 0; x < binarySky.cols; x += tile) {
            const cv::Rect inner(x, y, std::min(tile, binarySky.cols - x), std::min(tile, binarySky.rows - y));
            if (cv::countNonZero(nearBoundary(inner)) > 0) tiles.push_back(inner);
        }
    }
    cv::parallel_for_(cv::Range(0, (int)tiles.size()), [&](const cv::Range &range) {
        for (int t = range.start; t < range.end; t++) {
            const cv::Rect inner = tiles[t];
            const cv::Rect outer = cv::Rect(inner.x - margin, inner.y - margin, inner.width + 2 * margin,
                                            inner.height + 2 * margin) & cv::Rect(0, 0, binarySky.cols, binarySky.rows);
            const cv::Mat sky = binarySky(outer), open = nearBoundary(outer);
            cv::Mat mask(outer.size(), CV_8U);
            mask.setTo(cv::GC_BGD);
            mask.setTo(cv::GC_FGD, sky);
            mask.setTo(cv::GC_PR_BGD, open & ~sky);
            mask.setTo(cv::GC_PR_FGD, open & sky);
            mask.setTo(cv::GC_FGD, fixedSky(outer));
            mask.setTo(cv::GC_BGD, fixedGround(outer));
            // 区画に空と地上の両方が無いと色の分布を学べない
            if (cv::countNonZero(sky) == 0 || cv::countNonZero(sky) == (int)sky.total()) continue;
            cv::Mat backgroundModel, foregroundModel;
            // GrabCut の色の分布の初期化は乱数を使うため、毎回同じ結果になるよう種を固定する
            cv::theRNG().state = kGrabCutSeed + (uint64_t)t;
            cv::grabCut(image(outer), mask, cv::Rect(), backgroundModel, foregroundModel, 3, cv::GC_INIT_WITH_MASK);
            const cv::Mat result = (mask == cv::GC_FGD) | (mask == cv::GC_PR_FGD);
            result(cv::Rect(inner.x - outer.x, inner.y - outer.y, inner.width, inner.height)).copyTo(refined(inner));
        }
    });
    refined.setTo(255, fixedSky);
    refined.setTo(0, fixedGround);
    return refined;
}

/// 地上の手がかり（255）から、星に合わせたときに地上が通り過ぎて紛れ込んだ空（稜線の上の「炎」）を除く。
/// 星に合わせた座標 x には、各フレームで地上に合わせた座標 R_k x（relative）の景色が写るため、手がかりは
/// 本当の地上 G を R_k の逆向きに広げたもの（x について R_k x が G に入るフレームがある）になる。
/// 同じずれで縮める（seed(R_k^-1 x) がすべてのフレームで手がかりのままの画素だけ残す）と G に戻る。
/// ずれの向きだけ縮めるので、基準画像が撮影の端（ずれが片側だけ大きい）でも反対側の地上を削らない。
/// 画像の外は手がかりとみなす（縁で縮めすぎない）
cv::Mat ErodeByRelativeMotion(const cv::Mat &seed, const std::vector<cv::Matx33d> &relative) {
    cv::Mat result = seed.clone(), moved;
    for (const cv::Matx33d &r : relative) {
        // moved(x) = seed(R^-1 * x)
        cv::warpPerspective(seed, moved, r.inv(), seed.size(), cv::INTER_NEAREST | cv::WARP_INVERSE_MAP,
                            cv::BORDER_CONSTANT, cv::Scalar(255));
        cv::min(result, moved, result);
    }
    return result;
}

/// 光害フレームのなだらかさ（長辺に対する割合）。手作業の見本（長辺5496px）の光害フレームのマスクは、地上との
/// 境界からの距離 100px で0.83、300pxで0.60、500pxで0.36、700pxで0.18、1000pxで0.05 と、ほぼ σ=長辺の6.5% の
/// ガウス型で弱まっていた
const double kLightPollutionSigma = 0.065;

/// 光害フレームを重ねる強さ（float32）。地上（空の割合0.5未満）との境界で1、空の奥へ向かってガウス型で0へ。
/// 地平線付近の光害や大気の明るさは地上に対して動かないため、地上に合わせた星のない空から持ってくる
cv::Mat LightPollutionWeight(const cv::Mat &skyAlpha) {
    const int longSide = std::max(skyAlpha.cols, skyAlpha.rows);
    // 計算量を抑えるため縮小して距離を求める（なだらかな重みなので縮小で十分）
    const double scale = std::min(1.0, 1000.0 / longSide);
    cv::Mat small;
    cv::resize(skyAlpha, small, cv::Size(), scale, scale, cv::INTER_AREA);
    cv::Mat sky = small >= 0.5f;
    cv::Mat distance;
    cv::distanceTransform(sky, distance, cv::DIST_L2, cv::DIST_MASK_PRECISE);
    const double sigma = kLightPollutionSigma * longSide * scale;
    cv::Mat weight;
    cv::multiply(distance, distance, weight, -1.0 / (2.0 * sigma * sigma));
    cv::exp(weight, weight);
    cv::resize(weight, weight, skyAlpha.size(), 0, 0, cv::INTER_LINEAR);
    return weight;
}

/// 空と地上の境界付近だけで色の違いが効くよう、明るさの重みを下げた Lab 色空間（8bit）にする
cv::Mat HueWeightedLab(const cv::Mat &rgb01) {
    cv::Mat lab;
    cv::cvtColor(rgb01, lab, cv::COLOR_RGB2Lab);  // L: 0〜100, a・b: おおむね -127〜127
    std::vector<cv::Mat> channels;
    cv::split(lab, channels);
    channels[0] = channels[0] * (0.5 * 255.0 / 100.0);
    channels[1] = channels[1] + 128.0;
    channels[2] = channels[2] + 128.0;
    cv::Mat merged, result;
    cv::merge(channels, merged);
    merged.convertTo(result, CV_8UC3);
    return result;
}

}  // namespace

@interface NightscapeMask ()
- (instancetype)initWithSkyAlpha:(NSData *)skyAlpha width:(NSInteger)width height:(NSInteger)height
                  hasBothRegions:(BOOL)hasBothRegions skyMargin:(int)skyMargin;
@property (nonatomic, readwrite) NSData *skyAlpha;
@end

// ─────────────────────────────────────────────
//  判定結果
// ─────────────────────────────────────────────

@implementation NightscapeMask

- (instancetype)initWithSkyAlpha:(NSData *)skyAlpha width:(NSInteger)width height:(NSInteger)height {
    return [self initWithSkyAlpha:skyAlpha width:width height:height hasBothRegions:YES skyMargin:2];
}

- (instancetype)initWithSkyAlpha:(NSData *)skyAlpha width:(NSInteger)width height:(NSInteger)height
                  hasBothRegions:(BOOL)hasBothRegions skyMargin:(int)skyMargin {
    self = [super init];
    if (!self) return nil;
    _width = width;
    _height = height;
    _skyAlpha = [skyAlpha copy];
    cv::Mat alpha((int)height, (int)width, CV_32F, (void *)_skyAlpha.bytes);
    // 空は星に合わせて各フレームを動かすため、境界の近くでは地上が紛れ込みやすい（紛れ込むと空に稜線の影が出る）。
    // 合成に使う空の範囲は、半分以上空の範囲から skyMargin px 内側にする（判定の解像度で1画素ずれても
    // 地上が入らない幅）。境界のなじませ部分（alpha が中間）にも空のデータを残し、継ぎ目の星を薄くしない。
    // 地上は地上に合わせて重ねる（フレームごとに境界が動かない）ため、半分以上地上の画素をすべて使う。
    cv::Mat kernel = cv::getStructuringElement(cv::MORPH_ELLIPSE, cv::Size(2 * skyMargin + 1, 2 * skyMargin + 1));
    cv::Mat sky = alpha >= 0.5f, ground = alpha < 0.5f;
    cv::erode(sky, sky, kernel);
    _certainSky = [NSData dataWithBytes:sky.data length:sky.total()];
    _certainGround = [NSData dataWithBytes:ground.data length:ground.total()];
    _hasBothRegions = hasBothRegions && cv::countNonZero(sky) > 0 && cv::countNonZero(ground) > 0;
    return self;
}

- (NightscapeMask *)maskByFeatheringWithRadius:(double)radius {
    if (radius <= 0) return self;
    const cv::Mat alpha((int)_height, (int)_width, CV_32F, (void *)_skyAlpha.bytes);
    // 比較明の境界ぼかし（Core Image のガウスぼかし、半径＝標準偏差）と同じ強さにする。
    // 大きくぼかすときは縮小してからぼかす（なだらかなので縮小しても変わらず、計算が軽い）
    const double maxSigma = 8.0;
    cv::Mat blurred;
    if (radius <= maxSigma) {
        cv::GaussianBlur(alpha, blurred, cv::Size(0, 0), radius, radius, cv::BORDER_REPLICATE);
    } else {
        const double scale = maxSigma / radius;
        cv::Mat small;
        cv::resize(alpha, small, cv::Size(), scale, scale, cv::INTER_AREA);
        cv::GaussianBlur(small, small, cv::Size(0, 0), maxSigma, maxSigma, cv::BORDER_REPLICATE);
        cv::resize(small, blurred, alpha.size(), 0, 0, cv::INTER_LINEAR);
    }
    if (!blurred.isContinuous()) blurred = blurred.clone();
    // 合成に使う空・地上の範囲はぼかす前の判定のまま（ぼかしは仕上げの重ね合わせだけに効かせる）
    NightscapeMask *feathered = [[NightscapeMask alloc] initWithSkyAlpha:_skyAlpha width:_width height:_height
                                                          hasBothRegions:_hasBothRegions skyMargin:0];
    feathered->_certainSky = _certainSky;
    feathered->_certainGround = _certainGround;
    feathered.skyAlpha = [NSData dataWithBytes:blurred.data length:blurred.total() * sizeof(float)];
    return feathered;
}

@end

// ─────────────────────────────────────────────
//  空と地上の判定
// ─────────────────────────────────────────────

@implementation NightscapeAnalyzer {
    int _width, _height;
    double _analysisScale, _guideScale;
    cv::Size _analysisSize, _guideSize;
    cv::Mat _starSum, _starSumSq, _starCount;       // 星に合わせた細かな構造（輝度の高周波）と二乗（判定用の解像度）
    cv::Mat _groundSum, _groundSumSq, _groundCount; // 地上に合わせた細かな構造と二乗（判定用）
    std::vector<cv::Matx33d> _relative;    // 各フレームの「星に合わせた座標 → 地上に合わせた座標」（判定用の解像度）
    cv::Mat _groundRGBSum;                 // 地上に合わせたRGB（判定用、GrabCut の色）
    cv::Mat _guideSum, _guideCount;        // 地上に合わせた輝度（境界の仕上げ用の解像度）
    double _maximumRelativeShift;          // 星と地上の動きの差の最大値（元の解像度のpx）
}

- (double)maximumRelativeShift {
    return _maximumRelativeShift;
}

- (instancetype)initWithWidth:(NSInteger)width height:(NSInteger)height {
    self = [super init];
    if (!self) return nil;
    _width = (int)width;
    _height = (int)height;
    const int longSide = std::max(_width, _height);
    _analysisScale = std::min(1.0, (double)kAnalysisMaxSide / longSide);
    _guideScale = std::min(1.0, (double)kGuideMaxSide / longSide);
    _analysisSize = cv::Size(std::max(1, (int)std::lround(_width * _analysisScale)),
                             std::max(1, (int)std::lround(_height * _analysisScale)));
    _guideSize = cv::Size(std::max(1, (int)std::lround(_width * _guideScale)),
                          std::max(1, (int)std::lround(_height * _guideScale)));
    _starSum = cv::Mat::zeros(_analysisSize, CV_32F);
    _starSumSq = cv::Mat::zeros(_analysisSize, CV_32F);
    _starCount = cv::Mat::zeros(_analysisSize, CV_32F);
    _groundSum = cv::Mat::zeros(_analysisSize, CV_32F);
    _groundSumSq = cv::Mat::zeros(_analysisSize, CV_32F);
    _groundCount = cv::Mat::zeros(_analysisSize, CV_32F);
    _groundRGBSum = cv::Mat::zeros(_analysisSize, CV_32FC3);
    _guideSum = cv::Mat::zeros(_guideSize, CV_32F);
    _guideCount = cv::Mat::zeros(_guideSize, CV_32F);
    _maximumRelativeShift = 0;
    return self;
}

- (BOOL)addFrameGray:(NSData *)gray
                 rgb:(NSData *)rgb
      starHomography:(NSArray<NSNumber *> *)starHomography
    groundHomography:(NSArray<NSNumber *> *)groundHomography
               error:(NSError **)error {
    const size_t pixels = (size_t)_width * _height;
    if (gray.length < pixels * sizeof(float) || rgb.length < pixels * 3 * sizeof(uint16_t)) {
        if (error) *error = NightscapeError(1, @"新星景モードの画素データが不正です");
        return NO;
    }
    cv::Mat grayFull(_height, _width, CV_32F, (void *)gray.bytes);
    cv::Mat rgbFull(_height, _width, CV_16UC3, (void *)rgb.bytes);
    const cv::Matx33d hs = MatrixFromArray(starHomography), hg = MatrixFromArray(groundHomography);

    // 星と地上の動きの差（四隅と中央で最大のもの）
    const double points[5][2] = {{0, 0}, {(double)_width, 0}, {0, (double)_height}, {(double)_width, (double)_height},
                                 {_width * 0.5, _height * 0.5}};
    for (const auto &point : points) {
        const cv::Vec3d p(point[0], point[1], 1), a = hs * p, b = hg * p;
        _maximumRelativeShift = std::max(_maximumRelativeShift,
                                         std::hypot(a[0] / a[2] - b[0] / b[2], a[1] / a[2] - b[1] / b[2]));
    }

    cv::Mat graySmall, rgbSmall, grayGuide;
    cv::resize(grayFull, graySmall, _analysisSize, 0, 0, cv::INTER_AREA);
    // ばらつきは細かな構造（星・地上の模様や輪郭）だけで比べる。地平線付近の光害のようななだらかな明るさは
    // 地上に対して動かないため、そのまま比べると星の見える空を地上と取り違える
    cv::Mat smooth;
    cv::GaussianBlur(graySmall, smooth, cv::Size(0, 0), kDetailSigma);
    const cv::Mat detailSmall = graySmall - smooth;
    cv::resize(rgbFull, rgbSmall, _analysisSize, 0, 0, cv::INTER_AREA);
    rgbSmall.convertTo(rgbSmall, CV_32FC3);
    cv::resize(grayFull, grayGuide, _guideSize, 0, 0, cv::INTER_AREA);

    const cv::Matx33d hsSmall = ScaleHomography(hs, _analysisScale), hgSmall = ScaleHomography(hg, _analysisScale);
    const cv::Matx33d hgGuide = ScaleHomography(hg, _guideScale);
    cv::Mat warped, valid;

    // 星に合わせた座標 x は、地上に合わせた座標では Hg * Hs^-1 * x（地上の手がかりを縮めるのに使う）
    _relative.push_back(hgSmall * hsSmall.inv());

    cv::warpPerspective(detailSmall, warped, hsSmall, _analysisSize, cv::INTER_LINEAR);
    valid = WarpValidity(_analysisSize, hsSmall);
    _starSum += warped.mul(valid);
    _starSumSq += warped.mul(warped).mul(valid);
    _starCount += valid;

    cv::warpPerspective(detailSmall, warped, hgSmall, _analysisSize, cv::INTER_LINEAR);
    valid = WarpValidity(_analysisSize, hgSmall);
    _groundSum += warped.mul(valid);
    _groundSumSq += warped.mul(warped).mul(valid);
    _groundCount += valid;
    cv::Mat warpedRGB;
    cv::warpPerspective(rgbSmall, warpedRGB, hgSmall, _analysisSize, cv::INTER_LINEAR);
    cv::Mat valid3;
    cv::merge(std::vector<cv::Mat>{valid, valid, valid}, valid3);
    _groundRGBSum += warpedRGB.mul(valid3);

    cv::warpPerspective(grayGuide, warped, hgGuide, _guideSize, cv::INTER_LINEAR);
    valid = WarpValidity(_guideSize, hgGuide);
    _guideSum += warped.mul(valid);
    _guideCount += valid;
    return YES;
}

- (nullable NightscapeMask *)segmentWithHints:(nullable NSData *)hints error:(NSError **)error {
    cv::Mat starCount = cv::max(_starCount, 1.0f), groundCount = cv::max(_groundCount, 1.0f);
    if (cv::countNonZero(_starCount) == 0) {
        if (error) *error = NightscapeError(2, @"判定に使うフレームがありません");
        return nil;
    }
    cv::Mat starMean = _starSum / starCount;
    cv::Mat groundMean = _groundSum / groundCount;
    // フレーム間の細かな構造のばらつき（分散）
    cv::Mat starVariance = cv::max(_starSumSq / starCount - starMean.mul(starMean), 0.0f);
    cv::Mat groundVariance = cv::max(_groundSumSq / groundCount - groundMean.mul(groundMean), 0.0f);
    cv::Mat groundRGB;
    cv::Mat groundCount3;
    cv::merge(std::vector<cv::Mat>{groundCount, groundCount, groundCount}, groundCount3);
    cv::divide(_groundRGBSum, groundCount3, groundRGB);

    // 1. フレーム間のばらつきの差: 空は星に合わせるとフレームどうしが一致し、地上に合わせると星が通り過ぎて
    //    ばらつく。地上はその逆。センサーのノイズは両方に同じだけ乗るため打ち消し合う。
    //    （細部の多さで比べると、地上に合わせた画像の星の軌跡を地上の模様と取り違える）
    cv::Mat starSpread, groundSpread;
    cv::boxFilter(starVariance, starSpread, CV_32F, cv::Size(7, 7));
    cv::boxFilter(groundVariance, groundSpread, CV_32F, cv::Size(7, 7));
    // ノイズによるばらつき（どちらかに合わせればノイズだけになる画素が多いため、小さい方の中央値）
    const float noise = std::max(1e-6f, Median(cv::min(starSpread, groundSpread)));
    // 確実な手がかりは、片方に合わせるとばらつき、もう片方に合わせるとノイズ程度になる画素だけ。
    // 稜線のすぐ上のように両方でばらつく画素（星が通り過ぎ、星に合わせると地上のシルエットも通る）は
    // どちらとも決めず、色で判断させる
    // 空は星に合わせるとノイズ程度まで一定になる。明滅する灯りや動く人・車の灯りは地上に合わせてもばらつくが、
    // 星に合わせても（地上が動くため）一定にならないので、空の手がかりにしない
    cv::Mat seedSky = (groundSpread > 4.0f * noise) & (starSpread < 0.5f * groundSpread) & (starSpread < 3.0f * noise);
    cv::Mat seedGround = (starSpread > 4.0f * noise) & (groundSpread < 0.5f * starSpread);
    cv::Mat openKernel = cv::getStructuringElement(cv::MORPH_ELLIPSE, cv::Size(3, 3));
    cv::morphologyEx(seedSky, seedSky, cv::MORPH_OPEN, openKernel);
    cv::morphologyEx(seedGround, seedGround, cv::MORPH_OPEN, openKernel);
    // 本当の空の手がかりは空一面に広がり、画面の上辺までつながる。地上の中に孤立した小さな手がかり
    // （水面の反射・灯りのまわり）は除く
    seedSky = KeepConnectedSky(seedSky, std::max(2, (int)std::lround(kSkySeedLinkFraction * std::max(_analysisSize.width, _analysisSize.height))));
    // 稜線のすぐ上の空は、星に合わせると動いた地上のシルエットが通り過ぎてばらつき、地上に合わせても
    // 星が通らない画素はばらつかないため、地上の手がかりに紛れ込む。紛れ込むのは、星に合わせた座標 x から
    // 見て地上に合わせた座標 Hg * Hs^-1 * x が地上になるフレームがある画素なので、各フレームの星と地上のずれの
    // 向きにだけ地上の手がかりを縮める（ずれの無い向きには縮めないため、水平線の下の海などが残る）。
    // 最後に、ばらつきを周囲7x7で平均した分だけさらに縮める。境界付近は色で判断させる。
    // 空の手がかりは地上に合わせてばらつく画素なので、動かない地上には紛れ込まない（縮めない）
    seedGround = ErodeByRelativeMotion(seedGround, _relative);
    cv::erode(seedGround, seedGround, cv::getStructuringElement(cv::MORPH_ELLIPSE, cv::Size(7, 7)));

    // 塗った手がかり。1/2 は利用者のブラシ、3/4 は前回の自動判定の結果（ブラシで直せるように表示したもの）。
    // ブラシは本当の境界より少しはみ出して塗られることが多く、そのまま確実なものとすると境界が塗った跡に沿ってしまい、
    // 空に星の無い帯が出る。塗った範囲の内側は確実なものとし、縁（kHintRimFraction）は「おそらくその側」として
    // 色と輪郭で本当の境界に吸い付かせる（縁でも自動の手がかりより塗った側を優先する）。
    // 縁を除くと消えてしまう細い塗りは、意図して細かく直した所なのでそのまま確実なものとする。
    // 前回の自動判定より利用者のブラシを優先する
    cv::Mat rimSky = cv::Mat::zeros(_analysisSize, CV_8U), rimGround = cv::Mat::zeros(_analysisSize, CV_8U);
    cv::Mat hintFull;
    if (hints.length >= (NSUInteger)_width * _height) {
        hintFull = cv::Mat(_height, _width, CV_8U, (void *)hints.bytes);
        cv::Mat hintSmall;
        cv::resize(hintFull, hintSmall, _analysisSize, 0, 0, cv::INTER_NEAREST);
        const int rim = std::max(1, (int)std::lround(kHintRimFraction * std::max(_analysisSize.width, _analysisSize.height)));
        for (const bool byUser : {false, true}) {
            const cv::Mat paintedSky = hintSmall == (byUser ? 1 : 3), paintedGround = hintSmall == (byUser ? 2 : 4);
            const cv::Mat coreSky = HintCore(paintedSky, rim, byUser), coreGround = HintCore(paintedGround, rim, byUser);
            seedSky.setTo(255, coreSky);
            seedGround.setTo(0, coreSky);
            seedGround.setTo(255, coreGround);
            seedSky.setTo(0, coreGround);
            const cv::Mat edgeSky = paintedSky & ~coreSky, edgeGround = paintedGround & ~coreGround;
            seedSky.setTo(0, edgeGround);
            seedGround.setTo(0, edgeSky);
            rimSky.setTo(0, paintedGround);
            rimGround.setTo(0, paintedSky);
            rimSky.setTo(255, edgeSky);
            rimGround.setTo(255, edgeGround);
        }
    }

    const double minimumSeed = 0.002 * (double)_analysisSize.area();
    const bool hasBoth = cv::countNonZero(seedSky) >= minimumSeed && cv::countNonZero(seedGround) >= minimumSeed;

    // 2. 境界: 地上に合わせた画像（輪郭がくっきり、ノイズが少ない）の色で GrabCut。
    //    空に写る星の軌跡に境界が引きずられないよう、明るく細い構造は取り除いた画像を使う。
    //    手がかりの無い画素の初期の見立ては、細部の差を広くぼかした向き（空寄りか地上寄りか）で決める。
    //    ただし近くに空の手がかり（動く星）が無い画素は地上寄りとする。模様も星も無いなだらかな海などは
    //    どちらの手がかりも無く、空と色が近いと空にされて水平線がぼけるため
    cv::Mat binarySky;
    if (hasBoth) {
        const cv::Mat stretched = StretchForDisplay(RemoveBrightThinStructures(groundRGB, 5));
        const cv::Mat colorImage = HueWeightedLab(stretched);
        // 手がかりの無い所（なだらかな海・影の中の暗い崖など）は、色が空に似ていることが多い。
        // まず輪郭を壁にして手がかりから塗り広げ（分水嶺）、それを色の判定（GrabCut）の初めの見立てにする
        cv::Mat stretched8;
        stretched.convertTo(stretched8, CV_8UC3, 255.0);
        const cv::Mat flooded = FloodFromSeeds(stretched8, seedSky, seedGround);
        cv::Mat grabMask(_analysisSize, CV_8U, cv::Scalar(cv::GC_PR_BGD));
        grabMask.setTo(cv::GC_PR_FGD, flooded);
        grabMask.setTo(cv::GC_PR_FGD, rimSky);
        grabMask.setTo(cv::GC_PR_BGD, rimGround);
        grabMask.setTo(cv::GC_FGD, seedSky);
        grabMask.setTo(cv::GC_BGD, seedGround);
        cv::Mat backgroundModel, foregroundModel;
        // GrabCut の色の分布の初期化は乱数を使うため、毎回同じ結果になるよう種を固定する
        cv::theRNG().state = kGrabCutSeed;
        cv::grabCut(colorImage, grabMask, cv::Rect(), backgroundModel, foregroundModel, 5, cv::GC_INIT_WITH_MASK);
        binarySky = (grabMask == cv::GC_FGD) | (grabMask == cv::GC_PR_FGD);
        RemoveSmallIslands(binarySky, 0.001);
    } else {
        // どちらかしか見つからない構図は、見つかった側だけとして扱う（分けて合成しない）
        const bool mostlySky = cv::countNonZero(seedSky) >= cv::countNonZero(seedGround);
        binarySky = cv::Mat(_analysisSize, CV_8U, cv::Scalar(mostlySky ? 255 : 0));
    }

    // 3. 仕上げ: 高い解像度で、地上に合わせた画像の色の輪郭に沿って柔らかいマスクにする。
    //    境界から離れた場所は判定のまま（0か1）にし、境界付近だけを変える
    cv::Mat guideGray = RemoveBrightThinStructures(_guideSum / cv::max(_guideCount, 1.0f), 7);
    cv::Mat guideRGB;
    cv::resize(RemoveBrightThinStructures(groundRGB, 5), guideRGB, _guideSize, 0, 0, cv::INTER_LINEAR);
    // 色は判定用の解像度から、明るさの細部は高い解像度の画像から取る
    cv::Mat guideLuma;
    cv::cvtColor(guideRGB, guideLuma, cv::COLOR_RGB2GRAY);
    std::vector<cv::Mat> channels;
    cv::split(guideRGB, channels);
    for (cv::Mat &channel : channels) channel = channel.mul(guideGray / cv::max(guideLuma, 1e-3f));
    cv::merge(channels, guideRGB);
    const cv::Mat guide = StretchForDisplay(guideRGB);
    // 判定用の解像度（数px単位）の境界を、高い解像度で境界の近くだけ決め直す（水平線などの段差をなくす）。
    // 利用者が細く塗った所・塗った範囲の内側は、そのまま確実なものとする
    cv::Mat skyGuideRes;
    cv::resize(binarySky, skyGuideRes, _guideSize, 0, 0, cv::INTER_NEAREST);
    if (hasBoth) {
        cv::Mat fixedSky = cv::Mat::zeros(_guideSize, CV_8U), fixedGround = cv::Mat::zeros(_guideSize, CV_8U);
        if (!hintFull.empty()) {
            cv::Mat hintGuide;
            cv::resize(hintFull, hintGuide, _guideSize, 0, 0, cv::INTER_NEAREST);
            const int rim = std::max(1, (int)std::lround(kHintRimFraction * std::max(_guideSize.width, _guideSize.height)));
            fixedSky = HintCore(hintGuide == 1, rim, true);
            fixedGround = HintCore(hintGuide == 2, rim, true);
        }
        const int band = (int)std::ceil(2.0 * _guideScale / _analysisScale) + 2;
        skyGuideRes = RefineBoundaryInTiles(guide, skyGuideRes, fixedSky, fixedGround, band);
    }
    skyGuideRes.convertTo(skyGuideRes, CV_32F, 1.0 / 255.0);
    const int radius = std::max(2, (int)std::lround(8 * _guideScale * (double)kGuideMaxSide / 3000.0));
    cv::Mat alphaGuide = ColorGuidedFilter(guide, skyGuideRes, radius, 1e-3);
    cv::max(alphaGuide, 0.0, alphaGuide);
    cv::min(alphaGuide, 1.0, alphaGuide);
    // ガイドフィルタは窓の平均を2回取るため、境界から 2 * radius 先まで値が変わる。帯をそれより狭くすると
    // 帯の端で比率が段になり、空に境界と平行な線が出る
    cv::Mat boundary;
    cv::morphologyEx(skyGuideRes > 0.5f, boundary, cv::MORPH_GRADIENT,
                     cv::getStructuringElement(cv::MORPH_ELLIPSE, cv::Size(4 * radius + 1, 4 * radius + 1)));
    skyGuideRes.copyTo(alphaGuide, boundary == 0);
    cv::Mat alpha;
    cv::resize(alphaGuide, alpha, cv::Size(_width, _height), 0, 0, cv::INTER_LINEAR);
    if (!alpha.isContinuous()) alpha = alpha.clone();

    NSData *alphaData = [NSData dataWithBytes:alpha.data length:alpha.total() * sizeof(float)];
    const int skyMargin = std::max(2, (int)std::ceil(1.0 / _analysisScale) + 1);
    return [[NightscapeMask alloc] initWithSkyAlpha:alphaData width:_width height:_height hasBothRegions:hasBoth
                                          skyMargin:skyMargin];
}

@end

// ─────────────────────────────────────────────
//  合成
// ─────────────────────────────────────────────

// ─────────────────────────────────────────────
//  外れ値を除くための輝度の記録（画素ごとの中央値の基準）
// ─────────────────────────────────────────────

@interface NightscapeSamples ()
- (const std::vector<cv::Mat> &)starPlanes;
- (const std::vector<cv::Mat> &)groundPlanes;
- (const std::vector<cv::Matx33d> &)starHomographies;
- (const std::vector<cv::Matx33d> &)groundHomographies;
@end

@implementation NightscapeSamples {
    int _width, _height;
    std::vector<cv::Mat> _star;     // 星に合わせた輝度（16bit。0 は画像の外）
    std::vector<cv::Mat> _ground;   // 地上に合わせた輝度（16bit。0 は画像の外）
    std::vector<cv::Matx33d> _starH, _groundH;
}

- (instancetype)initWithWidth:(NSInteger)width height:(NSInteger)height {
    self = [super init];
    if (!self) return nil;
    _width = (int)width;
    _height = (int)height;
    return self;
}

- (NSInteger)frameCount {
    return (NSInteger)_star.size();
}

- (const std::vector<cv::Mat> &)starPlanes { return _star; }
- (const std::vector<cv::Mat> &)groundPlanes { return _ground; }
- (const std::vector<cv::Matx33d> &)starHomographies { return _starH; }
- (const std::vector<cv::Matx33d> &)groundHomographies { return _groundH; }

/// 輝度を 1〜65535 の16bitにする（0 は「画像の外」の印として空けておく）
static cv::Mat EncodeLuminance(const cv::Mat &luminance, const cv::Mat &valid) {
    cv::Mat shifted = luminance + 1.0f;
    cv::Mat encoded;
    shifted.convertTo(encoded, CV_16U);
    encoded.setTo(0, valid < 0.5f);
    return encoded;
}

- (BOOL)addFrameGray:(NSData *)gray
      starHomography:(NSArray<NSNumber *> *)starHomography
    groundHomography:(NSArray<NSNumber *> *)groundHomography
               error:(NSError **)error {
    const cv::Size size(_width, _height);
    if (gray.length < (NSUInteger)size.area() * sizeof(float)) {
        if (error) *error = NightscapeError(1, @"新星景モードの画素データが不正です");
        return NO;
    }
    const cv::Mat image(size, CV_32F, (void *)gray.bytes);
    const cv::Matx33d hs = MatrixFromArray(starHomography), hg = MatrixFromArray(groundHomography);
    cv::Mat warped;
    cv::warpPerspective(image, warped, hs, size, cv::INTER_LINEAR);
    _star.push_back(EncodeLuminance(warped, WarpValidity(size, hs)));
    cv::warpPerspective(image, warped, hg, size, cv::INTER_LINEAR);
    _ground.push_back(EncodeLuminance(warped, WarpValidity(size, hg)));
    _starH.push_back(hs);
    _groundH.push_back(hg);
    return YES;
}

/// 画素ごとの中央値と、外れ値とみなす幅（中央値からの許容幅）を求める。
/// weights が空でなければ、そのフレームで重みが 0 の画素は使わない
static void MedianAndTolerance(const std::vector<cv::Mat> &samples, const std::vector<cv::Mat> &weights,
                               const cv::Size &size, cv::Mat &median, cv::Mat &tolerance) {
    median = cv::Mat::zeros(size, CV_32F);
    cv::Mat mad = cv::Mat::zeros(size, CV_32F);
    cv::Mat counts = cv::Mat::zeros(size, CV_32F);
    const size_t n = samples.size();
    cv::parallel_for_(cv::Range(0, size.height), [&](const cv::Range &rows) {
        std::vector<float> values(n), deviations(n);
        for (int y = rows.start; y < rows.end; y++) {
            float *medianRow = median.ptr<float>(y), *madRow = mad.ptr<float>(y), *countRow = counts.ptr<float>(y);
            for (int x = 0; x < size.width; x++) {
                size_t count = 0;
                for (size_t i = 0; i < n; i++) {
                    const uint16_t value = samples[i].at<uint16_t>(y, x);
                    if (value == 0) continue;
                    if (!weights.empty() && weights[i].at<uchar>(y, x) == 0) continue;
                    values[count++] = (float)value - 1.0f;
                }
                countRow[x] = (float)count;
                if (count == 0) continue;
                std::nth_element(values.begin(), values.begin() + count / 2, values.begin() + count);
                const float center = values[count / 2];
                for (size_t i = 0; i < count; i++) deviations[i] = std::fabs(values[i] - center);
                std::nth_element(deviations.begin(), deviations.begin() + count / 2, deviations.begin() + count);
                medianRow[x] = center;
                madRow[x] = 1.4826f * deviations[count / 2];
            }
        }
    });
    // 画像全体のノイズ（MADの中央値）を下限にし、中央値から3倍を超えて離れた値を外れ値とする。
    // 3枚未満しか無い画素は外れ値を判定できないため除かない
    std::vector<float> values;
    for (int y = 0; y < size.height; y += 4) {
        for (int x = 0; x < size.width; x += 4) {
            if (counts.at<float>(y, x) >= 3) values.push_back(mad.at<float>(y, x));
        }
    }
    float noiseFloor = 1.0f;
    if (!values.empty()) {
        std::nth_element(values.begin(), values.begin() + values.size() / 2, values.end());
        noiseFloor = std::max(1.0f, values[values.size() / 2]);
    }
    tolerance = 3.0f * cv::max(mad, noiseFloor);
    tolerance.setTo(1e30f, counts < 3.0f);
}

@end

// ─────────────────────────────────────────────
//  合成
// ─────────────────────────────────────────────

@implementation NightscapeAccumulator {
    NightscapeMask *_mask;
    int _width, _height;
    cv::Mat _certainSky;                           // 0/1（float）
    cv::Mat _skySum, _skyWeight;                   // 確実に空だった画素だけを星に合わせて平均
    cv::Mat _groundSum, _groundWeight;             // 画面全体を地上に合わせて平均（空の部分は星のない空＝光害フレーム）
    bool _rejecting;
    cv::Mat _skyMedian, _skyTolerance, _groundMedian, _groundTolerance;
    NSInteger _frameCount;
}

- (instancetype)initWithMask:(NightscapeMask *)mask samples:(nullable NightscapeSamples *)samples {
    self = [super init];
    if (!self) return nil;
    _mask = mask;
    _width = (int)mask.width;
    _height = (int)mask.height;
    const cv::Size size(_width, _height);
    cv::Mat(size, CV_8U, (void *)mask.certainSky.bytes).convertTo(_certainSky, CV_32F, 1.0 / 255.0);
    _skySum = cv::Mat::zeros(size, CV_32FC3);
    _groundSum = cv::Mat::zeros(size, CV_32FC3);
    _skyWeight = cv::Mat::zeros(size, CV_32F);
    _groundWeight = cv::Mat::zeros(size, CV_32F);
    _rejecting = samples != nil && samples.frameCount >= 3;
    if (_rejecting) [self prepareRejectionFrom:samples];
    return self;
}

- (void)prepareRejectionFrom:(NightscapeSamples *)samples {
    // 画素ごとの中央値を基準に、動く星（地上側）・紛れ込んだ地上や飛行機の光（空側）を外れ値として除く
    const cv::Size size(_width, _height);
    const std::vector<cv::Mat> &star = [samples starPlanes], &ground = [samples groundPlanes];
    const std::vector<cv::Matx33d> &starH = [samples starHomographies], &groundH = [samples groundHomographies];
    std::vector<cv::Mat> skyWeights;
    for (size_t i = 0; i < star.size(); i++) {
        skyWeights.push_back([self skyWeightForStar:starH[i] ground:groundH[i]] > 0.5f);
    }
    MedianAndTolerance(star, skyWeights, size, _skyMedian, _skyTolerance);
    MedianAndTolerance(ground, {}, size, _groundMedian, _groundTolerance);
}

- (NSInteger)frameCount {
    return _frameCount;
}

/// このフレームで確実に空だった画素（星に合わせた座標）。基準画像の空の範囲を地上の動きで戻したもので、
/// 星の座標 x では certainSky(Hg * Hs^-1 * x)。warpPerspective は逆写像で読むため Hs * Hg^-1 で変形する
- (cv::Mat)skyWeightForStar:(const cv::Matx33d &)hs ground:(const cv::Matx33d &)hg {
    const cv::Size size(_width, _height);
    cv::Mat weight;
    cv::warpPerspective(_certainSky, weight, hs * hg.inv(), size, cv::INTER_LINEAR, cv::BORDER_CONSTANT, cv::Scalar(0));
    cv::threshold(weight, weight, 0.999, 1.0, cv::THRESH_BINARY);
    return weight.mul(WarpValidity(size, hs));
}

static cv::Mat Luminance(const cv::Mat &rgb) {
    cv::Mat gray;
    cv::transform(rgb, gray, cv::Matx13f(1.0f / 3, 1.0f / 3, 1.0f / 3));
    return gray;
}

static void Accumulate(cv::Mat &sum, cv::Mat &weightSum, const cv::Mat &image, const cv::Mat &weight) {
    cv::Mat weight3;
    cv::merge(std::vector<cv::Mat>{weight, weight, weight}, weight3);
    sum += image.mul(weight3);
    weightSum += weight;
}

- (BOOL)addFrameRGB:(NSData *)rgb
     starHomography:(NSArray<NSNumber *> *)starHomography
   groundHomography:(NSArray<NSNumber *> *)groundHomography
              error:(NSError **)error {
    const cv::Size size(_width, _height);
    if (rgb.length < (NSUInteger)size.area() * 3 * sizeof(uint16_t)) {
        if (error) *error = NightscapeError(1, @"新星景モードの画素データが不正です");
        return NO;
    }
    cv::Mat frame;
    cv::Mat(size, CV_16UC3, (void *)rgb.bytes).convertTo(frame, CV_32FC3);
    const cv::Matx33d hs = MatrixFromArray(starHomography), hg = MatrixFromArray(groundHomography);

    // 空: 星に合わせて変形し、このフレームで確実に空だった画素だけを加える
    cv::Mat starWarped;
    cv::warpPerspective(frame, starWarped, hs, size, cv::INTER_LANCZOS4, cv::BORDER_CONSTANT, cv::Scalar::all(0));
    cv::Mat skyWeight = [self skyWeightForStar:hs ground:hg];
    if (_rejecting) skyWeight.setTo(0, cv::abs(Luminance(starWarped) - _skyMedian) > _skyTolerance);
    Accumulate(_skySum, _skyWeight, starWarped, skyWeight);

    // 地上: 画面全体を地上に合わせて変形して加える（空の部分は動く星が外れ値として除かれ、星のない空になる）
    cv::Mat groundWarped;
    cv::warpPerspective(frame, groundWarped, hg, size, cv::INTER_LANCZOS4, cv::BORDER_CONSTANT, cv::Scalar::all(0));
    cv::Mat groundWeight = WarpValidity(size, hg);
    if (_rejecting) groundWeight.setTo(0, cv::abs(Luminance(groundWarped) - _groundMedian) > _groundTolerance);
    Accumulate(_groundSum, _groundWeight, groundWarped, groundWeight);
    _frameCount++;
    return YES;
}

- (nullable NSData *)composeWithError:(NSError **)error {
    if (_frameCount == 0) {
        if (error) *error = NightscapeError(3, @"合成するフレームがありません");
        return nil;
    }
    const cv::Size size(_width, _height);
    const cv::Mat alpha(size, CV_32F, (void *)_mask.skyAlpha.bytes);
    const int longSide = std::max(_width, _height);

    // 空と地上の層（重みで割った平均）。空のデータが無い画素（地平線のすぐ上など）は星のない空（地上の層）で埋める
    cv::Mat sky(size, CV_32FC3), ground(size, CV_32FC3);
    cv::Mat hasSky = _skyWeight > 0.5f, hasGround = _groundWeight > 0.5f;
    cv::parallel_for_(cv::Range(0, _height), [&](const cv::Range &rows) {
        for (int y = rows.start; y < rows.end; y++) {
            const cv::Vec3f *skySum = _skySum.ptr<cv::Vec3f>(y), *groundSum = _groundSum.ptr<cv::Vec3f>(y);
            const float *skyW = _skyWeight.ptr<float>(y), *groundW = _groundWeight.ptr<float>(y);
            cv::Vec3f *skyRow = sky.ptr<cv::Vec3f>(y), *groundRow = ground.ptr<cv::Vec3f>(y);
            for (int x = 0; x < _width; x++) {
                groundRow[x] = groundW[x] > 0.5f ? groundSum[x] / groundW[x] : cv::Vec3f(0, 0, 0);
                skyRow[x] = skyW[x] > 0.5f ? skySum[x] / skyW[x] : groundRow[x];
                if (groundW[x] <= 0.5f) groundRow[x] = skyRow[x];
            }
        }
    });
    // 空の層から星だけを取り出す（背景を除いた明るさ）。光害フレームに重ねて、継ぎ目付近の星が薄くならないようにする
    const int starSize = std::max(5, (int)std::lround(longSide * 0.0015) | 1);
    cv::Mat stars;
    cv::morphologyEx(sky, stars, cv::MORPH_TOPHAT, cv::getStructuringElement(cv::MORPH_ELLIPSE, cv::Size(starSize, starSize)));
    // 光害フレーム: 地上に合わせた層の空（動く星は外れ値として除かれている）。星と地上の動きの差が小さいと
    // 星が短い線として残るため、明るく細い構造を取り除いて、なだらかな光害・地平線の明るさだけにする
    const cv::Mat lightPollution = RemoveBrightThinStructures(ground, 2 * starSize + 1);
    // 光害フレームを重ねる強さ: 地上との境界で1、空の奥へ向かってなだらかに0へ
    const cv::Mat lightPollutionWeight = LightPollutionWeight(alpha);

    NSMutableData *output = [NSMutableData dataWithLength:(NSUInteger)size.area() * 3 * sizeof(uint16_t)];
    uint16_t *out = (uint16_t *)output.mutableBytes;
    cv::parallel_for_(cv::Range(0, _height), [&](const cv::Range &rows) {
        for (int y = rows.start; y < rows.end; y++) {
            const cv::Vec3f *skyRow = sky.ptr<cv::Vec3f>(y), *groundRow = ground.ptr<cv::Vec3f>(y);
            const cv::Vec3f *starRow = stars.ptr<cv::Vec3f>(y), *lightRow = lightPollution.ptr<cv::Vec3f>(y);
            const uchar *hasSkyRow = hasSky.ptr<uchar>(y), *hasGroundRow = hasGround.ptr<uchar>(y);
            const float *a = alpha.ptr<float>(y), *weightRow = lightPollutionWeight.ptr<float>(y);
            for (int x = 0; x < _width; x++) {
                // 空: 星に合わせた層に、星を重ねた光害フレームを比較明で合わせる
                cv::Vec3f skyValue = skyRow[x];
                if (weightRow[x] > 0 && hasGroundRow[x]) {
                    cv::Vec3f lighter = lightRow[x];
                    if (hasSkyRow[x]) lighter += starRow[x];
                    for (int c = 0; c < 3; c++) skyValue[c] += weightRow[x] * std::max(0.0f, lighter[c] - skyValue[c]);
                }
                // 地上を一番上に重ねる（地上側は明るくしない・星を足さない）
                const cv::Vec3f value = skyValue * a[x] + groundRow[x] * (1.0f - a[x]);
                uint16_t *pixel = out + ((size_t)y * _width + x) * 3;
                for (int c = 0; c < 3; c++) {
                    pixel[c] = (uint16_t)std::lround(std::min(65535.0f, std::max(0.0f, value[c])));
                }
            }
        }
    });
    return output;
}

@end
