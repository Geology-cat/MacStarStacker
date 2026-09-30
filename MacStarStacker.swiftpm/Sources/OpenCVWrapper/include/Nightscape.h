#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

/// 新星景モードの空と地上の判定結果（すべて基準画像の座標・元の解像度）
@interface NightscapeMask : NSObject
/// 空の割合（float32、width * height、1=空・0=地上）。境界は画像の輪郭に沿って柔らかく変化する。仕上げの合成に使う
@property (nonatomic, readonly) NSData *skyAlpha;
/// 確実に空の画素（uint8、255=空）。空の合成に使う画素を選ぶ
@property (nonatomic, readonly) NSData *certainSky;
/// 地上の合成に使う画素（uint8、255=地上。半分以上地上の画素）
@property (nonatomic, readonly) NSData *certainGround;
/// 空と地上の両方がはっきり見つかったか（どちらかしか無い構図では分けて合成しない）
@property (nonatomic, readonly) BOOL hasBothRegions;
@property (nonatomic, readonly) NSInteger width;
@property (nonatomic, readonly) NSInteger height;

/// 与えた空の割合から判定結果を作る（テスト・手動マスク用）
- (instancetype)initWithSkyAlpha:(NSData *)skyAlpha width:(NSInteger)width height:(NSInteger)height;

/// 空と地上の境界を、半径（px、ガウスぼかしの標準偏差）の分だけさらにぼかした判定結果。
/// 空・地上をそれぞれ合成する範囲（certainSky・certainGround）は変えず、重ね合わせの比率（skyAlpha）だけをぼかす
- (NightscapeMask *)maskByFeatheringWithRadius:(double)radius NS_SWIFT_NAME(feathered(radius:));
@end

/// 各フレームの「星に合わせた画像」と「地上に合わせた画像」を縮小して集め、空と地上を自動で判定する。
///
/// 空は星に合わせるとフレームどうしが一致し、地上は地上に合わせると一致する（逆に合わせるとばらつく）。
/// 細かな構造（星・地上の模様や輪郭）のばらつきの差から「確実に空」「確実に地上」を決め、基準画像の色で境界を決め（GrabCut）、画像の輪郭に沿って
/// 柔らかいマスクに仕上げる（ガイドフィルタ）。
@interface NightscapeAnalyzer : NSObject

- (instancetype)initWithWidth:(NSInteger)width height:(NSInteger)height;

/// フレームを加える
/// @param gray 線形の輝度（float32、width * height）
/// @param rgb 16bit RGB（width * height * 3）
/// @param starHomography フレーム→基準画像（星に合わせる）
/// @param groundHomography フレーム→基準画像（地上に合わせる）
- (BOOL)addFrameGray:(NSData *)gray
                 rgb:(NSData *)rgb
      starHomography:(NSArray<NSNumber *> *)starHomography
    groundHomography:(NSArray<NSNumber *> *)groundHomography
               error:(NSError **)error;

/// 星と地上の動きの差の最大値（元の解像度のpx）。小さいときは分けて合成する必要が無い
@property (nonatomic, readonly) double maximumRelativeShift;

/// 空と地上を判定する
/// @param hints 利用者が塗った手がかり（uint8、width * height。1=空、2=地上、0=自動）。nil なら自動のみ
- (nullable NightscapeMask *)segmentWithHints:(nullable NSData *)hints error:(NSError **)error;

@end

/// 外れ値を除く基準（画素ごとの中央値）を求めるため、各フレームの輝度を記録する
@interface NightscapeSamples : NSObject

- (instancetype)initWithWidth:(NSInteger)width height:(NSInteger)height;

/// フレームの輝度（float32、width * height）を、星に合わせた座標と地上に合わせた座標で記録する
- (BOOL)addFrameGray:(NSData *)gray
      starHomography:(NSArray<NSNumber *> *)starHomography
    groundHomography:(NSArray<NSNumber *> *)groundHomography
               error:(NSError **)error;

@property (nonatomic, readonly) NSInteger frameCount;

@end

/// 空は星に合わせて、地上は地上に合わせて合成し、判定結果で重ね合わせる。
///
/// - 空: 各フレームの「確実に空」の範囲を、そのフレームの動きに合わせて変形し、各画素で本当に空だった枚数だけ
///   平均する（地上のシルエットが空に入り込まない）。
/// - 地上: 画面全体を地上に合わせて平均する。空の部分は動く星が外れ値として除かれ、星のない空（光害フレーム）になる。
/// - 画素ごとの中央値から大きく外れた値（紛れ込んだ地上・動く星・飛行機や人工衛星の光）は除く。
/// - 空には、地上との境界から空の奥へなだらかに弱まる強さで、星のない空に星を重ねたもの（光害フレーム）を比較明で
///   合わせる。地平線付近の光害は地上に対して動かないため自然につながり、継ぎ目が暗く沈まず、星も薄くならない。
/// - 地上は判定結果の境界（ほぼ切り抜き）で一番上に重ねる。空のデータが無い画素は星のない空で埋める。
@interface NightscapeAccumulator : NSObject

/// @param samples 外れ値を除く基準。nil なら除かない
- (instancetype)initWithMask:(NightscapeMask *)mask samples:(nullable NightscapeSamples *)samples;

- (BOOL)addFrameRGB:(NSData *)rgb
     starHomography:(NSArray<NSNumber *> *)starHomography
   groundHomography:(NSArray<NSNumber *> *)groundHomography
              error:(NSError **)error;

/// 合成結果（16bit RGB、width * height * 3）
- (nullable NSData *)composeWithError:(NSError **)error;

@property (nonatomic, readonly) NSInteger frameCount;

@end

NS_ASSUME_NONNULL_END
