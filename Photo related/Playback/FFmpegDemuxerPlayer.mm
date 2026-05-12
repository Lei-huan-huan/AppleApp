#import "FFmpegDemuxerPlayer.h"
#import <AudioToolbox/AudioToolbox.h>
#import <pthread.h>
#import <stdatomic.h>
#import <stdlib.h>

extern "C" {
#include <libavcodec/avcodec.h>
#include <libavformat/avformat.h>
#include <libavutil/channel_layout.h>
#include <libavutil/imgutils.h>
#include <libavutil/opt.h>
#include <libavutil/pixdesc.h>
#include <libavutil/samplefmt.h>
#include <libavutil/time.h>
#include <libswresample/swresample.h>
#include <libswscale/swscale.h>
}

static int interrupt_cb(void *ctx) {
  return atomic_load((atomic_int *)ctx) != 0;
}

/// 与 LearnFFmpeg `ff_player.cpp` 中 `is_remote_url` 一致。
static BOOL LFFIsRemoteOpenURL(NSString *openURL) {
  static NSArray<NSString *> *prefixes;
  static dispatch_once_t once;
  dispatch_once(&once, ^{
    prefixes = @[
      @"http://", @"https://", @"tcp://", @"udp://", @"rtmp://", @"rtmps://", @"rtmpt://", @"rtmpts://", @"rtmpe://",
      @"rtmpte://", @"mmsh://", @"mmst://"
    ];
  });
  for (NSString *p in prefixes) {
    if ([openURL hasPrefix:p]) {
      return YES;
    }
  }
  return NO;
}

static NSString *LFFOpenInputStringForURL(NSURL *url) {
  NSString *abs = url.absoluteString ?: @"";
  if (LFFIsRemoteOpenURL(abs)) {
    return abs;
  }
  NSString *path = url.path ?: @"";
  if (path.length > 0 && [path hasPrefix:@"/"]) {
    return [@"file:" stringByAppendingString:path];
  }
  if (path.length > 0) {
    return path;
  }
  return abs;
}

static enum AVPixelFormat LFFGetFormat(AVCodecContext *ctx, const enum AVPixelFormat *pixFmts) {
  (void)ctx;
  if (pixFmts == NULL) {
    return AV_PIX_FMT_NONE;
  }
  for (const enum AVPixelFormat *p = pixFmts; *p != AV_PIX_FMT_NONE; p++) {
    const AVPixFmtDescriptor *desc = av_pix_fmt_desc_get(*p);
    if (desc == NULL) {
      continue;
    }
    if ((desc->flags & AV_PIX_FMT_FLAG_HWACCEL) == 0) {
      return *p;
    }
  }
  return pixFmts[0];
}

#pragma mark - Packet Queue

typedef struct LFFPktNode {
  AVPacket *pkt; // NULL 表示 EOF 哨兵
  BOOL eof;
  struct LFFPktNode *next;
} LFFPktNode;

typedef struct LFFPktQueue {
  LFFPktNode *first;
  LFFPktNode *last;
  int count;
  int max;
  BOOL aborted;
  pthread_mutex_t mtx;
  pthread_cond_t cond_not_empty;
  pthread_cond_t cond_not_full;
} LFFPktQueue;

static void pq_init(LFFPktQueue *q, int max) {
  q->first = NULL;
  q->last = NULL;
  q->count = 0;
  q->max = max;
  q->aborted = NO;
  pthread_mutex_init(&q->mtx, NULL);
  pthread_cond_init(&q->cond_not_empty, NULL);
  pthread_cond_init(&q->cond_not_full, NULL);
}

static void pq_destroy(LFFPktQueue *q) {
  LFFPktNode *n = q->first;
  while (n != NULL) {
    LFFPktNode *next = n->next;
    if (n->pkt) {
      av_packet_free(&n->pkt);
    }
    free(n);
    n = next;
  }
  q->first = q->last = NULL;
  q->count = 0;
  pthread_mutex_destroy(&q->mtx);
  pthread_cond_destroy(&q->cond_not_empty);
  pthread_cond_destroy(&q->cond_not_full);
}

static void pq_abort(LFFPktQueue *q) {
  pthread_mutex_lock(&q->mtx);
  q->aborted = YES;
  pthread_cond_broadcast(&q->cond_not_full);
  pthread_cond_broadcast(&q->cond_not_empty);
  pthread_mutex_unlock(&q->mtx);
}

static void pq_reset(LFFPktQueue *q) {
  pthread_mutex_lock(&q->mtx);
  LFFPktNode *n = q->first;
  while (n != NULL) {
    LFFPktNode *next = n->next;
    if (n->pkt) {
      av_packet_free(&n->pkt);
    }
    free(n);
    n = next;
  }
  q->first = q->last = NULL;
  q->count = 0;
  q->aborted = NO;
  pthread_mutex_unlock(&q->mtx);
}

/// 入队；返回 NO 表示队列已 abort，调用方自行释放 pkt。
static BOOL pq_push(LFFPktQueue *q, AVPacket *pkt, BOOL eof) {
  LFFPktNode *n = (LFFPktNode *)malloc(sizeof(LFFPktNode));
  if (n == NULL) {
    return NO;
  }
  n->pkt = pkt;
  n->eof = eof;
  n->next = NULL;

  pthread_mutex_lock(&q->mtx);
  while (q->count >= q->max && !q->aborted) {
    pthread_cond_wait(&q->cond_not_full, &q->mtx);
  }
  if (q->aborted) {
    pthread_mutex_unlock(&q->mtx);
    free(n);
    return NO;
  }
  if (q->last == NULL) {
    q->first = n;
  } else {
    q->last->next = n;
  }
  q->last = n;
  q->count++;
  pthread_cond_signal(&q->cond_not_empty);
  pthread_mutex_unlock(&q->mtx);
  return YES;
}

