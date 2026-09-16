#import <opencv2/core.hpp>
#import <opencv2/imgproc.hpp>
#import <opencv2/imgcodecs.hpp>
#import <opencv2/features2d.hpp>
#import <opencv2/calib3d.hpp>

#import "ImageAligner.h"

// 特徴点（AKAZE、低コントラスト時はORB）の対応からホモグラフィを推定する。
// target の座標を base の座標へ写す 3x3 行列を返し、失敗時は空の行列を返す。
static cv::Mat EstimateHomography(const cv::Mat &im_target_gray, const cv::Mat &im_base_gray,
                                  NSError **error) {
  // --- High-precision feature detection using AKAZE ---
  // AKAZE produces binary descriptors and is invariant to
  // scale, rotation, and non-linear distortions.
  cv::Ptr<cv::AKAZE> akaze = cv::AKAZE::create();

  std::vector<cv::KeyPoint> kp1, kp2;
  cv::Mat desc1, desc2;

  akaze->detectAndCompute(im_target_gray, cv::noArray(), kp1, desc1);
  akaze->detectAndCompute(im_base_gray, cv::noArray(), kp2, desc2);

  if (kp1.size() < 10 || kp2.size() < 10 || desc1.empty() || desc2.empty()) {
    // Fallback to ORB for very low-contrast images (e.g. dim sky)
    cv::Ptr<cv::ORB> orb = cv::ORB::create(10000);
    orb->detectAndCompute(im_target_gray, cv::noArray(), kp1, desc1);
    orb->detectAndCompute(im_base_gray, cv::noArray(), kp2, desc2);
    if (desc1.empty() || desc2.empty()) {
      if (error) {
        *error =
            [NSError errorWithDomain:@"ImageAlignerDomain"
                                code:2
                            userInfo:@{
                                NSLocalizedDescriptionKey : @"位置合わせに必要な特徴点が見つかりませんでした"
                            }];
      }
      return cv::Mat();
    }
  }

  // --- Cross-check BruteForce matcher for reliability ---
  cv::BFMatcher matcher(cv::NORM_HAMMING, /*crossCheck=*/true);
  std::vector<cv::DMatch> matches;
  matcher.match(desc1, desc2, matches);

  if (matches.size() < 10) {
    if (error) {
      *error = [NSError
          errorWithDomain:@"ImageAlignerDomain"
                     code:3
                 userInfo:@{
                   NSLocalizedDescriptionKey : @"一致する特徴点が不足しています"
                 }];
    }
    return cv::Mat();
  }

  // Sort by distance and take the best 80%
  std::sort(matches.begin(), matches.end());
  size_t goodCount = (size_t)(matches.size() * 0.8);
  matches.resize(goodCount);

  // Extract matched keypoint locations
  std::vector<cv::Point2f> pts1, pts2;
  for (const auto &m : matches) {
    pts1.push_back(kp1[m.queryIdx].pt);
    pts2.push_back(kp2[m.trainIdx].pt);
  }

  // --- Homography with USAC_MAGSAC (more robust than basic RANSAC) ---
  // Falls back to standard RANSAC if USAC not available.
  cv::Mat homography;
  cv::Mat inlierMask;
  try {
    homography = cv::findHomography(pts1, pts2, cv::USAC_MAGSAC, 3.0,
                                    inlierMask, 5000, 0.999);
  } catch (...) {
    homography = cv::findHomography(pts1, pts2, cv::RANSAC, 3.0, inlierMask,
                                    5000, 0.999);
  }

  if (homography.empty()) {
    if (error) {
      *error = [NSError
          errorWithDomain:@"ImageAlignerDomain"
                     code:4
                 userInfo:@{
                   NSLocalizedDescriptionKey : @"画像間の変換を計算できませんでした"
                 }];
    }
    return cv::Mat();
  }

  const int inlierCount = inlierMask.empty() ? 0 : cv::countNonZero(inlierMask);
  const double inlierRatio = matches.empty() ? 0.0 : (double)inlierCount / (double)matches.size();
  if (inlierCount < 8 || inlierRatio < 0.25) {
    if (error) {
      *error = [NSError
          errorWithDomain:@"ImageAlignerDomain"
                     code:5
                 userInfo:@{
                   NSLocalizedDescriptionKey : @"位置合わせの信頼度が不足しています"
                 }];
    }
    return cv::Mat();
  }

  return homography;
}

