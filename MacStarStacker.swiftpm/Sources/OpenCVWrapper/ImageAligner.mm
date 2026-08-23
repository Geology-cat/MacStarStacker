#import <opencv2/core.hpp>
#import <opencv2/imgproc.hpp>
#import <opencv2/imgcodecs.hpp>
#import <opencv2/features2d.hpp>
#import <opencv2/calib3d.hpp>

#import "ImageAligner.h"

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
      return nil;
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
    return nil;
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
    return nil;
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
