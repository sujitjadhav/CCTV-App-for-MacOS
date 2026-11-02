// Converts XMEye private recordings (.h264 downloaded over DVRIP) to MP4.
// Video is copied as-is (H.264 / H.265), G.711A audio becomes AAC.

#import <Foundation/Foundation.h>
#import <AVFoundation/AVFoundation.h>

NS_ASSUME_NONNULL_BEGIN

extern NSErrorDomain const CCTVConvertErrorDomain;

typedef NS_ERROR_ENUM(CCTVConvertErrorDomain, CCTVConvertErrorCode) {
    CCTVConvertErrorRead = 1,     // input missing or unreadable
    CCTVConvertErrorFormat = 2,   // no video found in the file
    CCTVConvertErrorRange = 3,    // startOffset is past the end
    CCTVConvertErrorWrite = 4,    // ffmpeg / disk failure while writing the MP4
};

@interface CCTVConvert : NSObject

/// Reads the private frame headers. Keys: start, end (NSDate of first/last I-frame, NVR wall
/// clock interpreted in `tz`), width, height, fps, codec ("h264"/"h265"), hasAudio,
/// duration (seconds, from frame count), frames (video frame count).
/// Plain Annex B files give codec/width/height/duration only (no start/end).
/// Returns nil if the file has no recognisable video.
+ (nullable NSDictionary<NSString *, id> *)probeXMEyeFile:(NSString *)path timeZone:(NSTimeZone *)tz;

/// Writes an MP4 (+faststart). start/duration are seconds from the beginning of the recording;
/// duration 0 = to the end. Output starts at the I-frame at or before `start`.
/// `progress` (0...1) and `cancel` are called on the calling thread; this call blocks, so run it
/// off the main thread. Cancelling deletes the output and fails with NSUserCancelledError.
+ (BOOL)convertXMEyeFile:(NSString *)input
                   toMP4:(NSString *)output
             startOffset:(double)start
                duration:(double)duration
                progress:(nullable void (^)(double fraction))progress
                  cancel:(nullable BOOL (^)(void))cancelled
                   error:(NSError **)error;

/// Same as probeXMEyeFile, for a recording held in memory.
+ (nullable NSDictionary<NSString *, id> *)probeXMEyeData:(NSData *)data timeZone:(NSTimeZone *)tz;

/// Converts a recording held in memory to MP4 bytes in memory — nothing is written to disk.
/// (moov at the end, which AVPlayer handles fine.)
+ (nullable NSData *)convertXMEyeData:(NSData *)data
                          startOffset:(double)start
                             duration:(double)duration
                             progress:(nullable void (^)(double fraction))progress
                               cancel:(nullable BOOL (^)(void))cancelled
                                error:(NSError **)error;

@end

/// Plays an XMEye recording while it is still arriving from the NVR (memory only, nothing on disk).
/// Feed bytes with appendData:, call finishData when the download ends. Video only.
@interface CCTVPlayback : NSObject
- (instancetype)initWithLayer:(AVSampleBufferDisplayLayer *)layer timeZone:(NSTimeZone *)tz;
- (instancetype)init NS_UNAVAILABLE;
- (void)appendData:(NSData *)chunk;          // any thread
- (void)finishData;
- (void)stop;
/// 0 = paused, 1 = normal, 2/4/8 = fast forward.
@property (nonatomic) float rate;
/// NVR wall-clock time of the first frame received.
@property (nonatomic, readonly, nullable) NSDate *startDate;
/// Seconds since startDate: current playback position / how far video has arrived.
@property (nonatomic, readonly) double position;
@property (nonatomic, readonly) double buffered;
@property (nonatomic, readonly) BOOL finished;
@property (nonatomic, readonly) BOOL hasPicture;
@property (nonatomic, readonly, getter=isStalled) BOOL stalled;
@property (nonatomic, readonly) size_t bytesReceived;
/// Jumps within the part that has arrived; NO if that time hasn't arrived yet.
- (BOOL)seekTo:(double)seconds;
/// Main queue: playback reached the end of a fully downloaded recording.
@property (nonatomic, copy, nullable) void (^onEnded)(void);
@end

NS_ASSUME_NONNULL_END
