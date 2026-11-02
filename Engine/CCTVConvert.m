// XMEye private recording -> MP4.
// File layout: frames with big-endian markers 00 00 01 FC (I-frame, 16-byte header),
// FD (P-frame, 8), FA (audio, 8), F9 (info, 8), FE (JPEG, 16). Video payloads are Annex B.
// Timestamps come from frame counting at the header fps, re-synced to the I-frame clock on gaps.

#import "CCTVConvert.h"
#include <libavformat/avformat.h>
#include <libavcodec/avcodec.h>
#include <libavutil/audio_fifo.h>
#include <libavutil/channel_layout.h>
#include <libswresample/swresample.h>
#include <string.h>

NSErrorDomain const CCTVConvertErrorDomain = @"CCTVConvert";

#define TICKS 90000           // video time base 1/90000
#define AUDIO_IN_RATE 8000    // G.711 is always 8 kHz
#define AAC_RATE 16000

#pragma mark - Errors

static BOOL setError(NSError **error, NSInteger code, NSString *msg) {
    if (error) *error = [NSError errorWithDomain:CCTVConvertErrorDomain code:code
                                        userInfo:@{ NSLocalizedDescriptionKey: msg }];
    return NO;
}

static BOOL setAVError(NSError **error, NSString *what, int err) {
    char buf[128] = { 0 };
    av_strerror(err, buf, sizeof buf);
    return setError(error, CCTVConvertErrorWrite, [NSString stringWithFormat:@"%@ (%s)", what, buf]);
}

static BOOL setCancelled(NSError **error) {
    if (error) *error = [NSError errorWithDomain:NSCocoaErrorDomain code:NSUserCancelledError userInfo:nil];
    return NO;
}

#pragma mark - Private framing

enum { XK_I = 1, XK_P, XK_A, XK_INFO, XK_JPEG };

typedef struct {
    size_t off;        // payload offset in the file
    uint32_t len;      // payload length
    uint8_t kind, media, fps, w8, h8;
    uint32_t dt;       // packed wall-clock time (I-frames)
    int64_t pts;       // video: frame time; audio: time of the preceding video frame (1/90000)
} XFrame;

typedef struct {
    XFrame *f;
    size_t n, cap;
    size_t junk;       // bytes skipped before the first I-frame
} XIndex;

static uint32_t rd32(const uint8_t *p) { return p[0] | p[1] << 8 | p[2] << 16 | (uint32_t)p[3] << 24; }
static uint16_t rd16(const uint8_t *p) { return (uint16_t)(p[0] | p[1] << 8); }

static BOOL startsWithStartCode(const uint8_t *p, size_t n) {
    return (n >= 3 && p[0] == 0 && p[1] == 0 && p[2] == 1) ||
           (n >= 4 && p[0] == 0 && p[1] == 0 && p[2] == 0 && p[3] == 1);
}

// Validates a private header at p and fills f.
static BOOL xmHeader(const uint8_t *b, size_t n, size_t p, XFrame *f) {
    if (p + 8 > n || b[p] || b[p + 1] || b[p + 2] != 1) return NO;
    memset(f, 0, sizeof *f);
    size_t hl = 8;
    uint32_t len;
    switch (b[p + 3]) {
    case 0xFC: case 0xFE:
        if (p + 16 > n) return NO;
        hl = 16;
        f->media = b[p + 4]; f->fps = b[p + 5]; f->w8 = b[p + 6]; f->h8 = b[p + 7];
        f->dt = rd32(b + p + 8);
        len = rd32(b + p + 12);
        if (b[p + 3] == 0xFC) {
            if (f->media < 1 || f->media > 3 || f->fps == 0 || f->fps > 120 || !f->w8 || !f->h8) return NO;
            f->kind = XK_I;
        } else f->kind = XK_JPEG;
        break;
    case 0xFD: f->kind = XK_P; len = rd32(b + p + 4); break;
    case 0xFA:
        f->kind = XK_A; f->media = b[p + 4]; len = rd16(b + p + 6);
        if (len == 0 || len > 8192) return NO;
        break;
    case 0xF9: f->kind = XK_INFO; f->media = b[p + 4]; len = rd16(b + p + 6); break;
    default: return NO;
    }
    if (len > (32u << 20) || p + hl + len > n) return NO;
    const uint8_t *pl = b + p + hl;
    if ((f->kind == XK_I || f->kind == XK_P) && !startsWithStartCode(pl, len)) return NO;
    if (f->kind == XK_JPEG && (len < 2 || pl[0] != 0xFF || pl[1] != 0xD8)) return NO;
    f->off = p + hl;
    f->len = len;
    return YES;
}

// Indexes every frame from the first I-frame on. Junk and damaged areas are skipped by
// scanning for the next valid header.
static void xmParse(const uint8_t *b, size_t n, XIndex *ix) {
    size_t p = 0;
    BOOL started = NO;
    XFrame f;
    while (p + 8 <= n) {
        if (xmHeader(b, n, p, &f) && (started || f.kind == XK_I)) {
            if (!started) ix->junk = p;
            started = YES;
            if (ix->n == ix->cap) {
                ix->cap = ix->cap ? ix->cap * 2 : 4096;
                ix->f = realloc(ix->f, ix->cap * sizeof(XFrame));
            }
            ix->f[ix->n++] = f;
            p = f.off + f.len;
            continue;
        }
        const uint8_t *q = memmem(b + p + 1, n - p - 1, "\0\0\1", 3);
        if (!q) break;
        p = (size_t)(q - b);
    }
}

static int64_t daysFromCivil(int y, unsigned m, unsigned d) {
    y -= m <= 2;
    int era = (y >= 0 ? y : y - 399) / 400;
    unsigned yoe = (unsigned)(y - era * 400);
    unsigned doy = (153 * (m + (m > 2 ? -3 : 9)) + 2) / 5 + d - 1;
    unsigned doe = yoe * 365 + yoe / 4 - yoe / 100 + doy;
    return (int64_t)era * 146097 + doe - 719468;
}

typedef struct { int year, month, day, hour, minute, second; } XTime;

static BOOL xmTime(uint32_t v, XTime *t) {
    t->second = v & 0x3F; t->minute = (v >> 6) & 0x3F; t->hour = (v >> 12) & 0x1F;
    t->day = (v >> 17) & 0x1F; t->month = (v >> 22) & 0xF; t->year = (int)(v >> 26) + 2000;
    return t->month >= 1 && t->month <= 12 && t->day >= 1 && t->hour < 24 && t->minute < 60 && t->second < 60;
}

// Wall-clock seconds (time-zone free), or -1 if invalid.
static int64_t xmSeconds(uint32_t v) {
    XTime t;
    if (!xmTime(v, &t)) return -1;
    return daysFromCivil(t.year, (unsigned)t.month, (unsigned)t.day) * 86400 + t.hour * 3600 + t.minute * 60 + t.second;
}

static NSDate *xmDate(uint32_t v, NSTimeZone *tz) {
    XTime t;
    if (!xmTime(v, &t)) return nil;
    NSCalendar *cal = [[NSCalendar alloc] initWithCalendarIdentifier:NSCalendarIdentifierGregorian];
    cal.timeZone = tz;
    NSDateComponents *c = [NSDateComponents new];
    c.year = t.year; c.month = t.month; c.day = t.day; c.hour = t.hour; c.minute = t.minute; c.second = t.second;
    return [cal dateFromComponents:c];
}