/// 出队；返回 NO 表示已 abort 且队列空。
static BOOL pq_pop(LFFPktQueue *q, AVPacket **outPkt, BOOL *outEof) {
  pthread_mutex_lock(&q->mtx);
  while (q->count == 0 && !q->aborted) {
    pthread_cond_wait(&q->cond_not_empty, &q->mtx);
  }
  if (q->count == 0 && q->aborted) {
    pthread_mutex_unlock(&q->mtx);
    return NO;
  }
  LFFPktNode *n = q->first;
  q->first = n->next;
  if (q->first == NULL) {
    q->last = NULL;
  }
  q->count--;
  pthread_cond_signal(&q->cond_not_full);
  pthread_mutex_unlock(&q->mtx);

  *outPkt = n->pkt;
  *outEof = n->eof;
  free(n);
  return YES;
}

#pragma mark - 常量

// 单个 AudioQueue 缓冲帧数；3 个缓冲共约 250ms，足够吸收抖动。
static const UInt32 kLFFAudioFramesPerBuffer = 4096;
static const int kLFFAudioBufferCount = 3;
static const int kLFFAudioPktQueueMax = 80; // 约 1.5 秒音频包
static const int kLFFVideoPktQueueMax = 30; // 约 1 秒视频包

@interface FFmpegDemuxerPlayer () {
  AVFormatContext *_fmt;

  // 视频解码上下文（仅视频线程访问）
  AVCodecContext *_vctx;
  int _videoStreamIndex;
  AVFrame *_decoded;
  AVFrame *_nv12;
  SwsContext *_sws;
  int _swsSrcW;
  int _swsSrcH;
  AVPixelFormat _swsSrcFmt;
  AVRational _videoTimeBase;

  // 音频解码上下文（仅音频线程访问）
  AVCodecContext *_actx;
  int _audioStreamIndex;
  SwrContext *_swr;
  AVFrame *_aframe;
  AVRational _audioTimeBase;
  int _audioOutSampleRate;
  int _audioOutChannels;
  int _audioBytesPerSec;

  // PCM 环形缓冲（音频线程写，AQ 回调读）
  uint8_t *_pcm;
  size_t _pcmCap;
  size_t _pcmHead;
  size_t _pcmTail;
  size_t _pcmAvail;
  pthread_mutex_t _pcmMtx;
  pthread_cond_t _pcmCondNotFull;

  // AudioQueue
  AudioQueueRef _aq;
  AudioQueueBufferRef _aqBufs[kLFFAudioBufferCount];
  BOOL _aqStarted;
  size_t _aqBufBytes;

  // 音频时钟（墙钟锚定）
  pthread_mutex_t _clockMtx;
  int64_t _audioStreamStartPtsUs;   // 第一次写入 ring 的 PCM 起始 PTS
  BOOL _audioStreamStartValid;
  int64_t _audioBytesWritten;        // 累计写入 ring 的真实音频字节
  int64_t _audioWritePtsUs;          // 最近一次写入 ring 的尾端 PTS
  int64_t _audioBytesPlayedByAQ;     // AQ 已确认播放完毕的真实音频字节
  int64_t _audioAnchorPtsUs;
  int64_t _audioAnchorWallUs;
  BOOL _audioAnchorValid;
  BOOL _audioClockPaused;
  int64_t _audioClockPauseStartUs;

  // 包队列
  LFFPktQueue _audioQ;
  LFFPktQueue _videoQ;
  BOOL _queuesInited;

  // 线程
  pthread_t _demuxTid;
  pthread_t _audioTid;
  pthread_t _videoTid;
  BOOL _demuxTidCreated;
  BOOL _audioTidCreated;
  BOOL _videoTidCreated;

  atomic_int _interrupt;
  BOOL _started;

  // 最新视频帧
  NSLock *_lock;
  CVPixelBufferRef _latestBuf;

  CGSize _videoSize;
  double _frameIntervalSec;
  BOOL _didNetworkInit;
  int64_t _durationMs;
  NSCondition *_pauseCond;
  BOOL _decodePaused;

  // 完成 / 错误一次性回调
  atomic_int _completionFired;
}
@end

@implementation FFmpegDemuxerPlayer

- (instancetype)init {
  self = [super init];
  if (self) {
    _lock = [[NSLock alloc] init];
    _pauseCond = [[NSCondition alloc] init];
    atomic_init(&_interrupt, 0);
    atomic_init(&_completionFired, 0);
    _videoStreamIndex = -1;
    _audioStreamIndex = -1;
    _swsSrcW = -1;
    _swsSrcH = -1;
    _swsSrcFmt = AV_PIX_FMT_NONE;
    _durationMs = 0;
    pthread_mutex_init(&_pcmMtx, NULL);
    pthread_cond_init(&_pcmCondNotFull, NULL);
    pthread_mutex_init(&_clockMtx, NULL);
  }
  return self;
}

- (void)dealloc {
  [self close];
  pthread_mutex_destroy(&_pcmMtx);
  pthread_cond_destroy(&_pcmCondNotFull);
  pthread_mutex_destroy(&_clockMtx);
}

#pragma mark - 公开属性

- (int64_t)durationMs {
  return _durationMs;
}

- (CGSize)videoSize {
  return _videoSize;
}

- (double)frameDuration {
  return _frameIntervalSec > 0 ? _frameIntervalSec : (1.0 / 30.0);
}

#pragma mark - 暂停 / 恢复

- (void)waitWhilePaused {
  [_pauseCond lock];
  while (_decodePaused && !atomic_load(&_interrupt)) {
    [_pauseCond wait];
  }
  [_pauseCond unlock];
}

- (void)pauseDecoding {
  [_pauseCond lock];
  _decodePaused = YES;
  [_pauseCond unlock];

  if (_aq != NULL && _aqStarted) {
    AudioQueuePause(_aq);
  }

  pthread_mutex_lock(&_clockMtx);
  if (_audioAnchorValid && !_audioClockPaused) {
    _audioClockPaused = YES;
    _audioClockPauseStartUs = av_gettime();
  }
  pthread_mutex_unlock(&_clockMtx);
}