@implementation ImageAligner

+ (NSImage *)alignImageAtURL:(NSURL *)targetURL
            toBaseImageAtURL:(NSURL *)baseURL
                       error:(NSError **)error {

  // Load as Grayscale for feature extraction
  cv::Mat im_target_gray =
      cv::imread(targetURL.path.UTF8String, cv::IMREAD_GRAYSCALE);
  cv::Mat im_base_gray =
      cv::imread(baseURL.path.UTF8String, cv::IMREAD_GRAYSCALE);

  if (im_target_gray.empty() || im_base_gray.empty()) {
    if (error) {
      *error =
          [NSError errorWithDomain:@"ImageAlignerDomain"
                              code:1
                          userInfo:@{
                            NSLocalizedDescriptionKey : @"画像を読み込めませんでした"
                          }];
    }
    return nil;
  }

  cv::Mat homography = EstimateHomography(im_target_gray, im_base_gray, error);
  if (homography.empty()) {
    return nil;
  }

  // --- Warp original color image using the computed homography ---
  cv::Mat im_target_color =
      cv::imread(targetURL.path.UTF8String, cv::IMREAD_UNCHANGED);
  if (im_target_color.empty()) {
    if (error) {
      *error = [NSError
          errorWithDomain:@"ImageAlignerDomain"
                     code:6
                 userInfo:@{
                   NSLocalizedDescriptionKey : @"カラー画像を読み込めませんでした"
                 }];
    }
    return nil;
  }
  if (im_target_color.depth() != CV_8U && im_target_color.depth() != CV_16U) {
    im_target_color.convertTo(im_target_color, CV_16U, 65535.0);
  }
  if (im_target_color.channels() == 4) {
    cv::cvtColor(im_target_color, im_target_color, cv::COLOR_BGRA2BGR);
  } else if (im_target_color.channels() == 1) {
    cv::cvtColor(im_target_color, im_target_color, cv::COLOR_GRAY2BGR);
  } else if (im_target_color.channels() != 3) {
    if (error) {
      *error = [NSError
          errorWithDomain:@"ImageAlignerDomain"
                     code:7
                 userInfo:@{
                   NSLocalizedDescriptionKey : @"未対応の画像チャンネル形式です"
                 }];
    }
    return nil;
  }
  cv::Mat im_aligned;
  cv::warpPerspective(im_target_color, im_aligned, homography,
                      cv::Size(im_base_gray.cols, im_base_gray.rows),
                      cv::INTER_LANCZOS4 // High-quality Lanczos 4x4 resampling
  );

  // BGR → RGB for NSImage
  cv::Mat im_rgb;
  cv::cvtColor(im_aligned, im_rgb, cv::COLOR_BGR2RGB);

  return [self NSImageFromMat:im_rgb];
}


+ (NSArray<NSNumber *> *)homographyFromGrayPixels:(NSData *)targetGray
                                     toBaseGray:(NSData *)baseGray
                                          width:(NSInteger)width
                                         height:(NSInteger)height
                                          error:(NSError **)error {
  if (width <= 0 || height <= 0 || targetGray.length < (NSUInteger)(width * height) ||
      baseGray.length < (NSUInteger)(width * height)) {
    if (error) {
      *error = [NSError errorWithDomain:@"ImageAlignerDomain"
                                   code:8
                               userInfo:@{NSLocalizedDescriptionKey : @"位置合わせ用の画素データが不正です"}];
    }
    return nil;
  }
  cv::Mat target((int)height, (int)width, CV_8UC1, (void *)targetGray.bytes);
  cv::Mat base((int)height, (int)width, CV_8UC1, (void *)baseGray.bytes);
  cv::Mat homography = EstimateHomography(target, base, error);
  if (homography.empty()) return nil;
  homography.convertTo(homography, CV_64F);
  NSMutableArray<NSNumber *> *values = [NSMutableArray arrayWithCapacity:9];
  for (int row = 0; row < 3; row++) {
    for (int col = 0; col < 3; col++) {
      [values addObject:@(homography.at<double>(row, col))];
    }
  }
  return values;
}