// Assigns pts to every frame; returns total video duration in ticks.
static int64_t xmTimeline(XIndex *ix) {
    int64_t t = 0, last = 0, base = -1;
    int fps = 25;
    for (size_t i = 0; i < ix->n; i++) {
        XFrame *f = &ix->f[i];
        if (f->kind == XK_I) {
            if (f->fps) fps = f->fps;
            int64_t s = xmSeconds(f->dt);
            if (s >= 0) {
                if (base < 0) base = s;
                else {
                    int64_t want = (s - base) * TICKS;
                    if (want - t > 2 * TICKS) t = want;                     // gap in the recording
                    else if (t - want > 10 * TICKS) base = s - t / TICKS;   // clock went backwards
                }
            }
        }
        if (f->kind == XK_I || f->kind == XK_P) {
            f->pts = last = t;
            t += TICKS / fps;
        } else f->pts = last;
    }
    return t;
}

#pragma mark - Annex B helpers

// Next start code at or after i; *sc = its length. Returns n if none.
static size_t nextStartCode(const uint8_t *p, size_t n, size_t i, size_t *sc) {
    for (; i + 3 <= n; i++) {
        if (p[i] == 0 && p[i + 1] == 0) {
            if (p[i + 2] == 1) { *sc = 3; return i; }
            if (i + 4 <= n && p[i + 2] == 0 && p[i + 3] == 1) { *sc = 4; return i; }
        }
    }
    *sc = 0;
    return n;
}

// Copies SPS/PPS (and VPS for H.265) out of a keyframe as Annex B extradata.
static uint8_t *parameterSets(const uint8_t *p, size_t n, BOOL hevc, int *outLen) {
    uint8_t *out = av_mallocz(n + AV_INPUT_BUFFER_PADDING_SIZE);
    int len = 0;
    size_t sc, i = nextStartCode(p, n, 0, &sc);
    while (i < n) {
        size_t s = i + sc, sc2;
        size_t e = nextStartCode(p, n, s, &sc2);
        size_t end = e;
        while (end > s && p[end - 1] == 0) end--;
        if (end > s) {
            int type = hevc ? (p[s] >> 1) & 0x3F : p[s] & 0x1F;
            BOOL ps = hevc ? (type >= 32 && type <= 34) : (type == 7 || type == 8);
            if (ps) {
                memcpy(out + len, "\0\0\0\1", 4); len += 4;
                memcpy(out + len, p + s, end - s); len += (int)(end - s);
            }
        }
        i = e; sc = sc2;
    }
    if (!len) { av_free(out); out = NULL; }
    *outLen = len;
    return out;
}

// Decodes one keyframe to learn the real picture size (headers store width/8 in a byte).
static BOOL decodeSize(enum AVCodecID cid, const uint8_t *data, size_t len, int *w, int *h) {
    const AVCodec *c = avcodec_find_decoder(cid);
    if (!c) return NO;
    AVCodecContext *ctx = avcodec_alloc_context3(c);
    AVPacket *pkt = av_packet_alloc();
    AVFrame *fr = av_frame_alloc();
    BOOL ok = NO;
    ctx->thread_count = 1;
    if (avcodec_open2(ctx, c, NULL) == 0 && av_new_packet(pkt, (int)len) == 0) {
        memcpy(pkt->data, data, len);
        pkt->flags |= AV_PKT_FLAG_KEY;
        avcodec_send_packet(ctx, pkt);
        avcodec_send_packet(ctx, NULL);
        if (avcodec_receive_frame(ctx, fr) == 0) { *w = fr->width; *h = fr->height; ok = YES; }
        else if (ctx->width > 0) { *w = ctx->width; *h = ctx->height; ok = YES; }
    }
    av_frame_free(&fr);
    av_packet_free(&pkt);
    avcodec_free_context(&ctx);
    return ok;
}

// Guesses H.264 vs H.265 for plain Annex B. Returns 0 if neither.
static enum AVCodecID detectAnnexB(const uint8_t *p, size_t n) {
    if (n > (4 << 20)) n = 4 << 20;
    size_t sc, i = nextStartCode(p, n, 0, &sc);
    if (i != 0) return AV_CODEC_ID_NONE;   // must start with a start code
    int h264 = 0, h265 = 0;
    for (int k = 0; i < n && k < 200; k++) {
        size_t s = i + sc;
        if (s + 2 > n) break;
        uint8_t b0 = p[s], b1 = p[s + 1];
        if ((b0 >> 1) == 32 && b1 == 1) h265++;          // VPS
        else if ((b0 & 0x9F) == 0x07 || (b0 & 0x9F) == 0x05) h264++;  // SPS / IDR
        i = nextStartCode(p, n, s, &sc);
    }
    if (h265) return AV_CODEC_ID_HEVC;
    if (h264) return AV_CODEC_ID_H264;
    return AV_CODEC_ID_NONE;
}

#pragma mark - In-memory output (nothing touches the disk)

typedef struct { uint8_t *data; size_t size, cap, pos; } MemOut;

static int memWrite(void *opaque, const uint8_t *buf, int n) {
    MemOut *m = opaque;
    if (m->pos + (size_t)n > m->cap) {
        size_t cap = MAX(m->cap * 2, m->pos + (size_t)n + (1 << 20));
        uint8_t *d = realloc(m->data, cap);
        if (!d) return AVERROR(ENOMEM);
        m->data = d; m->cap = cap;
    }
    memcpy(m->data + m->pos, buf, (size_t)n);
    m->pos += (size_t)n;
    if (m->pos > m->size) m->size = m->pos;
    return n;
}

static int64_t memSeek(void *opaque, int64_t off, int whence) {
    MemOut *m = opaque;
    if (whence & AVSEEK_SIZE) return (int64_t)m->size;
    int64_t base = (whence & 3) == SEEK_CUR ? (int64_t)m->pos : (whence & 3) == SEEK_END ? (int64_t)m->size : 0;
    int64_t np = base + off;
    if (np < 0) return AVERROR(EINVAL);
    m->pos = (size_t)np;
    return np;
}

#pragma mark - MP4 writer

typedef struct {
    MemOut *mem;        // non-NULL: write into memory instead of a file
    AVFormatContext *out;
    AVStream *vs, *as;
    AVCodecContext *dec, *enc;
    SwrContext *swr;
    AVAudioFifo *fifo;
    AVFrame *afr, *conv, *efr;
    AVPacket *pkt, *apkt;
    int64_t aIn;        // 8 kHz input samples placed so far (incl. silence)
    int64_t aNext;      // next AAC pts (1/AAC_RATE)
    BOOL aStarted;
    BOOL headerDone;
} Writer;