- (void)resumeDecoding {
  pthread_mutex_lock(&_clockMtx);
  if (_audioAnchorValid && _audioClockPaused) {
    int64_t pauseDur = av_gettime() - _audioClockPauseStartUs;
    _audioAnchorWallUs += pauseDur;
    _audioClockPaused = NO;
    _audioClockPauseStartUs = 0;
  }
  pthread_mutex_unlock(&_clockMtx);

  [_pauseCond lock];
  _decodePaused = NO;
  [_pauseCond broadcast];
  [_pauseCond unlock];

  if (_aq != NULL && _aqStarted) {
    AudioQueueStart(_aq, NULL);
  }
}

#pragma mark - 错误辅助

- (NSError *)ffmpegError:(int)code message:(NSString *)msg {
  char buf[AV_ERROR_MAX_STRING_SIZE];
  av_strerror(code, buf, sizeof(buf));
  return [NSError errorWithDomain:@"FFmpegDemuxerPlayer"
                             code:code
                         userInfo:@{NSLocalizedDescriptionKey : [NSString stringWithFormat:@"%@: %s", msg, buf]}];
}

#pragma mark - AudioQueue

static void LFFAudioQueueCallback(void *userData, AudioQueueRef inAQ, AudioQueueBufferRef inBuffer) {
  FFmpegDemuxerPlayer *p = (__bridge FFmpegDemuxerPlayer *)userData;
  [p handleAudioQueueBuffer:inBuffer queue:inAQ];
}

/// 从环形缓冲拷贝最多 cap 字节到 dst。返回拷贝的真实字节数。需要持有 _pcmMtx。
- (size_t)drainPCMRingIntoLocked:(uint8_t *)dst capacity:(size_t)cap {
  size_t got = 0;
  while (got < cap && _pcmAvail > 0) {
    size_t want = cap - got;
    size_t toEnd = _pcmCap - _pcmTail;
    size_t n = want < _pcmAvail ? want : _pcmAvail;
    if (n > toEnd) {
      n = toEnd;
    }
    memcpy(dst + got, _pcm + _pcmTail, n);
    _pcmTail = (_pcmTail + n) % _pcmCap;
    _pcmAvail -= n;
    got += n;
  }
  if (got > 0) {
    pthread_cond_broadcast(&_pcmCondNotFull);
  }
  return got;
}

- (void)handleAudioQueueBuffer:(AudioQueueBufferRef)buf queue:(AudioQueueRef)aq {
  // 上一次填入这个 buffer 的"真实音频字节数"放在 mUserData；
  // 回调时认为已播放完毕，累计到 _audioBytesPlayedByAQ，再用墙钟重锚音频时钟。
  size_t prevReal = (size_t)(uintptr_t)buf->mUserData;
  if (prevReal > 0) {
    pthread_mutex_lock(&_clockMtx);
    _audioBytesPlayedByAQ += (int64_t)prevReal;
    if (_audioStreamStartValid && _audioBytesPerSec > 0) {
      _audioAnchorPtsUs = _audioStreamStartPtsUs
                          + _audioBytesPlayedByAQ * 1000000 / _audioBytesPerSec;
      _audioAnchorWallUs = av_gettime();
      _audioAnchorValid = YES;
      _audioClockPaused = NO;
      _audioClockPauseStartUs = 0;
    }
    pthread_mutex_unlock(&_clockMtx);
  }

  UInt32 cap = buf->mAudioDataBytesCapacity;
  uint8_t *dst = (uint8_t *)buf->mAudioData;

  pthread_mutex_lock(&_pcmMtx);
  size_t got = [self drainPCMRingIntoLocked:dst capacity:cap];
  pthread_mutex_unlock(&_pcmMtx);

  // 没拿够就用静音补齐：保证 AudioQueue 不会因为短读而停转、并触发热循环。
  if (got < cap) {
    memset(dst + got, 0, cap - got);
  }
  buf->mAudioDataByteSize = cap;
  buf->mUserData = (void *)(uintptr_t)got;

  OSStatus st = AudioQueueEnqueueBuffer(aq, buf, 0, NULL);
  (void)st;
}

- (BOOL)setupAudioQueue {
  AudioStreamBasicDescription fmt = {0};
  fmt.mSampleRate = (Float64)_audioOutSampleRate;
  fmt.mFormatID = kAudioFormatLinearPCM;
  fmt.mFormatFlags = kLinearPCMFormatFlagIsSignedInteger | kLinearPCMFormatFlagIsPacked;
  fmt.mBitsPerChannel = 16;
  fmt.mChannelsPerFrame = (UInt32)_audioOutChannels;
  fmt.mFramesPerPacket = 1;
  fmt.mBytesPerFrame = (UInt32)(_audioOutChannels * 2);
  fmt.mBytesPerPacket = fmt.mBytesPerFrame;

  OSStatus st = AudioQueueNewOutput(&fmt, LFFAudioQueueCallback, (__bridge void *)self, NULL, NULL, 0, &_aq);
  if (st != noErr || _aq == NULL) {
    return NO;
  }

  _aqBufBytes = (size_t)(kLFFAudioFramesPerBuffer * fmt.mBytesPerFrame);
  for (int i = 0; i < kLFFAudioBufferCount; i++) {
    st = AudioQueueAllocateBuffer(_aq, (UInt32)_aqBufBytes, &_aqBufs[i]);
    if (st != noErr || _aqBufs[i] == NULL) {
      [self teardownAudioQueue];
      return NO;
    }
    // 预填静音入队：等解码线程喂到真实音频，回调会自动替换。
    memset(_aqBufs[i]->mAudioData, 0, _aqBufBytes);
    _aqBufs[i]->mAudioDataByteSize = (UInt32)_aqBufBytes;
    _aqBufs[i]->mUserData = (void *)(uintptr_t)0;
    AudioQueueEnqueueBuffer(_aq, _aqBufs[i], 0, NULL);
  }
  return YES;
}

