#import <Foundation/Foundation.h>
#import <AppKit/AppKit.h>

NS_ASSUME_NONNULL_BEGIN

/// 検出された光跡の解析結果
@interface TrailDetectionResult : NSObject

@property (nonatomic, assign) NSInteger frameIndex;
@property (nonatomic, copy) NSString *filePath;
@property (nonatomic, strong, nullable) NSImage *originalImage;      // ハイライトのない元画像
@property (nonatomic, strong, nullable) NSImage *maskImage;          // 2値マスク画像（白=光跡）
@property (nonatomic, strong, nullable) NSImage *highlightedImage;   // 光跡を赤くハイライトした元画像
@property (nonatomic, strong, nullable) NSImage *repairedImage;      // 光跡を除去・修復したプレビュー画像
@property (nonatomic, assign) NSRect detectedBounds;                // 解析画像上の候補範囲（左上原点相当）
@property (nonatomic, copy) NSString *detectedType;                 // "飛行機 (点滅)" / "人工衛星 (直線)" / "移動光跡"
@property (nonatomic, assign) double confidenceScore;               // 0.0 ~ 1.0
@property (nonatomic, assign) BOOL isLikelyMeteor;                  // 流星の可能性（片側が急峻に明るい・発光バースト等）
@property (nonatomic, assign) BOOL isMarkedForRemoval;              // 除去フラグ（デフォルトYES）

@end

/// OpenCVを用いた飛行機・人工衛星・車の光跡検出およびインペイント修復クラス
@interface TrailCleaner : NSObject

/// 連続する画像フレーム群を解析し、人工の光跡が含まれるフレームとマスクを検出する
+ (NSArray<TrailDetectionResult *> *)detectTrailsInImageURLs:(NSArray<NSURL *> *)imageURLs
                                            progressCallback:(void (^ _Nullable)(double progress, NSString *status))progressCallback;

/// 単一フレームについて、指定されたマスク領域を周囲または前後フレームを参照して修復（Inpaint）する
+ (nullable NSImage *)inpaintImageAtURL:(NSURL *)targetURL
                              withMask:(NSImage *)maskImage
                         prevFrameURL:(nullable NSURL *)prevURL
                         nextFrameURL:(nullable NSURL *)nextURL;

/// 複数の候補マスクを統合し、前後フレームのロバストな中央値で修復する
+ (nullable NSImage *)inpaintImageAtURL:(NSURL *)targetURL
                              withMasks:(NSArray<NSImage *> *)maskImages
                          prevFrameURL:(nullable NSURL *)prevURL
                          nextFrameURL:(nullable NSURL *)nextURL;

@end

NS_ASSUME_NONNULL_END