static int openWriter(Writer *w, NSString *path, enum AVCodecID cid, int width, int height, int fps,
                      uint8_t *extra, int extraLen) {
    int err = avformat_alloc_output_context2(&w->out, NULL, "mp4", path ? path.fileSystemRepresentation : NULL);
    if (err < 0) return err;
    w->vs = avformat_new_stream(w->out, NULL);
    if (!w->vs) return AVERROR(ENOMEM);
    AVCodecParameters *cp = w->vs->codecpar;
    cp->codec_type = AVMEDIA_TYPE_VIDEO;
    cp->codec_id = cid;
    cp->codec_tag = cid == AV_CODEC_ID_HEVC ? MKTAG('h', 'v', 'c', '1') : 0;
    cp->width = width;
    cp->height = height;
    cp->format = AV_PIX_FMT_YUV420P;
    if (extra) { cp->extradata = extra; cp->extradata_size = extraLen; }
    w->vs->time_base = (AVRational){ 1, TICKS };
    w->vs->avg_frame_rate = w->vs->r_frame_rate = (AVRational){ fps, 1 };
    w->pkt = av_packet_alloc();
    return 0;
}

// G.711A decoder + AAC encoder. Failure just means no audio track.
static void addAudio(Writer *w) {
    const AVCodec *dc = avcodec_find_decoder(AV_CODEC_ID_PCM_ALAW);
    const AVCodec *ec = avcodec_find_encoder(AV_CODEC_ID_AAC);
    if (!dc || !ec) return;
    w->dec = avcodec_alloc_context3(dc);
    w->dec->sample_rate = AUDIO_IN_RATE;
    av_channel_layout_default(&w->dec->ch_layout, 1);
    w->enc = avcodec_alloc_context3(ec);
    w->enc->sample_rate = AAC_RATE;
    w->enc->sample_fmt = AV_SAMPLE_FMT_FLTP;
    av_channel_layout_default(&w->enc->ch_layout, 1);
    w->enc->bit_rate = 32000;
    w->enc->time_base = (AVRational){ 1, AAC_RATE };
    if (w->out->oformat->flags & AVFMT_GLOBALHEADER) w->enc->flags |= AV_CODEC_FLAG_GLOBAL_HEADER;
    if (avcodec_open2(w->dec, dc, NULL) < 0 || avcodec_open2(w->enc, ec, NULL) < 0 ||
        swr_alloc_set_opts2(&w->swr, &w->enc->ch_layout, AV_SAMPLE_FMT_FLTP, AAC_RATE,
                            &w->dec->ch_layout, w->dec->sample_fmt, AUDIO_IN_RATE, 0, NULL) < 0 ||
        swr_init(w->swr) < 0) {
        avcodec_free_context(&w->dec);
        avcodec_free_context(&w->enc);
        swr_free(&w->swr);
        return;
    }
    w->as = avformat_new_stream(w->out, NULL);
    avcodec_parameters_from_context(w->as->codecpar, w->enc);
    w->as->time_base = w->enc->time_base;
    w->fifo = av_audio_fifo_alloc(AV_SAMPLE_FMT_FLTP, 1, w->enc->frame_size * 8);
    w->afr = av_frame_alloc();
    w->conv = av_frame_alloc();
    w->efr = av_frame_alloc();
    w->efr->nb_samples = w->enc->frame_size;
    w->efr->format = AV_SAMPLE_FMT_FLTP;
    w->efr->sample_rate = AAC_RATE;
    av_channel_layout_copy(&w->efr->ch_layout, &w->enc->ch_layout);
    av_frame_get_buffer(w->efr, 0);
    w->apkt = av_packet_alloc();
}

static int writeHeader(Writer *w, NSString *path) {
    int err = 0;
    AVDictionary *o = NULL;
    if (w->mem) {
        // Memory: moov goes at the end (faststart needs to re-read a file); fine for AVPlayer.
        unsigned char *iobuf = av_malloc(1 << 16);
        w->out->pb = avio_alloc_context(iobuf, 1 << 16, 1, w->mem, NULL, memWrite, memSeek);
        if (!w->out->pb) return AVERROR(ENOMEM);
        w->out->flags |= AVFMT_FLAG_CUSTOM_IO;
    } else {
        err = avio_open(&w->out->pb, path.fileSystemRepresentation, AVIO_FLAG_WRITE);
        if (err < 0) return err;
        av_dict_set(&o, "movflags", "+faststart", 0);
    }
    err = avformat_write_header(w->out, &o);
    av_dict_free(&o);
    if (err >= 0) w->headerDone = YES;
    return err < 0 ? err : 0;
}

static int writeVideo(Writer *w, const uint8_t *data, size_t len, int64_t pts, int64_t dur, BOOL key) {
    AVPacket *p = w->pkt;
    int err = av_new_packet(p, (int)len);
    if (err < 0) return err;
    memcpy(p->data, data, len);
    p->pts = p->dts = pts;
    p->duration = dur;
    if (key) p->flags |= AV_PKT_FLAG_KEY;
    p->stream_index = w->vs->index;
    av_packet_rescale_ts(p, (AVRational){ 1, TICKS }, w->vs->time_base);
    return av_interleaved_write_frame(w->out, p);
}

// Encodes whole AAC frames from the fifo (all of it when flushing).
static int drainAudio(Writer *w, BOOL flush) {
    int fs = w->enc->frame_size;
    while (av_audio_fifo_size(w->fifo) >= fs || (flush && av_audio_fifo_size(w->fifo) > 0)) {
        int n = FFMIN(fs, av_audio_fifo_size(w->fifo));
        av_frame_make_writable(w->efr);
        w->efr->nb_samples = n;
        av_audio_fifo_read(w->fifo, (void **)w->efr->data, n);
        w->efr->pts = w->aNext;
        w->aNext += n;
        if (avcodec_send_frame(w->enc, w->efr) < 0) continue;
        while (avcodec_receive_packet(w->enc, w->apkt) >= 0) {
            w->apkt->stream_index = w->as->index;
            av_packet_rescale_ts(w->apkt, w->enc->time_base, w->as->time_base);
            int err = av_interleaved_write_frame(w->out, w->apkt);
            if (err < 0) return err;
        }
    }
    w->efr->nb_samples = fs;
    if (flush && avcodec_send_frame(w->enc, NULL) >= 0) {
        while (avcodec_receive_packet(w->enc, w->apkt) >= 0) {
            w->apkt->stream_index = w->as->index;
            av_packet_rescale_ts(w->apkt, w->enc->time_base, w->as->time_base);
            av_interleaved_write_frame(w->out, w->apkt);
        }
    }
    return 0;
}

static void addSilence(Writer *w, int64_t inSamples) {
    static const float zeros[1024];
    int64_t out = inSamples * AAC_RATE / AUDIO_IN_RATE;
    while (out > 0) {
        int n = (int)FFMIN(out, 1024);
        const float *planes[1] = { zeros };
        av_audio_fifo_write(w->fifo, (void **)planes, n);
        out -= n;
    }
    w->aIn += inSamples;
}