- (void)teardownAudioQueue {
  if (_aq != NULL) {
    AudioQueueStop(_aq, true);
    AudioQueueDispose(_aq, true);
    _aq = NULL;
  }
  for (int i = 0; i < kLFFAudioBufferCount; i++) {
    _aqBufs[i] = NULL;
  }
  _aqStarted = NO;
  _aqBufBytes = 0;
}

#pragma mark - 音频时钟

/// 返回当前正在喇叭里播放出的音频 PTS（微秒）；尚未真正开始播放真实音频时返回 INT64_MIN。
- (int64_t)currentAudioClockUs {
  if (_audioStreamIndex < 0 || _audioBytesPerSec <= 0) {
    return INT64_MIN;
  }
  pthread_mutex_lock(&_clockMtx);
  // 静音预填还没结束（一字节真实音频都没播过），先返回不可用，
  // 让视频线程回退到本地墙钟，避免被错误时钟带跑。
  if (!_audioAnchorValid || _audioBytesPlayedByAQ <= 0) {
    pthread_mutex_unlock(&_clockMtx);
    return INT64_MIN;
  }
  int64_t pts = _audioAnchorPtsUs;
  int64_t wall = _audioAnchorWallUs;
  BOOL paused = _audioClockPaused;
  int64_t writePts = _audioWritePtsUs;
  pthread_mutex_unlock(&_clockMtx);

  if (!paused) {
    pts += av_gettime() - wall;
  }
  if (writePts > 0 && pts > writePts) {
    pts = writePts;
  }
  return pts;
}

#pragma mark - PCM 写入

- (void)writePCM:(const uint8_t *)data length:(size_t)len ptsStartUs:(int64_t)ptsStartUs {
  if (data == NULL || len == 0 || _pcm == NULL || _audioBytesPerSec <= 0) {
    return;
  }
  pthread_mutex_lock(&_pcmMtx);
  size_t written = 0;
  while (written < len) {
    while (_pcmAvail == _pcmCap && !atomic_load(&_interrupt)) {
      pthread_cond_wait(&_pcmCondNotFull, &_pcmMtx);
    }
    if (atomic_load(&_interrupt)) {
      break;
    }
    size_t free_space = _pcmCap - _pcmAvail;
    size_t toEnd = _pcmCap - _pcmHead;
    size_t chunk = len - written;
    if (chunk > free_space) {
      chunk = free_space;
    }
    if (chunk > toEnd) {
      chunk = toEnd;
    }
    memcpy(_pcm + _pcmHead, data + written, chunk);
    _pcmHead = (_pcmHead + chunk) % _pcmCap;
    _pcmAvail += chunk;
    written += chunk;
  }
  pthread_mutex_unlock(&_pcmMtx);

  if (written == 0) {
    return;
  }
  pthread_mutex_lock(&_clockMtx);
  if (!_audioStreamStartValid) {
    _audioStreamStartPtsUs = ptsStartUs;
    _audioStreamStartValid = YES;
  }
  _audioBytesWritten += (int64_t)written;
  _audioWritePtsUs = ptsStartUs + (int64_t)written * 1000000 / _audioBytesPerSec;
  pthread_mutex_unlock(&_clockMtx);
}

#pragma mark - 资源生命周期

- (void)freeAudioState {
  if (_swr) {
    swr_free(&_swr);
  }
  av_frame_free(&_aframe);
  avcodec_free_context(&_actx);
  _audioStreamIndex = -1;
  _audioOutSampleRate = 0;
  _audioOutChannels = 0;
  _audioBytesPerSec = 0;

  if (_pcm) {
    free(_pcm);
    _pcm = NULL;
  }
  _pcmCap = 0;
  _pcmHead = 0;
  _pcmTail = 0;
  _pcmAvail = 0;
  _audioStreamStartPtsUs = 0;
  _audioStreamStartValid = NO;
  _audioBytesWritten = 0;
  _audioWritePtsUs = 0;
  _audioBytesPlayedByAQ = 0;
  _audioAnchorPtsUs = 0;
  _audioAnchorWallUs = 0;
  _audioAnchorValid = NO;
  _audioClockPaused = NO;
  _audioClockPauseStartUs = 0;
}

- (void)freeDecoderState {
  [self resumeDecoding];
  [self teardownAudioQueue];

  if (_sws) {
    sws_freeContext(_sws);
    _sws = NULL;
  }
  _swsSrcW = -1;
  _swsSrcH = -1;
  _swsSrcFmt = AV_PIX_FMT_NONE;

  av_frame_free(&_decoded);
  av_frame_free(&_nv12);
  avcodec_free_context(&_vctx);
  [self freeAudioState];

  if (_queuesInited) {
    pq_destroy(&_audioQ);
    pq_destroy(&_videoQ);
    _queuesInited = NO;
  }

  if (_fmt) {
    avformat_close_input(&_fmt);
    _fmt = NULL;
  }
  _videoStreamIndex = -1;
  if (_didNetworkInit) {
    avformat_network_deinit();
    _didNetworkInit = NO;
  }
}

