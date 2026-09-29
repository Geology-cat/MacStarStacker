#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

/// タイムラプスの揺れ補正（手ぶれ・三脚のずれ・追尾架台による地上の動き）。
///
/// 日周運動で動く星を除いた地上の風景で、隣り合うフレームどうしを順に位置合わせし、
/// 最初のフレームに揃える変換を積み重ねる。数時間の撮影で空の明るさ（薄明→夜）が大きく
/// 変わっても、隣のフレームとは似ているため合わせられる。
@interface TimelapseStabilizer : NSObject

/// 次のフレームを渡し、そのフレームを最初のフレームに揃える 3x3 ホモグラフィ（行優先9要素）を返す。
/// 最初のフレームは恒等変換。前のフレームと合わせられなかったときは、前のフレームと同じ変換を返す
/// （動いていないものとして扱い、failedFrameCount を増やす）。画像を読めないときだけエラーになる。
- (nullable NSArray<NSNumber *> *)homographyForImageAtURL:(NSURL *)url error:(NSError **)error;

/// 前のフレームと合わせられなかったフレームの数
@property (nonatomic, readonly) NSInteger failedFrameCount;

@end

NS_ASSUME_NONNULL_END