// clock = output time (s) of the video frame just before this audio block.
static int writeAudio(Writer *w, const uint8_t *data, size_t len, double clock) {
    if (!w->as) return 0;
    double pos = (double)w->aIn / AUDIO_IN_RATE;
    if (!w->aStarted) {
        w->aStarted = YES;
        if (clock > 0) addSilence(w, llround(clock * AUDIO_IN_RATE));
    } else if (clock - pos > 1.0) {
        addSilence(w, llround((clock - pos) * AUDIO_IN_RATE));   // audio gap
    } else if (pos - clock > 1.0) {
        return 0;                                                // audio ahead of video: drop
    }
    AVPacket *p = w->pkt;
    if (av_new_packet(p, (int)len) < 0) return 0;
    memcpy(p->data, data, len);
    int r = avcodec_send_packet(w->dec, p);
    av_packet_unref(p);
    if (r < 0) return 0;
    while (avcodec_receive_frame(w->dec, w->afr) >= 0) {
        av_frame_unref(w->conv);
        w->conv->format = AV_SAMPLE_FMT_FLTP;
        w->conv->sample_rate = AAC_RATE;
        av_channel_layout_copy(&w->conv->ch_layout, &w->enc->ch_layout);
        if (swr_convert_frame(w->swr, w->conv, w->afr) == 0 && w->conv->nb_samples > 0)
            av_audio_fifo_write(w->fifo, (void **)w->conv->data, w->conv->nb_samples);
        w->aIn += w->afr->nb_samples;
        av_frame_unref(w->afr);
    }
    return drainAudio(w, NO);
}

// Finishes the file (if ok) and frees everything.
static int closeWriter(Writer *w, BOOL ok) {
    int err = 0;
    if (ok && w->headerDone) {
        if (w->as) drainAudio(w, YES);
        err = av_write_trailer(w->out);
    }
    if (w->out) {
        if (w->mem && w->out->pb) {
            avio_flush(w->out->pb);
            av_freep(&w->out->pb->buffer);
            avio_context_free(&w->out->pb);
        } else if (w->out->pb) {
            avio_closep(&w->out->pb);
        }
        avformat_free_context(w->out);
    }
    avcodec_free_context(&w->dec);
    avcodec_free_context(&w->enc);
    swr_free(&w->swr);
    if (w->fifo) av_audio_fifo_free(w->fifo);
    av_frame_free(&w->afr);
    av_frame_free(&w->conv);
    av_frame_free(&w->efr);
    av_packet_free(&w->pkt);
    av_packet_free(&w->apkt);
    MemOut *mem = w->mem;
    memset(w, 0, sizeof *w);
    w->mem = mem;
    return err;
}

#pragma mark - Plain Annex B fallback (ffmpeg raw demuxer)

static AVFormatContext *openRaw(NSString *path, enum AVCodecID cid) {
    const AVInputFormat *f = av_find_input_format(cid == AV_CODEC_ID_HEVC ? "hevc" : "h264");
    AVFormatContext *in = NULL;
    if (avformat_open_input(&in, path.fileSystemRepresentation, f, NULL) < 0) return NULL;
    if (avformat_find_stream_info(in, NULL) < 0 || in->nb_streams < 1) { avformat_close_input(&in); return NULL; }
    return in;
}

static int rawFps(AVStream *s) {
    AVRational r = s->avg_frame_rate.num > 0 ? s->avg_frame_rate : s->r_frame_rate;
    int fps = r.den > 0 ? (int)lround(av_q2d(r)) : 0;
    return fps >= 1 && fps <= 120 ? fps : 25;
}

static NSDictionary *probeRaw(NSString *path, enum AVCodecID cid) {
    AVFormatContext *in = openRaw(path, cid);
    if (!in) return nil;
    AVStream *s = in->streams[0];
    int fps = rawFps(s);
    int64_t frames = 0;
    AVPacket *pkt = av_packet_alloc();
    while (av_read_frame(in, pkt) >= 0) { frames++; av_packet_unref(pkt); }
    av_packet_free(&pkt);
    NSDictionary *d = @{
        @"width": @(s->codecpar->width), @"height": @(s->codecpar->height), @"fps": @(fps),
        @"codec": cid == AV_CODEC_ID_HEVC ? @"h265" : @"h264", @"hasAudio": @NO,
        @"frames": @(frames), @"duration": @((double)frames / fps),
    };
    avformat_close_input(&in);
    return d;
}

static BOOL remuxRaw(NSString *input, NSString *output, enum AVCodecID cid, double start, double duration,
                     void (^progress)(double), BOOL (^cancelled)(void), NSError **error) {
    // Pass 1: frame count and keyframe positions.
    AVFormatContext *in = openRaw(input, cid);
    if (!in) return setError(error, CCTVConvertErrorFormat, @"The recording couldn't be read.");
    int fps = rawFps(in->streams[0]);
    int64_t frames = 0, startFrame = 0, startTarget = llround(start * fps);
    AVPacket *pkt = av_packet_alloc();
    while (av_read_frame(in, pkt) >= 0) {
        if ((pkt->flags & AV_PKT_FLAG_KEY) && frames <= startTarget) startFrame = frames;
        frames++;
        av_packet_unref(pkt);
    }
    avformat_close_input(&in);
    if (frames == 0 || startTarget >= frames) {
        av_packet_free(&pkt);
        return frames ? setError(error, CCTVConvertErrorRange, @"The start time is past the end of the recording.")
                      : setError(error, CCTVConvertErrorFormat, @"No video found in the recording.");
    }
    int64_t endFrame = duration > 0 ? FFMIN(frames, llround((start + duration) * fps)) : frames;

    // Pass 2: copy.
    in = openRaw(input, cid);
    Writer w = { 0 };
    BOOL ok = NO;
    int err = 0;
    if (!in) { setError(error, CCTVConvertErrorFormat, @"The recording couldn't be read."); goto done; }
    {
        AVCodecParameters *ip = in->streams[0]->codecpar;
        uint8_t *extra = NULL;
        if (ip->extradata_size > 0) {
            extra = av_mallocz(ip->extradata_size + AV_INPUT_BUFFER_PADDING_SIZE);
            memcpy(extra, ip->extradata, ip->extradata_size);
        }
        if ((err = openWriter(&w, output, cid, ip->width, ip->height, fps, extra, ip->extradata_size)) < 0 ||
            (err = writeHeader(&w, output)) < 0) {
            setAVError(error, @"Couldn't create the MP4", err);
            goto done;
        }
    }
    int64_t idx = 0, dur = TICKS / fps;
    double lastReport = -1;
    while (av_read_frame(in, pkt) >= 0) {
        if (idx >= endFrame) { av_packet_unref(pkt); break; }
        if (idx >= startFrame) {
            if (cancelled && idx % 25 == 0 && cancelled()) { av_packet_unref(pkt); setCancelled(error); goto done; }
            err = writeVideo(&w, pkt->data, pkt->size, (idx - startFrame) * dur, dur, (pkt->flags & AV_PKT_FLAG_KEY) != 0);
            if (err < 0) { av_packet_unref(pkt); setAVError(error, @"Couldn't write the MP4", err); goto done; }
            double fr = (double)(idx - startFrame) / (double)FFMAX(1, endFrame - startFrame);
            if (progress && fr - lastReport >= 0.01) { lastReport = fr; progress(fr); }
        }
        idx++;
        av_packet_unref(pkt);
    }
    ok = YES;
done:
    err = closeWriter(&w, ok);
    if (ok && err < 0) { ok = NO; setAVError(error, @"Couldn't finish the MP4", err); }
    if (in) avformat_close_input(&in);
    av_packet_free(&pkt);
    if (!ok) [[NSFileManager defaultManager] removeItemAtPath:output error:nil];
    else if (progress) progress(1.0);
    return ok;
}