+ (BOOL)warpRGB16Pixels:(NSMutableData *)pixels
                  width:(NSInteger)width
                 height:(NSInteger)height
             homography:(NSArray<NSNumber *> *)homography
                  error:(NSError **)error {
  if (homography.count != 9 || width <= 0 || height <= 0 ||
      pixels.length < (NSUInteger)(width * height * 3 * sizeof(uint16_t))) {
    if (error) {
      *error = [NSError errorWithDomain:@"ImageAlignerDomain"
                                   code:9
                               userInfo:@{NSLocalizedDescriptionKey : @"変形する画素データが不正です"}];
    }
    return NO;
  }
  cv::Mat matrix(3, 3, CV_64F);
  for (int index = 0; index < 9; index++) {
    matrix.at<double>(index / 3, index % 3) = homography[index].doubleValue;
  }
  // 色空間の解釈を挟まず、16bitのカメラRGB値をそのまま変形する（範囲外は0）。
  cv::Mat source((int)height, (int)width, CV_16UC3, pixels.mutableBytes);
  cv::Mat warped;
  cv::warpPerspective(source, warped, matrix, source.size(), cv::INTER_LANCZOS4,
                      cv::BORDER_CONSTANT, cv::Scalar(0, 0, 0));
  if (!warped.isContinuous()) warped = warped.clone();
  memcpy(pixels.mutableBytes, warped.data, (size_t)(width * height * 3) * sizeof(uint16_t));
  return YES;
}

// ── Helper: cv::Mat → NSImage ──────────────────────────────────────────
+ (NSImage *)NSImageFromMat:(cv::Mat)cvMat {
  if (cvMat.empty() || (cvMat.depth() != CV_8U && cvMat.depth() != CV_16U)) {
    return nil;
  }
  if (!cvMat.isContinuous()) cvMat = cvMat.clone();
  NSData *data = [NSData dataWithBytes:cvMat.data
                                length:cvMat.step[0] * cvMat.rows];

  CGColorSpaceRef colorSpace = (cvMat.elemSize() == 1)
                                   ? CGColorSpaceCreateDeviceGray()
                                   : CGColorSpaceCreateDeviceRGB();

  CGDataProviderRef provider =
      CGDataProviderCreateWithCFData((__bridge CFDataRef)data);

  const size_t bitsPerComponent = cvMat.depth() == CV_16U ? 16 : 8;
  const CGBitmapInfo bitmapInfo = cvMat.depth() == CV_16U
      ? (kCGImageAlphaNone | kCGBitmapByteOrder16Little)
      : (kCGImageAlphaNone | kCGBitmapByteOrderDefault);
  CGImageRef imageRef = CGImageCreate(
      cvMat.cols, cvMat.rows, bitsPerComponent,
      bitsPerComponent * cvMat.channels(), cvMat.step[0],
      colorSpace, bitmapInfo, provider, NULL,
      false, kCGRenderingIntentDefault);

  if (!imageRef) {
    CGDataProviderRelease(provider);
    CGColorSpaceRelease(colorSpace);
    return nil;
  }

  NSImage *image =
      [[NSImage alloc] initWithCGImage:imageRef
                                  size:NSMakeSize(cvMat.cols, cvMat.rows)];
  CGImageRelease(imageRef);
  CGDataProviderRelease(provider);
  CGColorSpaceRelease(colorSpace);

  return image;
}

@end
