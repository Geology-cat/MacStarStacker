#import <Foundation/Foundation.h>
#import <AppKit/AppKit.h> // Since this is a Mac app

NS_ASSUME_NONNULL_BEGIN

@interface ImageAligner : NSObject

/// Align the given raw image URL against the base image URL and return the aligned image
+ (NSImage * _Nullable)alignImageAtURL:(NSURL *)targetURL
                        toBaseImageAtURL:(NSURL *)baseURL
                                   error:(NSError **)error;

/// 8bitグレースケール画素（同じ寸法）から、target を base に重ねる 3x3 ホモグラフィ（行優先9要素）を推定する
+ (nullable NSArray<NSNumber *> *)homographyFromGrayPixels:(NSData *)targetGray
                                              toBaseGray:(NSData *)baseGray
                                                   width:(NSInteger)width
                                                  height:(NSInteger)height
                                                   error:(NSError **)error;

/// 16bit RGBインターリーブ画素をホモグラフィで変形する（色空間変換なし、結果は同じバッファに書き戻す）
+ (BOOL)warpRGB16Pixels:(NSMutableData *)pixels
                  width:(NSInteger)width
                 height:(NSInteger)height
             homography:(NSArray<NSNumber *> *)homography
                  error:(NSError **)error;

@end

NS_ASSUME_NONNULL_END