#pragma mark - Public API

static NSDictionary *probeCore(NSData *data, NSString *path, NSTimeZone *tz);
static BOOL convertCore(NSData *data, NSString *output, MemOut *mem, double start, double duration,
                        void (^progress)(double), BOOL (^cancelled)(void), NSError **error);

static NSDictionary *probeCore(NSData *data, NSString *path, NSTimeZone *tz) {
    if (data.length < 8) return nil;
    const uint8_t *b = data.bytes;
    XIndex ix = { 0 };
    xmParse(b, data.length, &ix);
    if (ix.n == 0) {
        free(ix.f);
        enum AVCodecID cid = detectAnnexB(b, data.length);
        return cid && path ? probeRaw(path, cid) : nil;
    }
    int64_t total = xmTimeline(&ix);
    XFrame *first = &ix.f[0], *lastI = first;
    int64_t frames = 0;
    BOOL audio = NO;
    for (size_t i = 0; i < ix.n; i++) {
        XFrame *f = &ix.f[i];
        if (f->kind == XK_I) lastI = f;
        if (f->kind == XK_I || f->kind == XK_P) frames++;
        if (f->kind == XK_A) audio = YES;
    }
    enum AVCodecID cid = first->media == 3 ? AV_CODEC_ID_HEVC : first->media == 2 ? AV_CODEC_ID_H264 : AV_CODEC_ID_MPEG4;
    int w = first->w8 * 8, h = first->h8 * 8;
    if (cid != AV_CODEC_ID_MPEG4) decodeSize(cid, b + first->off, first->len, &w, &h);
    NSMutableDictionary *d = [@{
        @"width": @(w), @"height": @(h), @"fps": @(first->fps),
        @"codec": cid == AV_CODEC_ID_HEVC ? @"h265" : cid == AV_CODEC_ID_H264 ? @"h264" : @"mpeg4",
        @"hasAudio": @(audio), @"frames": @(frames), @"duration": @((double)total / TICKS),
    } mutableCopy];
    NSDate *s = xmDate(first->dt, tz), *e = xmDate(lastI->dt, tz);
    if (s) d[@"start"] = s;
    if (e) d[@"end"] = e;
    free(ix.f);
    return d;
}


@implementation CCTVConvert

+ (NSDictionary<NSString *, id> *)probeXMEyeFile:(NSString *)path timeZone:(NSTimeZone *)tz {
    NSData *data = [NSData dataWithContentsOfFile:path options:NSDataReadingMappedIfSafe error:nil];
    return probeCore(data, path, tz);
}

+ (BOOL)convertXMEyeFile:(NSString *)input toMP4:(NSString *)output startOffset:(double)start
                duration:(double)duration progress:(void (^)(double))progress
                  cancel:(BOOL (^)(void))cancelled error:(NSError **)error {
    NSData *data = [NSData dataWithContentsOfFile:input options:NSDataReadingMappedIfSafe error:nil];
    if (!data) return setError(error, CCTVConvertErrorRead, @"The recording file couldn't be opened.");
    [[NSFileManager defaultManager] removeItemAtPath:output error:nil];
    XIndex ix = { 0 };
    xmParse(data.bytes, data.length, &ix);
    if (ix.n == 0) {
        free(ix.f);
        enum AVCodecID cid = detectAnnexB(data.bytes, data.length);
        if (!cid) return setError(error, CCTVConvertErrorFormat, @"No video found in the recording.");
        return remuxRaw(input, output, cid, MAX(start, 0), duration, progress, cancelled, error);
    }
    free(ix.f);
    return convertCore(data, output, NULL, start, duration, progress, cancelled, error);
}

+ (NSDictionary<NSString *, id> *)probeXMEyeData:(NSData *)data timeZone:(NSTimeZone *)tz {
    return probeCore(data, nil, tz);
}

+ (NSData *)convertXMEyeData:(NSData *)data startOffset:(double)start duration:(double)duration
                    progress:(void (^)(double))progress cancel:(BOOL (^)(void))cancelled error:(NSError **)error {
    MemOut mem = { 0 };
    if (!convertCore(data, nil, &mem, start, duration, progress, cancelled, error)) {
        free(mem.data);
        return nil;
    }
    return [NSData dataWithBytesNoCopy:mem.data length:mem.size freeWhenDone:YES];
}

@end

// Shared by the file and memory versions. output = nil means write into `mem`.
static BOOL convertCore(NSData *data, NSString *output, MemOut *mem, double start, double duration,
                        void (^progress)(double), BOOL (^cancelled)(void), NSError **error) {
    if (start < 0) start = 0;
    const uint8_t *b = data.bytes;
    XIndex ix = { 0 };
    xmParse(b, data.length, &ix);
    if (ix.n == 0) {
        free(ix.f);
        return setError(error, CCTVConvertErrorFormat, @"No video found in the recording.");
    }

    int64_t total = xmTimeline(&ix);
    XFrame *f0 = &ix.f[0];
    if (f0->media != 2 && f0->media != 3) {
        free(ix.f);
        return setError(error, CCTVConvertErrorFormat, @"This recording uses MPEG-4 video, which isn't supported.");
    }
    BOOL hevc = f0->media == 3;
    enum AVCodecID cid = hevc ? AV_CODEC_ID_HEVC : AV_CODEC_ID_H264;
    int64_t startT = llround(start * TICKS);
    int64_t endT = duration > 0 ? startT + llround(duration * TICKS) : INT64_MAX;
    if (startT >= total) {
        free(ix.f);
        return setError(error, CCTVConvertErrorRange, @"The start time is past the end of the recording.");
    }

    // First frame: last I-frame at or before start. Last: first video frame at or after end.
    size_t si = 0, ei = ix.n;
    BOOL wantAudio = NO;
    for (size_t i = 0; i < ix.n; i++)
        if (ix.f[i].kind == XK_I && ix.f[i].pts <= startT) si = i;
    for (size_t i = si; i < ix.n; i++) {
        XFrame *f = &ix.f[i];
        if ((f->kind == XK_I || f->kind == XK_P) && f->pts >= endT) { ei = i; break; }
        if (f->kind == XK_A && f->media == 0x0E) wantAudio = YES;
    }
    int64_t offset = ix.f[si].pts;
    int fps = ix.f[si].fps ? ix.f[si].fps : 25;
    int w = ix.f[si].w8 * 8, h = ix.f[si].h8 * 8;
    decodeSize(cid, b + ix.f[si].off, ix.f[si].len, &w, &h);
    int extraLen = 0;
    uint8_t *extra = parameterSets(b + ix.f[si].off, ix.f[si].len, hevc, &extraLen);

    Writer wr = { 0 };
    wr.mem = mem;
    BOOL ok = NO;
    int err;
    if ((err = openWriter(&wr, output, cid, w, h, fps, extra, extraLen)) < 0) {
        if (!wr.out) av_free(extra);
        setAVError(error, @"Couldn't create the MP4", err);
        goto done;
    }
    if (wantAudio) addAudio(&wr);
    if ((err = writeHeader(&wr, output)) < 0) { setAVError(error, @"Couldn't create the MP4", err); goto done; }

    {
        double lastReport = -1;
        int64_t count = 0;
        for (size_t i = si; i < ei; i++) {
            XFrame *f = &ix.f[i];
            if (f->kind == XK_I || f->kind == XK_P) {
                if (f->kind == XK_I && f->fps) fps = f->fps;
                if (cancelled && ++count % 25 == 0 && cancelled()) { setCancelled(error); goto done; }
                err = writeVideo(&wr, b + f->off, f->len, f->pts - offset, TICKS / fps, f->kind == XK_I);
                if (err < 0) { setAVError(error, @"Couldn't write the MP4", err); goto done; }
            } else if (f->kind == XK_A && f->media == 0x0E) {
                err = writeAudio(&wr, b + f->off, f->len, (double)(f->pts - offset) / TICKS);
                if (err < 0) { setAVError(error, @"Couldn't write the MP4", err); goto done; }
            }
            double fr = (double)(i - si) / (double)(ei - si);
            if (progress && fr - lastReport >= 0.01) { lastReport = fr; progress(fr); }
        }
    }
    ok = YES;
done:
    err = closeWriter(&wr, ok);
    if (ok && err < 0) { ok = NO; setAVError(error, @"Couldn't finish the MP4", err); }
    free(ix.f);
    if (!ok && output) [[NSFileManager defaultManager] removeItemAtPath:output error:nil];
    else if (ok && progress) progress(1.0);
    return ok;
}

