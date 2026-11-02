// ffmpeg handles RTSP, VideoToolbox decodes on the GPU, and frames are shown the
// moment they're decoded (no jitter buffer) for the lowest possible delay.

#import "CCTVEngine.h"
#import <CoreMedia/CoreMedia.h>
#import <CoreVideo/CoreVideo.h>
#import <CoreImage/CoreImage.h>
#include <os/lock.h>
#include <stdatomic.h>
#include <libavformat/avformat.h>
#include <libavcodec/avcodec.h>
#include <libavutil/hwcontext.h>
#include <libavutil/time.h>
#include <libavutil/channel_layout.h>
#include <libavutil/audio_fifo.h>
#include <libswscale/swscale.h>
#include <libswresample/swresample.h>

#pragma mark - Shared helpers

typedef struct {
    atomic_bool stop;
    atomic_bool audio;
    _Atomic int64_t lastActivity;
    atomic_int queuedSamples;
    atomic_int audioGen;
    _Atomic int64_t lastAudioDone;
    atomic_int statFrames;
    atomic_int width, height;
} StreamCtl;

static int interruptCB(void *opaque) {
    StreamCtl *c = opaque;
    if (atomic_load(&c->stop)) return 1;
    // Watchdog: nothing received for 8s -> treat as dropped and reconnect.
    if (av_gettime_relative() - atomic_load(&c->lastActivity) > 8000000) return 1;
    return 0;
}

static void initFFmpeg(void) {
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        av_log_set_level(AV_LOG_QUIET); // ffmpeg logs can include URLs (and so the password)
        avformat_network_init();
    });
}

static NSString *avErr(int e) {
    char buf[256];
    av_strerror(e, buf, sizeof buf);
    return [NSString stringWithUTF8String:buf];
}

static AVFormatContext *openInput(NSString *url, StreamCtl *ctl, BOOL lowLatency, int *err) {
    AVFormatContext *fmt = avformat_alloc_context();
    fmt->interrupt_callback.callback = interruptCB;
    fmt->interrupt_callback.opaque = ctl;
    atomic_store(&ctl->lastActivity, av_gettime_relative());
    AVDictionary *o = NULL;
    av_dict_set(&o, "rtsp_transport", "tcp", 0);
    av_dict_set(&o, "timeout", "5000000", 0);
    av_dict_set(&o, "buffer_size", "4194304", 0);
    if (lowLatency) {
        av_dict_set(&o, "fflags", "nobuffer+discardcorrupt", 0);
        av_dict_set(&o, "flags", "low_delay", 0);
        av_dict_set(&o, "max_delay", "0", 0);
        av_dict_set(&o, "reorder_queue_size", "0", 0);
        av_dict_set(&o, "probesize", "500000", 0);
        av_dict_set(&o, "analyzeduration", "500000", 0);
    } else {
        av_dict_set(&o, "probesize", "2000000", 0);
        av_dict_set(&o, "analyzeduration", "1500000", 0);
    }
    int r = avformat_open_input(&fmt, url.UTF8String, NULL, &o);
    av_dict_free(&o);
    if (r < 0) { *err = r; return NULL; } // fmt already freed
    if ((r = avformat_find_stream_info(fmt, NULL)) < 0) { *err = r; avformat_close_input(&fmt); return NULL; }
    *err = 0;
    return fmt;
}

