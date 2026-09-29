#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

/// 地上の風景（星を除く）で各フレームを基準画像に合わせる（新星景モードの地上側）。
///
/// 固定撮影ではほぼ動かないため、わずかな動き（画像の四隅で0.5px未満）は「動きなし」に揃える。
/// 追尾撮影では架台の動きで地上が動くため、その動きを求める。
@interface GroundAligner : NSObject

/// 基準画像（線形の輝度、float32、width * height 要素）の地上の特徴点を準備する
- (nullable instancetype)initWithBaseGray:(NSData *)gray
                                    width:(NSInteger)width
                                   height:(NSInteger)height
                                    error:(NSError **)error NS_DESIGNATED_INITIALIZER;

- (instancetype)init NS_UNAVAILABLE;

/// target の座標を基準画像の座標へ写す 3x3 ホモグラフィ（行優先9要素）。
/// @param initialGuess 予想される変換（隣のフレームの結果など）。nil なら制限なしで対応を探す
- (nullable NSArray<NSNumber *> *)homographyFromGray:(NSData *)gray
                                        initialGuess:(nullable NSArray<NSNumber *> *)initialGuess
                                               error:(NSError **)error;

@end

NS_ASSUME_NONNULL_END