#pragma mark - Streaming playback (decode while the recording is still arriving)

#import <AVFoundation/AVFoundation.h>
#import <CoreMedia/CoreMedia.h>
#import <CoreVideo/CoreVideo.h>
#import <CoreImage/CoreImage.h>
#include <pthread.h>
#include <libavutil/hwcontext.h>
#include <libswscale/swscale.h>

typedef struct { size_t off; uint32_t len; uint8_t key; uint8_t media; uint8_t audio; double t; } PFrame;

// G.711 A-law -> 16-bit PCM.
static int16_t alaw2linear(uint8_t a) {
    a ^= 0x55;
    int t = (a & 0x0F) << 4;
    int seg = (a & 0x70) >> 4;
    if (seg == 0) t += 8; else if (seg == 1) t += 0x108; else { t += 0x108; t <<= seg - 1; }
    return (int16_t)((a & 0x80) ? t : -t);
}

@implementation CCTVPlayback {
    AVSampleBufferDisplayLayer *_layer;
    NSTimeZone *_tz;
    AVSampleBufferRenderSynchronizer *_sync;   // one clock for picture and sound
    AVSampleBufferAudioRenderer *_audio;
    CMAudioFormatDescriptionRef _afmt;
    double _audioNext;                          // time of the next audio sample
    BOOL _hasAudio, _soundOn;
    float _volume;
    pthread_mutex_t _mx;
    pthread_cond_t _cv;
    uint8_t *_buf; size_t _len, _cap;   // raw recording bytes (memory only)
    size_t _parsePos;
    PFrame *_fr; size_t _n, _frCap;     // video frame index
    BOOL _started, _finished, _stop, _endedSent;
    int64_t _firstSec;
    double _next;                       // time of the next video frame
    double _fps;
    double _lastT;                      // time of the newest video frame (audio frames don't count)
    size_t _decodeIdx;
    int _seekGen;
    float _rate;
    BOOL _stalled, _haveFirstFrame;
    NSDate *_startDate;
}

- (instancetype)initWithLayer:(AVSampleBufferDisplayLayer *)layer timeZone:(NSTimeZone *)tz {
    if ((self = [super init])) {
        _layer = layer;
        _tz = tz;
        _rate = 1;
        _fps = 25;
        pthread_mutex_init(&_mx, NULL);
        pthread_cond_init(&_cv, NULL);
        _soundOn = YES;
        _volume = 1;
        [_layer.sampleBufferRenderer flushWithRemovalOfDisplayedImage:YES completionHandler:nil];
        _layer.controlTimebase = nil;
        _sync = [AVSampleBufferRenderSynchronizer new];
        _audio = [AVSampleBufferAudioRenderer new];
        [_sync addRenderer:_layer.sampleBufferRenderer];
        [_sync addRenderer:_audio];
        [_sync setRate:0 time:kCMTimeZero];
        AudioStreamBasicDescription asbd = { .mSampleRate = 8000, .mFormatID = kAudioFormatLinearPCM,
            .mFormatFlags = kLinearPCMFormatFlagIsSignedInteger | kLinearPCMFormatFlagIsPacked,
            .mBytesPerPacket = 2, .mFramesPerPacket = 1, .mBytesPerFrame = 2, .mChannelsPerFrame = 1, .mBitsPerChannel = 16 };
        CMAudioFormatDescriptionCreate(kCFAllocatorDefault, &asbd, 0, NULL, 0, NULL, NULL, &_afmt);
        NSThread *t = [[NSThread alloc] initWithTarget:self selector:@selector(decodeLoop) object:nil];
        t.qualityOfService = NSQualityOfServiceUserInteractive;
        t.name = @"cctv.playback";
        [t start];
    }
    return self;
}

- (void)dealloc {
    free(_buf);
    free(_fr);
    if (_afmt) CFRelease(_afmt);
    pthread_mutex_destroy(&_mx);
    pthread_cond_destroy(&_cv);
}

- (void)stop {
    // Hand the shared video layer back so the next player can use it.
    [_sync removeRenderer:_layer.sampleBufferRenderer atTime:kCMTimeInvalid completionHandler:nil];
    [_sync removeRenderer:_audio atTime:kCMTimeInvalid completionHandler:nil];
    [_audio flush];
    pthread_mutex_lock(&_mx);
    _stop = YES;
    pthread_cond_broadcast(&_cv);
    pthread_mutex_unlock(&_mx);
}

#pragma mark Feeding

- (void)appendData:(NSData *)chunk {
    pthread_mutex_lock(&_mx);
    if (_len + chunk.length > _cap) {
        size_t cap = MAX(_cap * 2, _len + chunk.length + (8u << 20));
        uint8_t *b = realloc(_buf, cap);
        if (!b) { pthread_mutex_unlock(&_mx); return; }
        _buf = b; _cap = cap;
    }
    memcpy(_buf + _len, chunk.bytes, chunk.length);
    _len += chunk.length;
    [self parseLocked];
    pthread_cond_broadcast(&_cv);
    pthread_mutex_unlock(&_mx);
}

- (void)finishData {
    pthread_mutex_lock(&_mx);
    _finished = YES;
    pthread_cond_broadcast(&_cv);
    pthread_mutex_unlock(&_mx);
}

