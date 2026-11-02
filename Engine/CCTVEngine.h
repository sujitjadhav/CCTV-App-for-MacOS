// Low-level video engine (ffmpeg + VideoToolbox). Swift sees only this header.
// Never logs URLs: they contain the NVR login.

#import <Foundation/Foundation.h>
#import <AVFoundation/AVFoundation.h>
#import <CoreGraphics/CoreGraphics.h>

NS_ASSUME_NONNULL_BEGIN

typedef NS_ENUM(NSInteger, CCTVStreamState) {
    CCTVStreamStateConnecting,
    CCTVStreamStateLive,
    CCTVStreamStateError,
};

typedef NS_ENUM(NSInteger, CCTVErrorKind) {
    CCTVErrorKindNone,
    CCTVErrorKindAuth,          // 401/403 — stream stops retrying
    CCTVErrorKindUnreachable,   // no route / timeout / refused (may be Local Network permission)
    CCTVErrorKindOther,
};

/// One live RTSP stream rendered into an AVSampleBufferDisplayLayer with minimal latency.
/// Reconnects automatically with backoff (except on login failures).
@interface CCTVStream : NSObject
- (instancetype)initWithURL:(NSString *)url layer:(AVSampleBufferDisplayLayer *)layer;
- (instancetype)init NS_UNAVAILABLE;
/// Called on the main queue. retryIn = seconds until the next attempt, -1 = not retrying.
@property (nonatomic, copy, nullable) void (^onState)(CCTVStreamState state, CCTVErrorKind kind, NSString *_Nullable message, NSInteger retryIn);
/// Called on the main queue once the stream is opened.
@property (nonatomic, copy, nullable) void (^onAudioAvailable)(BOOL hasAudio);
- (void)start;
- (void)stop;
- (void)setAudioEnabled:(BOOL)on;
/// Sound volume 0…1 (when audio is enabled).
@property (nonatomic) float volume;
/// Recent sound level 0…1 for a level meter (0 when nothing arrives).
@property (nonatomic, readonly) float audioLevel;
/// Latest decoded frame, or NULL if nothing has been shown yet.
- (nullable CGImageRef)copySnapshot CF_RETURNS_RETAINED;
/// Size of the last decoded frame (0x0 before the first frame).
@property (nonatomic, readonly) CGSize videoSize;
/// Frames displayed since the last call (debug stats).
- (int)takeFrameCount;
@end

NS_ASSUME_NONNULL_END