static CCTVErrorKind classify(int r, NSString **msg) {
    if (r == AVERROR_HTTP_UNAUTHORIZED || r == AVERROR_HTTP_FORBIDDEN) { *msg = @"Wrong username or password"; return CCTVErrorKindAuth; }
    if (r == AVERROR_HTTP_NOT_FOUND) { *msg = @"This channel doesn't exist on the NVR"; return CCTVErrorKindOther; }
    if (r == AVERROR(EHOSTUNREACH) || r == AVERROR(ENETUNREACH) || r == AVERROR(EPERM) || r == AVERROR(EACCES)) {
        *msg = @"Can't reach the NVR"; return CCTVErrorKindUnreachable;
    }
    if (r == AVERROR(ECONNREFUSED)) { *msg = @"NVR refused the connection (check the port)"; return CCTVErrorKindUnreachable; }
    if (r == AVERROR(ETIMEDOUT) || r == AVERROR_EXIT) { *msg = @"NVR not responding"; return CCTVErrorKindUnreachable; }
    if (r == AVERROR_EOF) { *msg = @"Stream ended"; return CCTVErrorKindOther; }
    *msg = avErr(r);
    return CCTVErrorKindOther;
}

#pragma mark - Audio hub (one shared engine, one player node per stream)

@interface CCTVAudioHub : NSObject
@property (readonly) AVAudioEngine *engine;
@property (readonly) dispatch_queue_t queue;
+ (instancetype)shared;
- (nullable AVAudioPlayerNode *)playerForSampleRate:(double)rate;
- (void)removePlayer:(AVAudioPlayerNode *)p;
@end

@implementation CCTVAudioHub
+ (instancetype)shared {
    static CCTVAudioHub *h; static dispatch_once_t once;
    dispatch_once(&once, ^{ h = [CCTVAudioHub new]; });
    return h;
}
- (instancetype)init {
    if ((self = [super init])) {
        _engine = [AVAudioEngine new];
        _queue = dispatch_queue_create("cctv.audio", DISPATCH_QUEUE_SERIAL);
        (void)_engine.mainMixerNode;
        __weak CCTVAudioHub *w = self;
        [[NSNotificationCenter defaultCenter] addObserverForName:AVAudioEngineConfigurationChangeNotification
                                                          object:_engine queue:nil usingBlock:^(NSNotification *n) {
            CCTVAudioHub *s = w; if (!s) return;
            dispatch_async(s.queue, ^{ [s startIfNeeded]; });
        }];
    }
    return self;
}
- (void)startIfNeeded {
    if (!_engine.isRunning && _engine.attachedNodes.count > 2) [_engine startAndReturnError:nil];
}
- (AVAudioPlayerNode *)playerForSampleRate:(double)rate {
    __block AVAudioPlayerNode *p = nil;
    dispatch_sync(_queue, ^{
        AVAudioFormat *fmt = [[AVAudioFormat alloc] initStandardFormatWithSampleRate:rate channels:1];
        if (!fmt) return;
        p = [AVAudioPlayerNode new];
        [self->_engine attachNode:p];
        [self->_engine connect:p to:self->_engine.mainMixerNode format:fmt];
        [self startIfNeeded];
    });
    return p;
}
- (void)removePlayer:(AVAudioPlayerNode *)p {
    dispatch_async(_queue, ^{
        [p stop];
        [self->_engine detachNode:p];
    });
}
@end

#pragma mark - Live stream

@interface CCTVStream ()
@property (atomic, strong, nullable) AVAudioPlayerNode *player;
@end

@implementation CCTVStream {
    NSString *_url;
    StreamCtl *_ctl;
    AVSampleBufferDisplayLayer *_layer;
    CMVideoFormatDescriptionRef _fmtDesc;
    struct SwsContext *_sws;
    CVPixelBufferPoolRef _pool;
    int _swsW, _swsH, _swsFmt;
    os_unfair_lock _snapLock;
    CVPixelBufferRef _lastFrame;
}

- (instancetype)initWithURL:(NSString *)url layer:(AVSampleBufferDisplayLayer *)layer {
    if ((self = [super init])) {
        initFFmpeg();
        _url = [url copy];
        _layer = layer;
        _ctl = calloc(1, sizeof(StreamCtl));
        _snapLock = OS_UNFAIR_LOCK_INIT;
    }
    return self;
}