- (BOOL)openAudioStream {
  int aidx = av_find_best_stream(_fmt, AVMEDIA_TYPE_AUDIO, -1, -1, NULL, 0);
  if (aidx < 0) {
    _audioStreamIndex = -1;
    return YES;
  }
  AVStream *ast = _fmt->streams[aidx];
  const AVCodec *codec = avcodec_find_decoder(ast->codecpar->codec_id);
  if (!codec) {
    _audioStreamIndex = -1;
    return YES;
  }
  _actx = avcodec_alloc_context3(codec);
  if (!_actx) {
    _audioStreamIndex = -1;
    return YES;
  }
  avcodec_parameters_to_context(_actx, ast->codecpar);
  _actx->pkt_timebase = ast->time_base;
  if (avcodec_open2(_actx, codec, NULL) < 0) {
    avcodec_free_context(&_actx);
    _audioStreamIndex = -1;
    return YES;
  }
  _aframe = av_frame_alloc();
  if (!_aframe) {
    avcodec_free_context(&_actx);
    _audioStreamIndex = -1;
    return YES;
  }

  int srcRate = _actx->sample_rate > 0 ? _actx->sample_rate : 44100;
  int srcCh = _actx->ch_layout.nb_channels > 0 ? _actx->ch_layout.nb_channels : 2;
  _audioOutSampleRate = srcRate;
  _audioOutChannels = srcCh > 2 ? 2 : (srcCh < 1 ? 1 : srcCh);
  _audioBytesPerSec = _audioOutSampleRate * _audioOutChannels * 2;

  AVChannelLayout outLayout;
  av_channel_layout_default(&outLayout, _audioOutChannels);

  int sret = swr_alloc_set_opts2(&_swr,
                                 &outLayout, AV_SAMPLE_FMT_S16, _audioOutSampleRate,
                                 &_actx->ch_layout, _actx->sample_fmt, _actx->sample_rate,
                                 0, NULL);
  av_channel_layout_uninit(&outLayout);
  if (sret < 0 || _swr == NULL || swr_init(_swr) < 0) {
    if (_swr) {
      swr_free(&_swr);
    }
    av_frame_free(&_aframe);
    avcodec_free_context(&_actx);
    _audioStreamIndex = -1;
    return YES;
  }

  _audioStreamIndex = aidx;
  _audioTimeBase = ast->time_base;

  size_t cap = (size_t)(_audioBytesPerSec * 2); // ~2 秒
  if (cap < 64 * 1024) cap = 64 * 1024;
  if (cap > 2 * 1024 * 1024) cap = 2 * 1024 * 1024;
  _pcm = (uint8_t *)malloc(cap);
  if (_pcm == NULL) {
    [self freeAudioState];
    return YES;
  }
  _pcmCap = cap;
  _pcmHead = 0;
  _pcmTail = 0;
  _pcmAvail = 0;
  return YES;
}

- (BOOL)ffOpenMedia:(NSURL *)url error:(NSError *__autoreleasing _Nullable *_Nullable)error {
  [self close];

  NSString *openStr = LFFOpenInputStringForURL(url);
  if (openStr.length == 0) {
    if (error) {
      *error = [NSError errorWithDomain:@"FFmpegDemuxerPlayer"
                                   code:-1
                               userInfo:@{NSLocalizedDescriptionKey : @"Empty media URL"}];
    }
    return NO;
  }

  avformat_network_init();
  _didNetworkInit = YES;

  AVDictionary *opts = NULL;
  if (LFFIsRemoteOpenURL(openStr)) {
    av_dict_set(&opts, "stimeout", "5000000", 0);
    av_dict_set(&opts, "rw_timeout", "10000000", 0);
    av_dict_set(&opts, "user_agent", "LearnFFmpeg/1.0", 0);
  }

  int ret = avformat_open_input(&_fmt, openStr.UTF8String, NULL, &opts);
  av_dict_free(&opts);
  if (ret < 0) {
    if (error) {
      *error = [self ffmpegError:ret message:@"avformat_open_input"];
    }
    avformat_network_deinit();
    _didNetworkInit = NO;
    return NO;
  }

  _fmt->interrupt_callback.callback = interrupt_cb;
  _fmt->interrupt_callback.opaque = &_interrupt;

  ret = avformat_find_stream_info(_fmt, NULL);
  if (ret < 0) {
    if (error) {
      *error = [self ffmpegError:ret message:@"avformat_find_stream_info"];
    }
    [self freeDecoderState];
    return NO;
  }

  _videoStreamIndex = av_find_best_stream(_fmt, AVMEDIA_TYPE_VIDEO, -1, -1, NULL, 0);
  if (_videoStreamIndex < 0) {
    if (error) {
      *error = [NSError errorWithDomain:@"FFmpegDemuxerPlayer"
                                   code:-2
                               userInfo:@{NSLocalizedDescriptionKey : @"No video stream"}];
    }
    [self freeDecoderState];
    return NO;
  }

  AVStream *st = _fmt->streams[_videoStreamIndex];
  const char *codecName = avcodec_get_name(st->codecpar->codec_id);
  const AVCodec *codec = avcodec_find_decoder(st->codecpar->codec_id);
  if (!codec) {
    if (error) {
      NSString *msg = [NSString stringWithFormat:@"未找到 %s 解码器", codecName ? codecName : "?"];
      *error = [NSError errorWithDomain:@"FFmpegDemuxerPlayer"
                                   code:-3
                               userInfo:@{NSLocalizedDescriptionKey : msg}];
    }
    [self freeDecoderState];
    return NO;
  }

  _vctx = avcodec_alloc_context3(codec);
  if (!_vctx) {
    if (error) {
      *error = [NSError errorWithDomain:@"FFmpegDemuxerPlayer"
                                   code:-4
                               userInfo:@{NSLocalizedDescriptionKey : @"avcodec_alloc_context3"}];
    }
    [self freeDecoderState];
    return NO;
  }

  avcodec_parameters_to_context(_vctx, st->codecpar);
  _vctx->pkt_timebase = st->time_base;
  _vctx->get_format = LFFGetFormat;
  ret = avcodec_open2(_vctx, codec, NULL);
  if (ret < 0) {
    if (error) {
      *error = [self ffmpegError:ret message:@"avcodec_open2"];
    }
    [self freeDecoderState];
    return NO;
  }

  _decoded = av_frame_alloc();
  _nv12 = av_frame_alloc();
  if (!_decoded || !_nv12) {
    if (error) {
      *error = [NSError errorWithDomain:@"FFmpegDemuxerPlayer"
                                   code:-5
                               userInfo:@{NSLocalizedDescriptionKey : @"Frame alloc"}];
    }
    [self freeDecoderState];
    return NO;
  }

  _nv12->format = AV_PIX_FMT_NV12;
  _nv12->width = _vctx->width;
  _nv12->height = _vctx->height;
  ret = av_frame_get_buffer(_nv12, 32);
  if (ret < 0) {
    if (error) {
      *error = [self ffmpegError:ret message:@"nv12 buffer"];
    }
    [self freeDecoderState];
    return NO;
  }

  _videoSize = CGSizeMake(_vctx->width, _vctx->height);
  _videoTimeBase = st->time_base;
  if (_fmt->duration != AV_NOPTS_VALUE && _fmt->duration > 0) {
    _durationMs = (int64_t)(_fmt->duration / 1000);
  } else {
    _durationMs = 0;
  }

  AVRational fr = av_guess_frame_rate(_fmt, st, NULL);
  double fps = av_q2d(fr);
  if (fps < 1.0 || fps > 240.0) {
    fps = 30.0;
  }
  _frameIntervalSec = 1.0 / fps;

  (void)[self openAudioStream];
  if (_audioStreamIndex >= 0) {
    if (![self setupAudioQueue]) {
      [self freeAudioState];
    }
  }

  pq_init(&_audioQ, kLFFAudioPktQueueMax);
  pq_init(&_videoQ, kLFFVideoPktQueueMax);
  _queuesInited = YES;

  return YES;
}

