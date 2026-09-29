#import <Foundation/Foundation.h>
#import <AppKit/AppKit.h> // Since this is a Mac app

NS_ASSUME_NONNULL_BEGIN

@interface ImageAligner : NSObject

/// 画像全体の特徴点（AKAZE）で位置合わせする。地上の風景に合わせるタイムラプスの手ぶれ補正用。
/// 星の位置合わせには StarAligner を使う（地上の模様に引きずられるため）。
+ (NSImage * _Nullable)alignImageAtURL:(NSURL *)targetURL
                        toBaseImageAtURL:(NSURL *)baseURL
                                   error:(NSError **)error;

/// 画像ファイルをホモグラフィ（行優先9要素、画像の座標→基準の座標）で変形して返す（範囲外は黒）
+ (nullable NSImage *)warpImageAtURL:(NSURL *)url
                          homography:(NSArray<NSNumber *> *)homography
                               error:(NSError **)error;

/// 16bit RGBインターリーブ画素をホモグラフィで変形する（色空間変換なし、結果は同じバッファに書き戻す）
+ (BOOL)warpRGB16Pixels:(NSMutableData *)pixels
                  width:(NSInteger)width
                 height:(NSInteger)height
             homography:(NSArray<NSNumber *> *)homography
                  error:(NSError **)error;

@end

NS_ASSUME_NONNULL_END