- (void)dealloc {
    if (_fmtDesc) CFRelease(_fmtDesc);
    if (_pool) CVPixelBufferPoolRelease(_pool);
    if (_sws) sws_freeContext(_sws);
    if (_lastFrame) CVPixelBufferRelease(_lastFrame);
    free(_ctl);
}

- (void)start {
    NSThread *t = [[NSThread alloc] initWithTarget:self selector:@selector(threadMain) object:nil];
    t.qualityOfService = NSQualityOfServiceUserInteractive;
    t.name = @"cctv.stream";
    [t start];
}

- (void)stop {
    atomic_store(&_ctl->stop, true);
    [self setAudioEnabled:NO];
}

- (int)takeFrameCount { return atomic_exchange(&_ctl->statFrames, 0); }
- (CGSize)videoSize { return CGSizeMake(atomic_load(&_ctl->width), atomic_load(&_ctl->height)); }

- (void)setAudioEnabled:(BOOL)on {
    atomic_store(&_ctl->audio, on);
    if (!on) {
        AVAudioPlayerNode *p = self.player;
        StreamCtl *c = _ctl;
        if (p) dispatch_async([CCTVAudioHub shared].queue, ^{
            atomic_fetch_add(&c->audioGen, 1);
            [p stop];
            atomic_store(&c->queuedSamples, 0);
            (void)self; // keeps ctl alive until this runs
        });
    }
}

- (CGImageRef)copySnapshot {
    os_unfair_lock_lock(&_snapLock);
    CVPixelBufferRef pb = _lastFrame ? CVPixelBufferRetain(_lastFrame) : NULL;
    os_unfair_lock_unlock(&_snapLock);
    if (!pb) return NULL;
    static CIContext *ctx;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ ctx = [CIContext contextWithOptions:nil]; });
    CIImage *img = [CIImage imageWithCVPixelBuffer:pb];
    CGImageRef cg = [ctx createCGImage:img fromRect:img.extent];
    CVPixelBufferRelease(pb);
    return cg;
}

- (void)emit:(CCTVStreamState)st kind:(CCTVErrorKind)k message:(NSString *)m retry:(NSInteger)retry {
    if (atomic_load(&_ctl->stop)) return;
    void (^cb)(CCTVStreamState, CCTVErrorKind, NSString *, NSInteger) = self.onState;
    if (cb) dispatch_async(dispatch_get_main_queue(), ^{ cb(st, k, m, retry); });
}

- (void)threadMain {
    int backoff = 2;
    while (!atomic_load(&_ctl->stop)) {
        @autoreleasepool {
            [self emit:CCTVStreamStateConnecting kind:CCTVErrorKindNone message:nil retry:0];
            BOOL wasLive = NO;
            int err = [self runSession:&wasLive];
            if (atomic_load(&_ctl->stop)) break;
            NSString *msg = @"Connection lost";
            CCTVErrorKind kind = err ? classify(err, &msg) : CCTVErrorKindOther;
            if (wasLive && kind != CCTVErrorKindAuth) msg = @"Connection lost";
            if (kind == CCTVErrorKindAuth) {
                // Don't hammer the NVR with a bad login — it may lock the account.
                [self emit:CCTVStreamStateError kind:kind message:msg retry:-1];
                break;
            }
            if (wasLive) backoff = 2;
            [self emit:CCTVStreamStateError kind:kind message:msg retry:backoff];
            for (int i = 0; i < backoff * 10 && !atomic_load(&_ctl->stop); i++) usleep(100000);
            backoff = MIN(backoff * 2, 15); // 2, 4, 8, 15, 15… so a rebooted NVR is picked up quickly
        }
    }
}