- (BOOL)ensureSwsForFrame:(AVFrame *)src {
  if (_sws && _swsSrcW == src->width && _swsSrcH == src->height && _swsSrcFmt == (AVPixelFormat)src->format) {
    return YES;
  }
  if (_sws) {
    sws_freeContext(_sws);
    _sws = NULL;
  }
  _sws = sws_getContext(src->width, src->height, (AVPixelFormat)src->format, src->width, src->height,
                        AV_PIX_FMT_NV12, SWS_BILINEAR, NULL, NULL, NULL);
  if (!_sws) {
    return NO;
  }
  _swsSrcW = src->width;
  _swsSrcH = src->height;
  _swsSrcFmt = (AVPixelFormat)src->format;

  if (_nv12->width != src->width || _nv12->height != src->height) {
    av_frame_unref(_nv12);
    _nv12->format = AV_PIX_FMT_NV12;
    _nv12->width = src->width;
    _nv12->height = src->height;
    int r = av_frame_get_buffer(_nv12, 32);
    if (r < 0) {
      return NO;
    }
    _videoSize = CGSizeMake(src->width, src->height);
  }
  return YES;
}

#pragma mark - 线程入口

static void *LFFDemuxThreadEntry(void *ctx) {
  FFmpegDemuxerPlayer *p = (__bridge FFmpegDemuxerPlayer *)ctx;
  [p demuxLoop];
  return NULL;
}

static void *LFFAudioThreadEntry(void *ctx) {
  FFmpegDemuxerPlayer *p = (__bridge FFmpegDemuxerPlayer *)ctx;
  [p audioDecodeLoop];
  return NULL;
}

static void *LFFVideoThreadEntry(void *ctx) {
  FFmpegDemuxerPlayer *p = (__bridge FFmpegDemuxerPlayer *)ctx;
  [p videoDecodeLoop];
  return NULL;
}

- (void)start {
  if (_started || !_fmt) {
    return;
  }
  _started = YES;
  atomic_store(&_interrupt, 0);
  atomic_store(&_completionFired, 0);

  if (_aq != NULL && !_aqStarted) {
    if (AudioQueueStart(_aq, NULL) == noErr) {
      _aqStarted = YES;
    }
  }
  if (_audioStreamIndex >= 0 && _actx != NULL) {
    pthread_create(&_audioTid, NULL, LFFAudioThreadEntry, (__bridge void *)self);
    _audioTidCreated = YES;
  }
  pthread_create(&_videoTid, NULL, LFFVideoThreadEntry, (__bridge void *)self);
  _videoTidCreated = YES;
  pthread_create(&_demuxTid, NULL, LFFDemuxThreadEntry, (__bridge void *)self);
  _demuxTidCreated = YES;
}

- (void)stop {
  if (!_started) {
    return;
  }
  atomic_store(&_interrupt, 1);

  if (_queuesInited) {
    pq_abort(&_audioQ);
    pq_abort(&_videoQ);
  }
  pthread_mutex_lock(&_pcmMtx);
  pthread_cond_broadcast(&_pcmCondNotFull);
  pthread_mutex_unlock(&_pcmMtx);
  [self resumeDecoding];

  if (_demuxTidCreated) {
    pthread_join(_demuxTid, NULL);
    _demuxTidCreated = NO;
  }
  if (_audioTidCreated) {
    pthread_join(_audioTid, NULL);
    _audioTidCreated = NO;
  }
  if (_videoTidCreated) {
    pthread_join(_videoTid, NULL);
    _videoTidCreated = NO;
  }
  _started = NO;
  atomic_store(&_interrupt, 0);
}

- (void)close {
  [self stop];
  [_lock lock];
  if (_latestBuf) {
    CVPixelBufferRelease(_latestBuf);
    _latestBuf = NULL;
  }
  [_lock unlock];
  [self freeDecoderState];
}

#pragma mark - 一次性完成 / 错误回调

- (void)dispatchCompletion {
  if (atomic_exchange(&_completionFired, 1) != 0) {
    return;
  }
  dispatch_async(dispatch_get_main_queue(), ^{
    id<FFmpegDemuxerPlayerDelegate> d = self.delegate;
    if (d != nil && [d respondsToSelector:@selector(ffmpegPlayerDidCompletePlayback:)]) {
      [d ffmpegPlayerDidCompletePlayback:self];
    }
  });
}

- (void)dispatchErrorWithCode:(int)code message:(NSString *)msg {
  if (atomic_exchange(&_completionFired, 1) != 0) {
    return;
  }
  dispatch_async(dispatch_get_main_queue(), ^{
    id<FFmpegDemuxerPlayerDelegate> d = self.delegate;
    if (d != nil && [d respondsToSelector:@selector(ffmpegPlayer:didFailWithCode:message:)]) {
      [d ffmpegPlayer:self didFailWithCode:code message:msg];
    }
  });
}

#pragma mark - Demux 线程