// Indexes complete frames; stops at a frame that hasn't fully arrived yet.
- (void)parseLocked {
    size_t p = _parsePos;
    XFrame f;
    while (p + 8 <= _len) {
        if (xmHeader(_buf, _len, p, &f)) {
            if (f.kind == XK_I && !_started) {
                _started = YES;
                _firstSec = xmSeconds(f.dt);
                _startDate = xmDate(f.dt, _tz);
                _next = 0;
            }
            if (_started && f.kind == XK_A && f.media == 0x0E && f.len > 0) {
                if (_n == _frCap) { _frCap = _frCap ? _frCap * 2 : 8192; _fr = realloc(_fr, _frCap * sizeof(PFrame)); }
                double at = _lastT;
                _fr[_n++] = (PFrame){ f.off, f.len, 0, f.media, 1, at };
                _hasAudio = YES;
            }
            if (_started && (f.kind == XK_I || f.kind == XK_P)) {
                if (f.kind == XK_I) {
                    // Resync to the I-frame's wall clock when there's a gap in the recording.
                    int64_t s = xmSeconds(f.dt);
                    if (s >= 0 && _firstSec >= 0) {
                        double wall = (double)(s - _firstSec);
                        if (fabs(wall - _next) > 2.0) _next = MAX(wall, _n ? _lastT + 0.04 : 0);
                    }
                }
                if (_n == _frCap) { _frCap = _frCap ? _frCap * 2 : 8192; _fr = realloc(_fr, _frCap * sizeof(PFrame)); }
                _fr[_n++] = (PFrame){ f.off, f.len, f.kind == XK_I, f.media, 0, _next };
                _lastT = _next;
                if (f.kind == XK_I && f.fps) _fps = f.fps;
                _next += 1.0 / _fps;
            }
            p = f.off + f.len;
            continue;
        }
        // Not a complete header here: either the frame is still arriving, or this is junk.
        if (_buf[p] == 0 && _buf[p + 1] == 0 && _buf[p + 2] == 1) {
            uint8_t ty = _buf[p + 3];
            size_t need = 0;
            if ((ty == 0xFC || ty == 0xFE)) need = p + 16 <= _len ? p + 16 + rd32(_buf + p + 12) : p + 16;
            else if (ty == 0xFD) need = p + 8 + rd32(_buf + p + 4);
            else if (ty == 0xFA || ty == 0xF9) need = p + 8 + rd16(_buf + p + 6);
            if (need > _len && need - p < (32u << 20)) break;   // wait for more data
        }
        const uint8_t *q = memmem(_buf + p + 1, _len - p - 1, "\0\0\1", 3);
        if (!q) { p = _len > 3 ? _len - 3 : p; break; }
        p = (size_t)(q - _buf);
    }
    _parsePos = p;
}

#pragma mark State (any thread)

- (NSDate *)startDate { pthread_mutex_lock(&_mx); NSDate *d = _startDate; pthread_mutex_unlock(&_mx); return d; }
- (double)position { return CMTimeGetSeconds(CMTimebaseGetTime(_sync.timebase)); }
- (BOOL)hasAudio { pthread_mutex_lock(&_mx); BOOL a = _hasAudio; pthread_mutex_unlock(&_mx); return a; }
- (BOOL)soundOn { return _soundOn; }
- (void)setSoundOn:(BOOL)on { _soundOn = on; [self applyAudio]; }
- (float)volume { return _volume; }
- (void)setVolume:(float)v { _volume = v; [self applyAudio]; }
// Sound plays at normal speed only (fast-forward is silent).
- (void)applyAudio { _audio.volume = _volume; _audio.muted = !_soundOn || fabsf(_rate - 1) > 0.01f; }
- (double)buffered { pthread_mutex_lock(&_mx); double b = _n ? _lastT : 0; pthread_mutex_unlock(&_mx); return b; }
- (BOOL)finished { pthread_mutex_lock(&_mx); BOOL f = _finished; pthread_mutex_unlock(&_mx); return f; }
- (BOOL)hasPicture { pthread_mutex_lock(&_mx); BOOL f = _haveFirstFrame; pthread_mutex_unlock(&_mx); return f; }
- (BOOL)isStalled { pthread_mutex_lock(&_mx); BOOL s = _stalled; pthread_mutex_unlock(&_mx); return s; }
- (size_t)bytesReceived { pthread_mutex_lock(&_mx); size_t l = _len; pthread_mutex_unlock(&_mx); return l; }
- (float)rate { return _rate; }

- (void)setRate:(float)rate {
    pthread_mutex_lock(&_mx);
    _rate = rate;
    [self applyAudio];
    if (_haveFirstFrame && !_stalled) [_sync setRate:rate];
    pthread_cond_broadcast(&_cv);
    pthread_mutex_unlock(&_mx);
}

- (BOOL)seekTo:(double)seconds {
    pthread_mutex_lock(&_mx);
    if (_n == 0 || seconds > _lastT + 0.5) { pthread_mutex_unlock(&_mx); return NO; }
    size_t idx = 0;
    for (size_t i = 0; i < _n && _fr[i].t <= seconds; i++) if (_fr[i].key) idx = i;
    _decodeIdx = idx;
    _seekGen++;
    _endedSent = NO;
    double t = MAX(seconds, _fr[idx].t);
    [_layer.sampleBufferRenderer flushWithRemovalOfDisplayedImage:NO completionHandler:nil];
    [_audio flush];
    _audioNext = 0;
    [_sync setRate:(_haveFirstFrame && !_stalled ? _rate : 0) time:CMTimeMakeWithSeconds(t, 90000)];
    pthread_cond_broadcast(&_cv);
    pthread_mutex_unlock(&_mx);
    return YES;
}

#pragma mark Decoding