// Returns the ffmpeg error that ended the session (0 if none).
- (int)runSession:(BOOL *)wasLive {
    int err = 0;
    AVCodecContext *vctx = NULL, *actx = NULL;
    AVBufferRef *hw = NULL;
    SwrContext *swr = NULL;
    AVPacket *pkt = av_packet_alloc();
    AVFrame *frame = av_frame_alloc();
    AVAudioPlayerNode *player = nil;
    double audioRate = 0;

    AVFormatContext *fmt = openInput(_url, _ctl, YES, &err);
    if (!fmt) goto done;

    const AVCodec *vcodec = NULL, *acodec = NULL;
    int vidx = av_find_best_stream(fmt, AVMEDIA_TYPE_VIDEO, -1, -1, &vcodec, 0);
    int aidx = av_find_best_stream(fmt, AVMEDIA_TYPE_AUDIO, -1, -1, &acodec, 0);
    if (vidx < 0 || !vcodec) { err = AVERROR_STREAM_NOT_FOUND; goto done; }

    vctx = avcodec_alloc_context3(vcodec);
    avcodec_parameters_to_context(vctx, fmt->streams[vidx]->codecpar);
    vctx->flags |= AV_CODEC_FLAG_LOW_DELAY;
    vctx->flags2 |= AV_CODEC_FLAG2_FAST;
    if (av_hwdevice_ctx_create(&hw, AV_HWDEVICE_TYPE_VIDEOTOOLBOX, NULL, NULL, 0) == 0) {
        vctx->hw_device_ctx = av_buffer_ref(hw);
        vctx->thread_count = 1;
    } else {
        vctx->thread_type = FF_THREAD_SLICE;
        vctx->thread_count = 0;
    }
    if ((err = avcodec_open2(vctx, vcodec, NULL)) < 0) goto done;
    err = 0;

    if (aidx >= 0 && acodec) {
        actx = avcodec_alloc_context3(acodec);
        avcodec_parameters_to_context(actx, fmt->streams[aidx]->codecpar);
        if (actx->ch_layout.nb_channels == 0) av_channel_layout_default(&actx->ch_layout, 1);
        if (avcodec_open2(actx, acodec, NULL) < 0) avcodec_free_context(&actx);
    }
    {
        BOOL has = actx != NULL;
        void (^cb)(BOOL) = self.onAudioAvailable;
        if (cb) dispatch_async(dispatch_get_main_queue(), ^{ cb(has); });
    }

    BOOL live = NO;
    while (!atomic_load(&_ctl->stop)) {
        @autoreleasepool {
            int r = av_read_frame(fmt, pkt);
            if (r == AVERROR(EAGAIN)) { usleep(2000); continue; }
            if (r < 0) { err = r; break; }
            atomic_store(&_ctl->lastActivity, av_gettime_relative());

            if (pkt->stream_index == vidx) {
                if (avcodec_send_packet(vctx, pkt) >= 0) {
                    while (avcodec_receive_frame(vctx, frame) >= 0) {
                        if ([self displayFrame:frame] && !live) {
                            live = YES; *wasLive = YES;
                            [self emit:CCTVStreamStateLive kind:CCTVErrorKindNone message:nil retry:0];
                        }
                        av_frame_unref(frame);
                    }
                }
            } else if (pkt->stream_index == aidx && actx && atomic_load(&_ctl->audio)) {
                if (avcodec_send_packet(actx, pkt) >= 0) {
                    while (avcodec_receive_frame(actx, frame) >= 0) {
                        if (!swr || frame->sample_rate != audioRate) {
                            swr_free(&swr);
                            if (player) { [[CCTVAudioHub shared] removePlayer:player]; player = nil; self.player = nil; }
                            AVChannelLayout mono = AV_CHANNEL_LAYOUT_MONO;
                            AVChannelLayout in = frame->ch_layout;
                            if (in.nb_channels == 0) in = actx->ch_layout;
                            if (swr_alloc_set_opts2(&swr, &mono, AV_SAMPLE_FMT_FLTP, frame->sample_rate,
                                                    &in, frame->format, frame->sample_rate, 0, NULL) < 0 ||
                                swr_init(swr) < 0) { swr_free(&swr); av_frame_unref(frame); continue; }
                            audioRate = frame->sample_rate;
                            player = [[CCTVAudioHub shared] playerForSampleRate:audioRate];
                            self.player = player;
                        }
                        if (player) [self playAudioFrame:frame swr:swr player:player rate:audioRate];
                        av_frame_unref(frame);
                    }
                }
            }
            av_packet_unref(pkt);
        }
    }

done:
    if (player) { self.player = nil; [[CCTVAudioHub shared] removePlayer:player]; }
    swr_free(&swr);
    av_packet_free(&pkt);
    av_frame_free(&frame);
    avcodec_free_context(&vctx);
    avcodec_free_context(&actx);
    av_buffer_unref(&hw);
    if (fmt) avformat_close_input(&fmt);
    return err;
}

