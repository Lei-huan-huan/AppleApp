#import <CoreVideo/CoreVideo.h>
#import <Foundation/Foundation.h>

// 解封装/解码节拍对齐 Android LearnFFmpeg（app/src/main/cpp/ff_player.cpp）；
// 渲染为 NV12 + Metal（Android 侧为 RGBA + ANativeWindow）。

NS_ASSUME_NONNULL_BEGIN

@class FFmpegDemuxerPlayer;

@protocol FFmpegDemuxerPlayerDelegate <NSObject>
@optional
/// 解码线程因 EOF 正常结束（主线程回调）
- (void)ffmpegPlayerDidCompletePlayback:(FFmpegDemuxerPlayer *)player;
/// 读包/解码失败（主线程回调）
- (void)ffmpegPlayer:(FFmpegDemuxerPlayer *)player didFailWithCode:(int)code message:(NSString *)message;
@end

@interface FFmpegDemuxerPlayer : NSObject

@property (nonatomic, weak, nullable) id<FFmpegDemuxerPlayerDelegate> delegate;

- (BOOL)ffOpenMedia:(NSURL *)url error:(NSError *__autoreleasing _Nullable *_Nullable)error;
- (void)close;

/// 启动后台解码线程（open 成功后调用）
- (void)start;
/// 中断并 join 解码线程（与 Android NativePlayer.stop 一致）
- (void)stop;

/// 应用退后台时暂停解码节拍（对齐 PlayerViewModel.onLeaveForeground）
- (void)pauseDecoding;
/// 回前台恢复（对齐 onEnterForeground）
- (void)resumeDecoding;

/// 返回 +1 retain 的 NV12（BiPlanar Full Range）像素缓冲，供 Metal 采样。
- (nullable CVPixelBufferRef)copyLatestPixelBuffer CF_RETURNS_RETAINED;

@property (nonatomic, readonly) CGSize videoSize;
@property (nonatomic, readonly) double frameDuration;
/// 容器时长（毫秒），未知时为 0；与 Android Prepared.durationMs 一致
@property (nonatomic, readonly) int64_t durationMs;

@end

NS_ASSUME_NONNULL_END