- (void)decodeLoop {
    AVCodecContext *ctx = NULL;
    AVBufferRef *hw = NULL;
    AVPacket *pkt = av_packet_alloc();
    AVFrame *frame = av_frame_alloc();
    CMVideoFormatDescriptionRef fmt = NULL;
    struct SwsContext *sws = NULL;
    CVPixelBufferPoolRef pool = NULL;
    int sw = 0, shh = 0, sfmt = -1;
    int gen = -1;

    pthread_mutex_lock(&_mx);
    while (!_stop) {
        double now = CMTimeGetSeconds(CMTimebaseGetTime(_sync.timebase));
        double ahead = 1.0 + 0.75 * MAX(_rate, 1);

        if (_decodeIdx >= _n) {
            if (_finished) {
                if (!_endedSent && _n && now >= _lastT) {
                    _endedSent = YES;
                    void (^cb)(void) = self.onEnded;
                    if (cb) dispatch_async(dispatch_get_main_queue(), cb);
                }
            } else if (_haveFirstFrame && !_stalled && _n && now > _lastT) {
                _stalled = YES;                              // download is behind playback: wait
                [_sync setRate:0];
            }
            [self waitLocked:0.05];
            continue;
        }
        if (_stalled && (_finished || _lastT > now + ahead)) {
            _stalled = NO;
            [_sync setRate:_rate];
        }
        PFrame f = _fr[_decodeIdx];
        if (f.audio) {
            // Audio: decode G.711A and queue it at the time of the video around it.
            _decodeIdx++;
            if (_haveFirstFrame && f.t >= now - 0.2) {
                double t = (_audioNext > 0 && fabs(_audioNext - f.t) < 0.5) ? _audioNext : f.t;
                size_t ns = f.len;
                int16_t *pcm = malloc(ns * 2);
                for (size_t i = 0; i < ns; i++) pcm[i] = alaw2linear(_buf[f.off + i]);
                _audioNext = t + (double)ns / 8000.0;
                pthread_mutex_unlock(&_mx);
                [self enqueueAudio:pcm samples:ns at:t];
                pthread_mutex_lock(&_mx);
            }
            continue;
        }
        if (_haveFirstFrame && f.t > now + ahead) { [self waitLocked:0.03]; continue; }

        // Copy the frame out so the buffer may grow while we decode.
        if (av_new_packet(pkt, (int)f.len) < 0) break;
        memcpy(pkt->data, _buf + f.off, f.len);
        pkt->pts = (int64_t)llround(f.t * 90000);
        if (f.key) pkt->flags |= AV_PKT_FLAG_KEY;
        _decodeIdx++;
        BOOL newGen = gen != _seekGen;
        gen = _seekGen;
        pthread_mutex_unlock(&_mx);

        if (!ctx) {
            const AVCodec *c = avcodec_find_decoder(f.media == 3 ? AV_CODEC_ID_HEVC : AV_CODEC_ID_H264);
            ctx = c ? avcodec_alloc_context3(c) : NULL;
            if (ctx) {
                ctx->pkt_timebase = (AVRational){ 1, 90000 };
                if (av_hwdevice_ctx_create(&hw, AV_HWDEVICE_TYPE_VIDEOTOOLBOX, NULL, NULL, 0) == 0) ctx->hw_device_ctx = av_buffer_ref(hw);
                if (avcodec_open2(ctx, c, NULL) < 0) avcodec_free_context(&ctx);
            }
        } else if (newGen) {
            avcodec_flush_buffers(ctx);
        }
        if (ctx && avcodec_send_packet(ctx, pkt) >= 0) {
            while (avcodec_receive_frame(ctx, frame) >= 0) {
                CVPixelBufferRef pb = NULL;
                if (frame->format == AV_PIX_FMT_VIDEOTOOLBOX) {
                    pb = CVPixelBufferRetain((CVPixelBufferRef)frame->data[3]);
                } else if (frame->width > 1 && frame->height > 1) {
                    int w = frame->width & ~1, h = frame->height & ~1;
                    if (!sws || w != sw || h != shh || frame->format != sfmt) {
                        if (sws) sws_freeContext(sws);
                        if (pool) { CVPixelBufferPoolRelease(pool); pool = NULL; }
                        sws = sws_getContext(frame->width, frame->height, frame->format, w, h, AV_PIX_FMT_NV12, SWS_FAST_BILINEAR, NULL, NULL, NULL);
                        NSDictionary *a = @{ (id)kCVPixelBufferPixelFormatTypeKey: @(kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange),
                                             (id)kCVPixelBufferWidthKey: @(w), (id)kCVPixelBufferHeightKey: @(h),
                                             (id)kCVPixelBufferIOSurfacePropertiesKey: @{} };
                        CVPixelBufferPoolCreate(kCFAllocatorDefault, NULL, (__bridge CFDictionaryRef)a, &pool);
                        sw = w; shh = h; sfmt = frame->format;
                    }
                    if (sws && pool && CVPixelBufferPoolCreatePixelBuffer(kCFAllocatorDefault, pool, &pb) == kCVReturnSuccess) {
                        CVPixelBufferLockBaseAddress(pb, 0);
                        uint8_t *dst[4] = { CVPixelBufferGetBaseAddressOfPlane(pb, 0), CVPixelBufferGetBaseAddressOfPlane(pb, 1), NULL, NULL };
                        int st[4] = { (int)CVPixelBufferGetBytesPerRowOfPlane(pb, 0), (int)CVPixelBufferGetBytesPerRowOfPlane(pb, 1), 0, 0 };
                        sws_scale(sws, (const uint8_t *const *)frame->data, frame->linesize, 0, frame->height, dst, st);
                        CVPixelBufferUnlockBaseAddress(pb, 0);
                    }
                }
                if (pb) {
                    if (!fmt || !CMVideoFormatDescriptionMatchesImageBuffer(fmt, pb)) {
                        if (fmt) CFRelease(fmt);
                        fmt = NULL;
                        CMVideoFormatDescriptionCreateForImageBuffer(kCFAllocatorDefault, pb, &fmt);
                    }
                    int64_t pts = frame->best_effort_timestamp != AV_NOPTS_VALUE ? frame->best_effort_timestamp : frame->pts;
                    CMSampleTimingInfo ti = { kCMTimeInvalid, CMTimeMake(pts, 90000), kCMTimeInvalid };
                    CMSampleBufferRef sb = NULL;
                    if (fmt && CMSampleBufferCreateReadyWithImageBuffer(kCFAllocatorDefault, pb, fmt, &ti, &sb) == noErr) {
                        AVSampleBufferVideoRenderer *r = _layer.sampleBufferRenderer;
                        if (r.status == AVQueuedSampleBufferRenderingStatusFailed) [r flush];
                        [r enqueueSampleBuffer:sb];
                        CFRelease(sb);
                        pthread_mutex_lock(&_mx);
                        if (!_haveFirstFrame) {
                            // First picture: start the clock here.
                            _haveFirstFrame = YES;
                            [_sync setRate:_rate time:CMTimeMake(pts, 90000)];
                        }
                        pthread_mutex_unlock(&_mx);
                    }
                    CVPixelBufferRelease(pb);
                }
                av_frame_unref(frame);
            }
        }
        av_packet_unref(pkt);
        pthread_mutex_lock(&_mx);
    }
    pthread_mutex_unlock(&_mx);
    if (fmt) CFRelease(fmt);
    if (sws) sws_freeContext(sws);
    if (pool) CVPixelBufferPoolRelease(pool);
    av_packet_free(&pkt);
    av_frame_free(&frame);
    avcodec_free_context(&ctx);
    av_buffer_unref(&hw);
}

// Takes ownership of pcm.
- (void)enqueueAudio:(int16_t *)pcm samples:(size_t)n at:(double)t {
    CMBlockBufferRef block = NULL;
    if (CMBlockBufferCreateWithMemoryBlock(kCFAllocatorDefault, pcm, n * 2, kCFAllocatorMalloc, NULL, 0, n * 2, 0, &block) != noErr) {
        free(pcm);
        return;
    }
    CMSampleBufferRef sb = NULL;
    if (CMAudioSampleBufferCreateReadyWithPacketDescriptions(kCFAllocatorDefault, block, _afmt, (CMItemCount)n,
                                                             CMTimeMakeWithSeconds(t, 8000), NULL, &sb) == noErr) {
        if (_audio.status == AVQueuedSampleBufferRenderingStatusFailed) [_audio flush];
        [_audio enqueueSampleBuffer:sb];
        CFRelease(sb);
    }
    CFRelease(block);
}

- (void)waitLocked:(double)seconds {
    struct timespec ts;
    clock_gettime(CLOCK_REALTIME, &ts);
    long ns = ts.tv_nsec + (long)(seconds * 1e9);
    ts.tv_sec += ns / 1000000000L;
    ts.tv_nsec = ns % 1000000000L;
    pthread_cond_timedwait(&_cv, &_mx, &ts);
}

@end