- (void)demuxLoop {
  BOOL hitEOF = NO;
  int readErr = 0;

  while (atomic_load(&_interrupt) == 0) {
    [self waitWhilePaused];
    if (atomic_load(&_interrupt)) {
      break;
    }

    AVPacket *pkt = av_packet_alloc();
    if (pkt == NULL) {
      readErr = AVERROR(ENOMEM);
      break;
    }
    int ret = av_read_frame(_fmt, pkt);
    if (ret == AVERROR_EOF) {
      av_packet_free(&pkt);
      hitEOF = YES;
      break;
    }
    if (ret < 0) {
      av_packet_free(&pkt);
      readErr = ret;
      break;
    }

    if (pkt->stream_index == _audioStreamIndex && _audioStreamIndex >= 0 && _actx != NULL) {
      if (!pq_push(&_audioQ, pkt, NO)) {
        av_packet_free(&pkt);
        break;
      }
    } else if (pkt->stream_index == _videoStreamIndex) {
      if (!pq_push(&_videoQ, pkt, NO)) {
        av_packet_free(&pkt);
        break;
      }
    } else {
      av_packet_free(&pkt);
    }
  }

  // 给两个解码线程发 EOF 哨兵，让它们 drain 解码器后退出
  pq_push(&_audioQ, NULL, YES);
  pq_push(&_videoQ, NULL, YES);

  if (atomic_load(&_interrupt)) {
    return;
  }
  if (hitEOF) {
    [self dispatchCompletion];
    return;
  }
  if (readErr != 0) {
    const char *codecName = _vctx != NULL ? avcodec_get_name(_vctx->codec_id) : "?";
    NSString *msg = [self ffmpegError:readErr message:@"read/decode"].localizedDescription;
    msg = [NSString stringWithFormat:@"%@（%s）", msg, codecName ? codecName : "?"];
    if (_vctx != NULL && _vctx->codec_id == AV_CODEC_ID_AV1) {
      msg = [msg stringByAppendingString:@"，当前 FFmpeg 包可能缺少 AV1 软件解码器，建议先换 H.264/H.265 视频。"];
    }
    [self dispatchErrorWithCode:readErr message:msg];
  }
}

#pragma mark - 音频解码线程

- (void)resampleAndPushFrame:(AVFrame *)frame {
  AVRational usBase = {1, 1000000};
  int inSamples = frame->nb_samples;
  if (inSamples <= 0) {
    return;
  }

  int outSamplesEst = (int)av_rescale_rnd(
      swr_get_delay(_swr, _actx->sample_rate) + inSamples,
      _audioOutSampleRate, _actx->sample_rate, AV_ROUND_UP);
  if (outSamplesEst <= 0) {
    return;
  }

  int outLineSize = 0;
  uint8_t *outBuf = NULL;
  int allocErr = av_samples_alloc(&outBuf, &outLineSize, _audioOutChannels, outSamplesEst, AV_SAMPLE_FMT_S16, 0);
  if (allocErr < 0 || outBuf == NULL) {
    return;
  }

  int outSamples = swr_convert(_swr, &outBuf, outSamplesEst,
                               (const uint8_t **)frame->extended_data, inSamples);
  if (outSamples > 0) {
    size_t bytes = (size_t)outSamples * _audioOutChannels * 2;
    int64_t framePtsUs = 0;
    int64_t basePts = frame->best_effort_timestamp != AV_NOPTS_VALUE ? frame->best_effort_timestamp
                                                                      : frame->pts;
    if (basePts != AV_NOPTS_VALUE) {
      framePtsUs = av_rescale_q(basePts, _audioTimeBase, usBase);
    } else {
      framePtsUs = _audioWritePtsUs; // 接在尾巴上
    }
    [self writePCM:outBuf length:bytes ptsStartUs:framePtsUs];
  }
  av_freep(&outBuf);
}

- (void)audioDecodeLoop {
  while (atomic_load(&_interrupt) == 0) {
    [self waitWhilePaused];
    if (atomic_load(&_interrupt)) {
      break;
    }

    AVPacket *pkt = NULL;
    BOOL eof = NO;
    if (!pq_pop(&_audioQ, &pkt, &eof)) {
      break;
    }

    if (eof) {
      avcodec_send_packet(_actx, NULL);
      while (atomic_load(&_interrupt) == 0) {
        int r = avcodec_receive_frame(_actx, _aframe);
        if (r == AVERROR_EOF || r == AVERROR(EAGAIN) || r < 0) {
          av_frame_unref(_aframe);
          break;
        }
        [self resampleAndPushFrame:_aframe];
        av_frame_unref(_aframe);
      }
      break;
    }

    int ret = avcodec_send_packet(_actx, pkt);
    av_packet_free(&pkt);
    if (ret < 0 && ret != AVERROR(EAGAIN)) {
      continue;
    }
    while (atomic_load(&_interrupt) == 0) {
      int r = avcodec_receive_frame(_actx, _aframe);
      if (r == AVERROR(EAGAIN) || r == AVERROR_EOF) {
        break;
      }
      if (r < 0) {
        break;
      }
      [self resampleAndPushFrame:_aframe];
      av_frame_unref(_aframe);
    }
  }
}

#pragma mark - 视频解码线程

