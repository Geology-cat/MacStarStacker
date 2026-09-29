#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

/// 星だけを手がかりにした位置合わせ。
///
/// 画像全体の特徴点（AKAZE等）で位置合わせすると、特徴点の多い地上の風景に引きずられ、
/// 固定撮影では地上に合って星がずれ、追尾撮影では動いた地上に合わせて星をずらしてしまう。
/// ここでは点光源（星）だけを検出し、星どうしの対応からホモグラフィを求める。
@interface StarAligner : NSObject

/// 基準画像から星を検出して準備する。
/// @param gray   線形の輝度（float32、width * height 要素）。明るさの尺度は問わない
/// @param skyMask 空の範囲（uint8、width * height 要素、0 以外が空）。nil なら画像全体から探す
- (nullable instancetype)initWithBaseGray:(NSData *)gray
                                    width:(NSInteger)width
                                   height:(NSInteger)height
                                  skyMask:(nullable NSData *)skyMask
                                    error:(NSError **)error NS_DESIGNATED_INITIALIZER;

/// 画像ファイル（8bit/16bit）を読み込んで基準にする。
- (nullable instancetype)initWithBaseImageAtURL:(NSURL *)url
                                        skyMask:(nullable NSData *)skyMask
                                          error:(NSError **)error;

- (instancetype)init NS_UNAVAILABLE;

/// 基準画像で見つかった星の数
@property (nonatomic, readonly) NSInteger baseStarCount;
@property (nonatomic, readonly) NSInteger width;
@property (nonatomic, readonly) NSInteger height;

/// target の座標を基準画像の座標へ写す 3x3 ホモグラフィ（行優先9要素）を求める。
/// @param initialGuess 予想される変換（隣のフレームの結果など）。nil なら星の位置の差の投票で初期値を求める
- (nullable NSArray<NSNumber *> *)homographyFromGray:(NSData *)gray
                                        initialGuess:(nullable NSArray<NSNumber *> *)initialGuess
                                               error:(NSError **)error;

- (nullable NSArray<NSNumber *> *)homographyForImageAtURL:(NSURL *)url
                                             initialGuess:(nullable NSArray<NSNumber *> *)initialGuess
                                                    error:(NSError **)error;

@end

NS_ASSUME_NONNULL_END