- (void)playAudioFrame:(AVFrame *)frame swr:(SwrContext *)swr player:(AVAudioPlayerNode *)player rate:(double)rate {
    CCTVAudioHub *hub = [CCTVAudioHub shared];
    StreamCtl *c = _ctl;
    if (!player.isPlaying) {
        dispatch_sync(hub.queue, ^{
            if (hub.engine.isRunning && !player.isPlaying && atomic_load(&c->audio)) {
                @try { [player play]; } @catch (NSException *e) {}
            }
        });
        if (!player.isPlaying) return;
    }
    int cap = swr_get_out_samples(swr, frame->nb_samples);
    if (cap <= 0) return;
    AVAudioPCMBuffer *buf = [[AVAudioPCMBuffer alloc] initWithPCMFormat:[player outputFormatForBus:0] frameCapacity:cap];
    if (!buf) return;
    uint8_t *out[1] = { (uint8_t *)buf.floatChannelData[0] };
    int n = swr_convert(swr, out, cap, (const uint8_t **)frame->extended_data, frame->nb_samples);
    if (n <= 0) return;
    buf.frameLength = n;

    // Keep at most ~500ms queued so sound stays in sync with the live picture.
    int64_t now = av_gettime_relative();
    if (atomic_load(&c->queuedSamples) > rate * 0.5) {
        // Queue looks full. If nothing played for 0.5s the engine dropped our buffers
        // (happens on audio device changes) — reset and carry on.
        if (now - atomic_load(&c->lastAudioDone) < 500000) return;
        dispatch_sync(hub.queue, ^{
            atomic_fetch_add(&c->audioGen, 1);
            atomic_store(&c->queuedSamples, 0);
            [player stop];
            if (hub.engine.isRunning) { @try { [player play]; } @catch (NSException *e) {} }
        });
    }
    if (atomic_load(&c->queuedSamples) == 0) atomic_store(&c->lastAudioDone, now);
    int gen = atomic_load(&c->audioGen);
    atomic_fetch_add(&c->queuedSamples, n);
    CCTVStream *keep = self;
    [player scheduleBuffer:buf completionHandler:^{
        if (atomic_load(&c->audioGen) == gen) atomic_fetch_sub(&c->queuedSamples, n);
        atomic_store(&c->lastAudioDone, av_gettime_relative());
        (void)keep;
    }];
}