- (void)renderDecodedFrameSyncedHasAudio:(BOOL)hasAudio
                                  usBase:(AVRational)usBase
                             startPtsUs:(int64_t *)startPtsUs
                             startWallUs:(int64_t *)startWallUs
                          fallbackSleep:(useconds_t)fallbackSleep {
  if (![self ensureSwsForFrame:_decoded]) {
    return;
  }
  const uint8_t *srcSlice[4] = {_decoded->data[0], _decoded->data[1], _decoded->data[2], _decoded->data[3]};
  int srcStride[4] = {_decoded->linesize[0], _decoded->linesize[1], _decoded->linesize[2], _decoded->linesize[3]};
  uint8_t *dstSlice[4] = {_nv12->data[0], _nv12->data[1], NULL, NULL};
  int dstStride[4] = {_nv12->linesize[0], _nv12->linesize[1], 0, 0};
  sws_scale(_sws, srcSlice, srcStride, 0, _decoded->height, dstSlice, dstStride);

  int64_t pts = _decoded->best_effort_timestamp;
  if (pts != AV_NOPTS_VALUE) {
    int64_t ptsUs = av_rescale_q(pts, _videoTimeBase, usBase);

    int64_t audioUs = hasAudio ? [self currentAudioClockUs] : INT64_MIN;
    if (audioUs != INT64_MIN) {
      int64_t diff = ptsUs - audioUs;
      if (diff > 0 && diff < 1000000) {
        av_usleep((useconds_t)diff);
      }
    } else {
      if (*startPtsUs == AV_NOPTS_VALUE) {
        *startPtsUs = ptsUs;
        *startWallUs = av_gettime();
      } else {
        int64_t target = *startWallUs + (ptsUs - *startPtsUs);
        int64_t wait = target - av_gettime();
        if (wait > 0 && wait < 1000000) {
          av_usleep((useconds_t)wait);
        }
      }
    }
  } else {
    av_usleep(fallbackSleep > 0 ? fallbackSleep : 33333);
  }

  if (atomic_load(&_interrupt)) {
    return;
  }
  CVPixelBufferRef pb = [self makeNV12PixelBufferFromNV12Frame];
  if (!pb) {
    return;
  }
  [_lock lock];
  if (_latestBuf) {
    CVPixelBufferRelease(_latestBuf);
  }
  _latestBuf = pb;
  [_lock unlock];
}

- (void)videoDecodeLoop {
  BOOL hasAudio = (_audioStreamIndex >= 0 && _actx != NULL);
  AVRational usBase = {1, 1000000};
  int64_t startPtsUs = AV_NOPTS_VALUE;
  int64_t startWallUs = av_gettime();
  useconds_t fallbackSleep = (useconds_t)(_frameIntervalSec * 1e6);

  // 有音频时，先等真实音频开始出声再渲首帧，否则前奏静音那段视频会提前跑、声音追不上。
  if (hasAudio) {
    while (atomic_load(&_interrupt) == 0) {
      if ([self currentAudioClockUs] != INT64_MIN) {
        break;
      }
      usleep(5000);
    }
    startWallUs = av_gettime();
  }

  while (atomic_load(&_interrupt) == 0) {
    [self waitWhilePaused];
    if (atomic_load(&_interrupt)) {
      break;
    }

    AVPacket *pkt = NULL;
    BOOL eof = NO;
    if (!pq_pop(&_videoQ, &pkt, &eof)) {
      break;
    }

    if (eof) {
      avcodec_send_packet(_vctx, NULL);
      while (atomic_load(&_interrupt) == 0) {
        int r = avcodec_receive_frame(_vctx, _decoded);
        if (r == AVERROR_EOF || r == AVERROR(EAGAIN) || r < 0) {
          av_frame_unref(_decoded);
          break;
        }
        [self renderDecodedFrameSyncedHasAudio:hasAudio
                                        usBase:usBase
                                   startPtsUs:&startPtsUs
                                   startWallUs:&startWallUs
                                fallbackSleep:fallbackSleep];
        av_frame_unref(_decoded);
      }
      break;
    }

    int ret = avcodec_send_packet(_vctx, pkt);
    av_packet_free(&pkt);
    if (ret < 0 && ret != AVERROR(EAGAIN)) {
      continue;
    }
    while (atomic_load(&_interrupt) == 0) {
      int r = avcodec_receive_frame(_vctx, _decoded);
      if (r == AVERROR(EAGAIN) || r == AVERROR_EOF) {
        break;
      }
      if (r < 0) {
        break;
      }
      [self renderDecodedFrameSyncedHasAudio:hasAudio
                                      usBase:usBase
                                 startPtsUs:&startPtsUs
                                 startWallUs:&startWallUs
                              fallbackSleep:fallbackSleep];
      av_frame_unref(_decoded);
    }
  }
}

#pragma mark - 像素缓冲产出

- (nullable CVPixelBufferRef)makeNV12PixelBufferFromNV12Frame {
  int w = _nv12->width;
  int h = _nv12->height;
  NSDictionary *attrs = @{
    (NSString *)kCVPixelBufferIOSurfacePropertiesKey : @{},
    (NSString *)kCVPixelBufferMetalCompatibilityKey : @YES,
  };
  CVPixelBufferRef pb = NULL;
  CVReturn cr = CVPixelBufferCreate(kCFAllocatorDefault, w, h, kCVPixelFormatType_420YpCbCr8BiPlanarFullRange,
                                    (__bridge CFDictionaryRef)attrs, &pb);
  if (cr != kCVReturnSuccess || pb == NULL) {
    return NULL;
  }

  CVPixelBufferLockBaseAddress(pb, 0);
  uint8_t *yDst = (uint8_t *)CVPixelBufferGetBaseAddressOfPlane(pb, 0);
  uint8_t *uvDst = (uint8_t *)CVPixelBufferGetBaseAddressOfPlane(pb, 1);
  size_t yPitch = CVPixelBufferGetBytesPerRowOfPlane(pb, 0);
  size_t uvPitch = CVPixelBufferGetBytesPerRowOfPlane(pb, 1);

  const uint8_t *ySrc = _nv12->data[0];
  const uint8_t *uvSrc = _nv12->data[1];
  for (int row = 0; row < h; row++) {
    memcpy(yDst + row * yPitch, ySrc + row * _nv12->linesize[0], (size_t)w);
  }
  for (int row = 0; row < h / 2; row++) {
    memcpy(uvDst + row * uvPitch, uvSrc + row * _nv12->linesize[1], (size_t)w);
  }
  CVPixelBufferUnlockBaseAddress(pb, 0);
  return pb;
}

- (nullable CVPixelBufferRef)copyLatestPixelBuffer CF_RETURNS_RETAINED {
  [_lock lock];
  CVPixelBufferRef b = _latestBuf;
  if (b) {
    CVPixelBufferRetain(b);
  }
  [_lock unlock];
  return b;
}

@end