- (BOOL)displayFrame:(AVFrame *)frame {
    CVPixelBufferRef pb = NULL;
    if (frame->format == AV_PIX_FMT_VIDEOTOOLBOX) {
        pb = CVPixelBufferRetain((CVPixelBufferRef)frame->data[3]);
    } else {
        pb = [self convertSoftwareFrame:frame];
    }
    if (!pb) return NO;

    AVSampleBufferVideoRenderer *rend = _layer.sampleBufferRenderer;
    if (rend.status == AVQueuedSampleBufferRenderingStatusFailed) [rend flush];

    if (!_fmtDesc || !CMVideoFormatDescriptionMatchesImageBuffer(_fmtDesc, pb)) {
        if (_fmtDesc) { CFRelease(_fmtDesc); _fmtDesc = NULL; }
        CMVideoFormatDescriptionCreateForImageBuffer(kCFAllocatorDefault, pb, &_fmtDesc);
    }
    BOOL ok = NO;
    if (_fmtDesc) {
        CMSampleTimingInfo t = { kCMTimeInvalid, CMClockGetTime(CMClockGetHostTimeClock()), kCMTimeInvalid };
        CMSampleBufferRef sb = NULL;
        if (CMSampleBufferCreateReadyWithImageBuffer(kCFAllocatorDefault, pb, _fmtDesc, &t, &sb) == noErr) {
            CFArrayRef att = CMSampleBufferGetSampleAttachmentsArray(sb, true);
            CFMutableDictionaryRef d = (CFMutableDictionaryRef)CFArrayGetValueAtIndex(att, 0);
            CFDictionarySetValue(d, kCMSampleAttachmentKey_DisplayImmediately, kCFBooleanTrue);
            [rend enqueueSampleBuffer:sb];
            CFRelease(sb);
            atomic_fetch_add(&_ctl->statFrames, 1);
            atomic_store(&_ctl->width, (int)CVPixelBufferGetWidth(pb));
            atomic_store(&_ctl->height, (int)CVPixelBufferGetHeight(pb));
            ok = YES;
        }
    }
    // Keep the latest frame for snapshots.
    os_unfair_lock_lock(&_snapLock);
    CVPixelBufferRef old = _lastFrame;
    _lastFrame = pb;
    os_unfair_lock_unlock(&_snapLock);
    if (old) CVPixelBufferRelease(old);
    return ok;
}

// Software-decoded frames (codecs VideoToolbox can't handle) -> NV12 CVPixelBuffer (+1 retained).
- (CVPixelBufferRef)convertSoftwareFrame:(AVFrame *)f {
    int w = f->width & ~1, h = f->height & ~1;
    if (w <= 0 || h <= 0) return NULL;
    if (!_sws || w != _swsW || h != _swsH || f->format != _swsFmt) {
        if (_sws) sws_freeContext(_sws);
        if (_pool) { CVPixelBufferPoolRelease(_pool); _pool = NULL; }
        _sws = sws_getContext(f->width, f->height, f->format, w, h, AV_PIX_FMT_NV12, SWS_FAST_BILINEAR, NULL, NULL, NULL);
        NSDictionary *attrs = @{
            (id)kCVPixelBufferPixelFormatTypeKey: @(kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange),
            (id)kCVPixelBufferWidthKey: @(w), (id)kCVPixelBufferHeightKey: @(h),
            (id)kCVPixelBufferIOSurfacePropertiesKey: @{},
        };
        CVPixelBufferPoolCreate(kCFAllocatorDefault, NULL, (__bridge CFDictionaryRef)attrs, &_pool);
        _swsW = w; _swsH = h; _swsFmt = f->format;
    }
    if (!_sws || !_pool) return NULL;
    CVPixelBufferRef pb = NULL;
    if (CVPixelBufferPoolCreatePixelBuffer(kCFAllocatorDefault, _pool, &pb) != kCVReturnSuccess) return NULL;
    CVPixelBufferLockBaseAddress(pb, 0);
    uint8_t *dst[4] = { CVPixelBufferGetBaseAddressOfPlane(pb, 0), CVPixelBufferGetBaseAddressOfPlane(pb, 1), NULL, NULL };
    int stride[4] = { (int)CVPixelBufferGetBytesPerRowOfPlane(pb, 0), (int)CVPixelBufferGetBytesPerRowOfPlane(pb, 1), 0, 0 };
    sws_scale(_sws, (const uint8_t *const *)f->data, f->linesize, 0, f->height, dst, stride);
    CVPixelBufferUnlockBaseAddress(pb, 0);
    return pb;
}
@end
