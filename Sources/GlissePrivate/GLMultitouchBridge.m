//
//  GLMultitouchBridge.m
//  GlissePrivate
//
//  See GLMultitouchBridge.h for the rationale and the safety contract.
//

#import "GLMultitouchBridge.h"

#import <dlfcn.h>
#import <pthread.h>
#import <string.h>
#import <math.h>
#import <mach/mach_time.h>

// ---------------------------------------------------------------------------
// MARK: - Private framework function signatures
//
// Reconstructed signatures. Only the ones Glisse needs are declared; each is
// resolved with dlsym and individually optional unless marked required.
// ---------------------------------------------------------------------------

typedef void *MTDeviceRef;

// Required.
typedef CFMutableArrayRef (*MTDeviceCreateListFn)(void);
typedef void  (*MTRegisterContactFrameCallbackWithRefconFn)(MTDeviceRef, void *callback, void *refcon);
typedef void  (*MTUnregisterContactFrameCallbackFn)(MTDeviceRef, void *callback);
typedef void  (*MTDeviceStartFn)(MTDeviceRef, int runMode);
typedef void  (*MTDeviceStopFn)(MTDeviceRef);

// Optional.
typedef void  (*MTDeviceReleaseFn)(MTDeviceRef);
typedef bool  (*MTDeviceIsBuiltInFn)(MTDeviceRef);
typedef bool  (*MTDeviceIsOpaqueSurfaceFn)(MTDeviceRef);
typedef bool  (*MTDeviceIsRunningFn)(MTDeviceRef);
typedef bool  (*MTDeviceIsAliveFn)(MTDeviceRef);
typedef OSStatus (*MTDeviceGetDeviceIDFn)(MTDeviceRef, uint64_t *);
typedef OSStatus (*MTDeviceGetFamilyIDFn)(MTDeviceRef, int32_t *);
typedef OSStatus (*MTDeviceGetGUIDFn)(MTDeviceRef, uuid_t *);
typedef OSStatus (*MTDeviceGetSensorSurfaceDimensionsFn)(MTDeviceRef, int32_t *, int32_t *);
typedef OSStatus (*MTDeviceGetSensorDimensionsFn)(MTDeviceRef, int32_t *, int32_t *);
typedef OSStatus (*MTDeviceGetDriverTypeFn)(MTDeviceRef, int32_t *);

// The refcon-carrying contact frame callback. `touches` points to an array of
// `numTouches` MTTouch structures whose stride we determine at runtime.
typedef int (*GLMTContactFrameCallback)(MTDeviceRef device,
                                        void *touches,
                                        int32_t numTouches,
                                        double timestamp,
                                        int32_t frameNumber,
                                        void *refcon);

// ---------------------------------------------------------------------------
// MARK: - Symbol table
// ---------------------------------------------------------------------------

typedef struct GLMTSymbols {
    void *handle;
    MTDeviceCreateListFn createList;
    MTRegisterContactFrameCallbackWithRefconFn registerCallback;
    MTUnregisterContactFrameCallbackFn unregisterCallback;
    MTDeviceStartFn start;
    MTDeviceStopFn stop;
    MTDeviceReleaseFn release;
    MTDeviceIsBuiltInFn isBuiltIn;
    MTDeviceIsOpaqueSurfaceFn isOpaqueSurface;
    MTDeviceIsRunningFn isRunning;
    MTDeviceIsAliveFn isAlive;
    MTDeviceGetDeviceIDFn getDeviceID;
    MTDeviceGetFamilyIDFn getFamilyID;
    MTDeviceGetGUIDFn getGUID;
    MTDeviceGetSensorSurfaceDimensionsFn getSurfaceDimensions;
    MTDeviceGetSensorDimensionsFn getSensorDimensions;
    MTDeviceGetDriverTypeFn getDriverType;
    bool loaded;
    char failureReason[256];
} GLMTSymbols;

static GLMTSymbols gSym;
static pthread_once_t gSymOnce = PTHREAD_ONCE_INIT;

static void GLMTLoadSymbols(void) {
    memset(&gSym, 0, sizeof(gSym));

    static const char *kPath =
        "/System/Library/PrivateFrameworks/MultitouchSupport.framework/MultitouchSupport";

    gSym.handle = dlopen(kPath, RTLD_LAZY | RTLD_LOCAL);
    if (gSym.handle == NULL) {
        snprintf(gSym.failureReason, sizeof(gSym.failureReason),
                 "dlopen failed: %s", dlerror() ?: "unknown");
        return;
    }

#define ES_SYM(field, name) gSym.field = (__typeof__(gSym.field))dlsym(gSym.handle, name)

    ES_SYM(createList,           "MTDeviceCreateList");
    ES_SYM(registerCallback,     "MTRegisterContactFrameCallbackWithRefcon");
    ES_SYM(unregisterCallback,   "MTUnregisterContactFrameCallback");
    ES_SYM(start,                "MTDeviceStart");
    ES_SYM(stop,                 "MTDeviceStop");
    ES_SYM(release,              "MTDeviceRelease");
    ES_SYM(isBuiltIn,            "MTDeviceIsBuiltIn");
    ES_SYM(isOpaqueSurface,      "MTDeviceIsOpaqueSurface");
    ES_SYM(isRunning,            "MTDeviceIsRunning");
    ES_SYM(isAlive,              "MTDeviceIsAlive");
    ES_SYM(getDeviceID,          "MTDeviceGetDeviceID");
    ES_SYM(getFamilyID,          "MTDeviceGetFamilyID");
    ES_SYM(getGUID,              "MTDeviceGetGUID");
    ES_SYM(getSurfaceDimensions, "MTDeviceGetSensorSurfaceDimensions");
    ES_SYM(getSensorDimensions,  "MTDeviceGetSensorDimensions");
    ES_SYM(getDriverType,        "MTDeviceGetDriverType");

#undef ES_SYM

    if (gSym.createList == NULL || gSym.registerCallback == NULL ||
        gSym.start == NULL || gSym.stop == NULL) {
        snprintf(gSym.failureReason, sizeof(gSym.failureReason),
                 "required symbols missing (createList=%d register=%d start=%d stop=%d)",
                 gSym.createList != NULL, gSym.registerCallback != NULL,
                 gSym.start != NULL, gSym.stop != NULL);
        return;
    }

    gSym.loaded = true;
}

static const GLMTSymbols *GLMTSymbolsShared(void) {
    pthread_once(&gSymOnce, GLMTLoadSymbols);
    return &gSym;
}

// ---------------------------------------------------------------------------
// MARK: - MTTouch byte-layout handling
//
// The canonical layout below matches every publicly documented reconstruction
// of MTTouch and is what the framework has used on Intel and Apple Silicon:
//
//   off  type      field
//   0    int32     frame
//   8    double    timestamp
//   16   int32     pathIndex        (contact identifier)
//   20   int32     state
//   24   int32     fingerID
//   28   int32     handID
//   32   float[4]  normalized {pos.x, pos.y, vel.x, vel.y}
//   48   float     zTotal (size)
//   52   int32     ---
//   56   float     angle
//   60   float     majorAxis
//   64   float     minorAxis
//   68   float[4]  absolute {pos.x, pos.y, vel.x, vel.y}  (millimetres)
//   84   int32     ---
//   88   int32     ---
//   92   float     zDensity
//   ---> stride 96
//
// Rather than trust it blindly the bridge scores it against real frames and,
// if it does not hold, searches a bounded space of alternatives. Failing that
// it reports layout failure and the app falls back to the public NSTouch path.
// ---------------------------------------------------------------------------

static const int32_t kESCanonicalStride = 96;

static GLMTLayout GLMTCanonicalLayout(void) {
    GLMTLayout l;
    l.stride           = kESCanonicalStride;
    l.offsetTimestamp  = 8;
    l.offsetIdentifier = 16;
    l.offsetState      = 20;
    l.offsetFingerID   = 24;
    l.offsetHandID     = 28;
    l.offsetPosition   = 32;
    l.offsetSize       = 48;
    l.offsetAngle      = 56;
    l.origin           = GLMTLayoutOriginAssumed;
    l.confirmations    = 0;
    return l;
}

static inline float GLReadFloat(const void *base, int32_t offset) {
    float v;
    memcpy(&v, (const uint8_t *)base + offset, sizeof(v));
    return v;
}

static inline double GLReadDouble(const void *base, int32_t offset) {
    double v;
    memcpy(&v, (const uint8_t *)base + offset, sizeof(v));
    return v;
}

static inline int32_t GLReadInt32(const void *base, int32_t offset) {
    int32_t v;
    memcpy(&v, (const uint8_t *)base + offset, sizeof(v));
    return v;
}

/// Plausibility test for one contact under a candidate layout.
static bool GLMTTouchLooksSane(const void *touchBase,
                               const GLMTLayout *layout,
                               double frameTimestamp) {
    int32_t state = GLReadInt32(touchBase, layout->offsetState);
    if (state < 0 || state > 8) return false;

    int32_t identifier = GLReadInt32(touchBase, layout->offsetIdentifier);
    if (identifier < 0 || identifier > 128) return false;

    float x = GLReadFloat(touchBase, layout->offsetPosition);
    float y = GLReadFloat(touchBase, layout->offsetPosition + 4);
    if (!isfinite(x) || !isfinite(y)) return false;
    // Contacts can sit a hair outside the reported surface.
    if (x < -0.15f || x > 1.15f) return false;
    if (y < -0.15f || y > 1.15f) return false;

    float size = GLReadFloat(touchBase, layout->offsetSize);
    if (!isfinite(size) || size < 0.0f || size > 1000.0f) return false;

    double ts = GLReadDouble(touchBase, layout->offsetTimestamp);
    if (!isfinite(ts)) return false;
    // MT stamps each contact with the frame time; allow generous slack.
    if (frameTimestamp > 0.0 && fabs(ts - frameTimestamp) > 2.0) return false;

    return true;
}

/// Scores a layout over a whole frame. Returns the number of sane contacts,
/// or -1 if any contact fails.
static int GLMTScoreLayout(const void *frame,
                           int32_t count,
                           const GLMTLayout *layout,
                           double frameTimestamp) {
    for (int32_t i = 0; i < count; i++) {
        const void *touch = (const uint8_t *)frame + (size_t)i * (size_t)layout->stride;
        if (!GLMTTouchLooksSane(touch, layout, frameTimestamp)) return -1;
    }
    return count;
}

static const int32_t kESCandidateStrides[] = { 96, 100, 104, 108, 112, 116, 120, 128, 136, 144, 152, 160 };
static const size_t  kESCandidateStrideCount =
    sizeof(kESCandidateStrides) / sizeof(kESCandidateStrides[0]);

// ---------------------------------------------------------------------------
// MARK: - Device wrapper
// ---------------------------------------------------------------------------

@interface GLMultitouchDeviceInfo ()
@property (nonatomic, copy) NSString *key;
@property (nonatomic, copy) NSString *displayName;
@property (nonatomic) BOOL isBuiltIn;
@property (nonatomic) BOOL isOpaqueSurface;
@property (nonatomic) uint64_t deviceID;
@property (nonatomic) int32_t familyID;
@property (nonatomic) int32_t surfaceWidth;
@property (nonatomic) int32_t surfaceHeight;
@property (nonatomic) int32_t sensorColumns;
@property (nonatomic) int32_t sensorRows;
@end

@implementation GLMultitouchDeviceInfo
- (NSString *)description {
    return [NSString stringWithFormat:
            @"<GLMultitouchDeviceInfo %@ builtIn=%d id=0x%llx family=%d surface=%dx%d sensor=%dx%d>",
            self.key, self.isBuiltIn, (unsigned long long)self.deviceID, self.familyID,
            self.surfaceWidth, self.surfaceHeight, self.sensorColumns, self.sensorRows];
}
@end

/// One registered device: the opaque ref plus its identity.
///
/// Ownership note: `ref` is *not* individually retained. `MTDeviceCreateList`
/// hands back a CFArray that owns its elements, so the bridge keeps that array
/// alive for as long as any device is registered and releases it in `stop`.
/// This avoids guessing whether `MTDeviceRelease` is CFRelease-equivalent —
/// getting that wrong is a double-free.
typedef struct GLMTRegisteredDevice {
    MTDeviceRef ref;
    CFStringRef key;      // retained
    bool started;
} GLMTRegisteredDevice;

// ---------------------------------------------------------------------------
// MARK: - Bridge
// ---------------------------------------------------------------------------

@implementation GLMultitouchBridge {
    // Guards everything below. The frame callback takes it only briefly and
    // never allocates while held.
    pthread_mutex_t _lock;

    GLMTRegisteredDevice *_registered;
    NSInteger _registeredCount;
    NSInteger _registeredCapacity;

    /// Owns the MTDeviceRefs. Released only in `stop`.
    CFMutableArrayRef _deviceList;

    NSArray<GLMultitouchDeviceInfo *> *_devices;
    BOOL _running;

    GLMTLayout _layout;
    int32_t _layoutRejections;
    int32_t _framesSeen;
    BOOL _layoutFailureReported;

    // Scratch buffer reused by the callback so no allocation happens on the
    // multitouch thread.
    GLRawTouch *_scratch;
    NSInteger _scratchCapacity;

    uint8_t _lastFrameBytes[160];
    NSInteger _lastFrameByteCount;
    int32_t _lastFrameTouchCount;
}

// MARK: Availability

+ (BOOL)isFrameworkAvailable {
    return GLMTSymbolsShared()->loaded;
}

+ (NSString *)unavailableReason {
    const GLMTSymbols *s = GLMTSymbolsShared();
    if (s->loaded) return @"";
    return [NSString stringWithUTF8String:s->failureReason];
}

// MARK: Lifecycle

- (instancetype)init {
    self = [super init];
    if (self) {
        pthread_mutexattr_t attr;
        pthread_mutexattr_init(&attr);
        pthread_mutexattr_settype(&attr, PTHREAD_MUTEX_RECURSIVE);
        pthread_mutex_init(&_lock, &attr);
        pthread_mutexattr_destroy(&attr);

        _devices = @[];
        _layout = GLMTCanonicalLayout();
        _scratchCapacity = 32;
        _scratch = calloc((size_t)_scratchCapacity, sizeof(GLRawTouch));
        _registeredCapacity = 8;
        _registered = calloc((size_t)_registeredCapacity, sizeof(GLMTRegisteredDevice));
    }
    return self;
}

- (void)dealloc {
    [self stop];
    free(_scratch);
    free(_registered);
    pthread_mutex_destroy(&_lock);
}

// MARK: Public state

- (NSArray<GLMultitouchDeviceInfo *> *)devices {
    pthread_mutex_lock(&_lock);
    NSArray *copy = [_devices copy];
    pthread_mutex_unlock(&_lock);
    return copy;
}

- (BOOL)isRunning {
    pthread_mutex_lock(&_lock);
    BOOL r = _running;
    pthread_mutex_unlock(&_lock);
    return r;
}

- (GLMTLayout)currentLayout {
    pthread_mutex_lock(&_lock);
    GLMTLayout l = _layout;
    pthread_mutex_unlock(&_lock);
    return l;
}

// MARK: Start / stop

static int GLMTFrameCallbackTrampoline(MTDeviceRef device,
                                       void *touches,
                                       int32_t numTouches,
                                       double timestamp,
                                       int32_t frameNumber,
                                       void *refcon);

- (BOOL)startAndReturnError:(NSError **)error {
    const GLMTSymbols *s = GLMTSymbolsShared();
    if (!s->loaded) {
        if (error) {
            *error = [NSError errorWithDomain:@"xyz.glisse.multitouch"
                                         code:1
                                     userInfo:@{NSLocalizedDescriptionKey:
                                                    [NSString stringWithUTF8String:s->failureReason]}];
        }
        return NO;
    }

    pthread_mutex_lock(&_lock);

    if (_running) {
        pthread_mutex_unlock(&_lock);
        return YES;
    }

    BOOL ok = [self ES_enumerateAndRegisterLocked];
    _running = ok && _registeredCount > 0;
    NSInteger count = _registeredCount;

    pthread_mutex_unlock(&_lock);

    if (!_running && error) {
        *error = [NSError errorWithDomain:@"xyz.glisse.multitouch"
                                     code:2
                                 userInfo:@{NSLocalizedDescriptionKey:
                                                count == 0
                                                    ? @"No multitouch devices were reported by MultitouchSupport."
                                                    : @"Failed to start multitouch devices."}];
    }
    return _running;
}

- (void)stop {
    const GLMTSymbols *s = GLMTSymbolsShared();

    pthread_mutex_lock(&_lock);
    for (NSInteger i = 0; i < _registeredCount; i++) {
        GLMTRegisteredDevice *d = &_registered[i];
        if (d->ref == NULL) continue;
        if (d->started && s->stop) {
            s->stop(d->ref);
        }
        if (s->unregisterCallback) {
            s->unregisterCallback(d->ref, (void *)GLMTFrameCallbackTrampoline);
        }
        if (d->key) {
            CFRelease(d->key);
            d->key = NULL;
        }
        d->ref = NULL;
        d->started = false;
    }
    _registeredCount = 0;
    if (_deviceList != NULL) {
        CFRelease(_deviceList);
        _deviceList = NULL;
    }
    _running = NO;
    _devices = @[];
    pthread_mutex_unlock(&_lock);
}

- (BOOL)restartAndReturnError:(NSError **)error {
    [self stop];
    // MultitouchSupport occasionally needs a beat after wake before it will
    // hand out fresh device references.
    pthread_mutex_lock(&_lock);
    _layoutFailureReported = NO;
    _layoutRejections = 0;
    pthread_mutex_unlock(&_lock);
    return [self startAndReturnError:error];
}

// MARK: Enumeration (lock held)

- (BOOL)ES_enumerateAndRegisterLocked {
    const GLMTSymbols *s = GLMTSymbolsShared();
    if (!s->loaded) return NO;

    if (_deviceList != NULL) {
        CFRelease(_deviceList);
        _deviceList = NULL;
    }

    CFMutableArrayRef list = s->createList();
    if (list == NULL) return NO;
    _deviceList = list;   // retained until stop; owns the device refs

    NSMutableArray<GLMultitouchDeviceInfo *> *infos = [NSMutableArray array];
    CFIndex n = CFArrayGetCount(list);

    for (CFIndex i = 0; i < n; i++) {
        MTDeviceRef dev = (MTDeviceRef)CFArrayGetValueAtIndex(list, i);
        if (dev == NULL) continue;

        // Note: MTDeviceIsAlive is deliberately NOT used as a filter here.
        // Measured on macOS 27.0 / M2 Pro: it reports false for the built-in
        // trackpad until after MTDeviceStart, so filtering on it discards every
        // device and the app silently falls back to the public touch source.
        GLMultitouchDeviceInfo *info = [self ES_infoForDevice:dev];
        if (info == nil) continue;

        if (_registeredCount >= _registeredCapacity) {
            NSInteger newCap = _registeredCapacity * 2;
            GLMTRegisteredDevice *grown =
                realloc(_registered, (size_t)newCap * sizeof(GLMTRegisteredDevice));
            if (grown == NULL) break;
            memset(grown + _registeredCapacity, 0,
                   (size_t)(newCap - _registeredCapacity) * sizeof(GLMTRegisteredDevice));
            _registered = grown;
            _registeredCapacity = newCap;
        }

        GLMTRegisteredDevice *slot = &_registered[_registeredCount];
        slot->ref = dev;
        slot->key = (CFStringRef)CFBridgingRetain(info.key);
        slot->started = false;

        // Unretained refcon: the bridge outlives its registrations because
        // -stop unregisters in -dealloc.
        s->registerCallback(dev, (void *)GLMTFrameCallbackTrampoline, (__bridge void *)self);
        s->start(dev, 0);
        slot->started = (s->isRunning == NULL) || s->isRunning(dev);
        // Some devices report not-running immediately after start; treat the
        // registration as live regardless so stop() still tears it down.
        slot->started = true;

        _registeredCount += 1;
        [infos addObject:info];
    }

    _devices = [infos copy];
    return infos.count > 0;
}

- (GLMultitouchDeviceInfo *)ES_infoForDevice:(MTDeviceRef)dev {
    const GLMTSymbols *s = GLMTSymbolsShared();

    GLMultitouchDeviceInfo *info = [[GLMultitouchDeviceInfo alloc] init];

    uint64_t deviceID = 0;
    if (s->getDeviceID) { s->getDeviceID(dev, &deviceID); }
    info.deviceID = deviceID;

    int32_t familyID = 0;
    if (s->getFamilyID) { s->getFamilyID(dev, &familyID); }
    info.familyID = familyID;

    info.isBuiltIn = s->isBuiltIn ? s->isBuiltIn(dev) : NO;
    info.isOpaqueSurface = s->isOpaqueSurface ? s->isOpaqueSurface(dev) : NO;

    int32_t w = 0, h = 0;
    if (s->getSurfaceDimensions) { s->getSurfaceDimensions(dev, &w, &h); }
    info.surfaceWidth = w;
    info.surfaceHeight = h;

    int32_t cols = 0, rows = 0;
    if (s->getSensorDimensions) { s->getSensorDimensions(dev, &rows, &cols); }
    info.sensorRows = rows;
    info.sensorColumns = cols;

    // Session key preference: device ID, then GUID, then the pointer.
    //
    // The device ID is used first because MTDeviceGetGUID does not return a real
    // UUID on this hardware — measured on macOS 27.0 / M2 Pro it returns the
    // device ID in the first byte and zeroes for the rest, which would produce
    // near-identical keys for different devices. The device ID is stable across
    // sleep/wake and replug, which is what the gesture session needs.
    NSString *key = nil;
    if (deviceID != 0) {
        key = [NSString stringWithFormat:@"mt-%llx", (unsigned long long)deviceID];
    }
    if (key == nil && s->getGUID) {
        uuid_t guid;
        memset(&guid, 0, sizeof(guid));
        if (s->getGUID(dev, &guid) == 0) {
            uuid_string_t str;
            uuid_unparse_upper(guid, str);
            NSString *candidate = [NSString stringWithUTF8String:str];
            if (candidate.length > 0 &&
                ![candidate isEqualToString:@"00000000-0000-0000-0000-000000000000"]) {
                key = candidate;
            }
        }
    }
    if (key == nil) {
        key = [NSString stringWithFormat:@"mt-ptr-%p", dev];
    }
    info.key = key;

    // Family IDs are not documented; the built-in flag is the reliable signal.
    info.displayName = info.isBuiltIn ? @"Built-in Trackpad"
                                      : (familyID >= 112 ? @"Magic Trackpad" : @"External Trackpad");
    return info;
}

// MARK: Frame handling

- (void)ES_handleFrameFromDevice:(MTDeviceRef)device
                         touches:(void *)touches
                      touchCount:(int32_t)numTouches
                       timestamp:(double)timestamp
                     frameNumber:(int32_t)frameNumber {
    if (numTouches < 0) return;
    if (numTouches > 32) numTouches = 32;

    GLMultitouchFrameHandler handler = self.frameHandler;

    NSString *deviceKey = nil;
    GLRawTouch *out = NULL;
    NSInteger produced = 0;
    BOOL reportFailure = NO;

    pthread_mutex_lock(&_lock);

    _framesSeen += 1;

    // Remember the bytes for diagnostics before doing anything else.
    if (touches != NULL && numTouches > 0) {
        size_t avail = (size_t)numTouches * (size_t)MAX(_layout.stride, kESCanonicalStride);
        size_t copyLen = MIN(avail, sizeof(_lastFrameBytes));
        memcpy(_lastFrameBytes, touches, copyLen);
        _lastFrameByteCount = (NSInteger)copyLen;
        _lastFrameTouchCount = numTouches;
    }

    // Resolve the device key.
    for (NSInteger i = 0; i < _registeredCount; i++) {
        if (_registered[i].ref == device) {
            deviceKey = (__bridge NSString *)_registered[i].key;
            break;
        }
    }
    if (deviceKey == nil) {
        // A frame from a device we do not know about (can happen briefly during
        // a restart). Drop it rather than guess.
        pthread_mutex_unlock(&_lock);
        return;
    }

    if (touches != NULL && numTouches > 0) {
        [self ES_maintainLayoutLocked:touches count:numTouches timestamp:timestamp];

        if (_layout.origin == GLMTLayoutOriginFailed) {
            reportFailure = !_layoutFailureReported;
            _layoutFailureReported = YES;
            pthread_mutex_unlock(&_lock);
            if (reportFailure) {
                void (^cb)(void) = self.layoutFailureHandler;
                if (cb) cb();
            }
            return;
        }

        if (_scratchCapacity < numTouches) {
            GLRawTouch *grown = realloc(_scratch, (size_t)numTouches * sizeof(GLRawTouch));
            if (grown != NULL) {
                _scratch = grown;
                _scratchCapacity = numTouches;
            }
        }

        NSInteger cap = MIN((NSInteger)numTouches, _scratchCapacity);
        for (NSInteger i = 0; i < cap; i++) {
            const void *tb = (const uint8_t *)touches + (size_t)i * (size_t)_layout.stride;

            float x  = GLReadFloat(tb, _layout.offsetPosition);
            float y  = GLReadFloat(tb, _layout.offsetPosition + 4);
            float vx = GLReadFloat(tb, _layout.offsetPosition + 8);
            float vy = GLReadFloat(tb, _layout.offsetPosition + 12);

            if (!isfinite(x) || !isfinite(y)) continue;
            if (!isfinite(vx)) vx = 0.0f;
            if (!isfinite(vy)) vy = 0.0f;

            GLRawTouch *t = &_scratch[produced];
            t->identifier = GLReadInt32(tb, _layout.offsetIdentifier);
            t->fingerID   = GLReadInt32(tb, _layout.offsetFingerID);
            t->handID     = GLReadInt32(tb, _layout.offsetHandID);
            t->state      = GLReadInt32(tb, _layout.offsetState);

            // Clamp: a contact right on the bezel can read slightly out of range
            // and every downstream consumer assumes 0...1.
            t->x = fmin(fmax((double)x, 0.0), 1.0);
            t->y = fmin(fmax((double)y, 0.0), 1.0);
            t->velocityX = (double)vx;
            t->velocityY = (double)vy;

            float size = GLReadFloat(tb, _layout.offsetSize);
            t->pressure  = isfinite(size) ? (double)size : 0.0;

            float angle = GLReadFloat(tb, _layout.offsetAngle);
            float major = GLReadFloat(tb, _layout.offsetAngle + 4);
            float minor = GLReadFloat(tb, _layout.offsetAngle + 8);
            t->angle     = isfinite(angle) ? (double)angle : 0.0;
            t->majorAxis = isfinite(major) ? (double)major : 0.0;
            t->minorAxis = isfinite(minor) ? (double)minor : 0.0;

            double ts = GLReadDouble(tb, _layout.offsetTimestamp);
            t->timestamp = isfinite(ts) ? ts : timestamp;

            produced += 1;
        }
        out = _scratch;
    }

    pthread_mutex_unlock(&_lock);

    if (handler) {
        handler(deviceKey, frameNumber, timestamp, produced > 0 ? out : NULL, produced);
    }
}

/// Validates, and if necessary re-derives, the byte layout. Lock held.
- (void)ES_maintainLayoutLocked:(const void *)frame
                          count:(int32_t)count
                      timestamp:(double)timestamp {
    if (_layout.origin == GLMTLayoutOriginFailed) return;

    // A single contact cannot disambiguate stride, but it can still invalidate
    // the field offsets.
    bool currentOK = GLMTScoreLayout(frame, count, &_layout, timestamp) >= 0;

    if (currentOK) {
        if (count >= 2 && _layout.origin == GLMTLayoutOriginAssumed) {
            // Two or more contacts parsed cleanly at this stride: that is real
            // corroboration, because a wrong stride would misalign contact 2+.
            _layout.confirmations += 1;
            if (_layout.confirmations >= 3) {
                _layout.origin = GLMTLayoutOriginValidated;
            }
        }
        _layoutRejections = 0;
        return;
    }

    _layoutRejections += 1;

    // Transient garbage happens; only re-derive after repeated failures.
    if (_layoutRejections < 8) return;

    GLMTLayout recovered;
    if ([self ES_searchLayout:frame count:count timestamp:timestamp into:&recovered]) {
        recovered.origin = GLMTLayoutOriginRecovered;
        recovered.confirmations = 0;
        _layout = recovered;
        _layoutRejections = 0;
        return;
    }

    if (_layoutRejections >= 40) {
        _layout.origin = GLMTLayoutOriginFailed;
    }
}

/// Bounded search over stride x position-offset. Lock held.
- (BOOL)ES_searchLayout:(const void *)frame
                  count:(int32_t)count
              timestamp:(double)timestamp
                   into:(GLMTLayout *)outLayout {
    if (count < 1) return NO;

    // Discover the timestamp offset first: it is the one field whose value we
    // already know, which anchors everything else.
    int32_t tsOffset = -1;
    for (int32_t off = 0; off <= 32; off += 4) {
        double v = GLReadDouble(frame, off);
        if (isfinite(v) && fabs(v - timestamp) < 0.5) { tsOffset = off; break; }
    }
    if (tsOffset < 0) return NO;

    GLMTLayout best = GLMTCanonicalLayout();
    int bestScore = -1;
    bool found = false;

    for (size_t si = 0; si < kESCandidateStrideCount; si++) {
        int32_t stride = kESCandidateStrides[si];

        for (int32_t posOff = tsOffset + 8; posOff + 16 <= stride; posOff += 4) {
            GLMTLayout candidate = GLMTCanonicalLayout();
            candidate.stride = stride;
            candidate.offsetTimestamp = tsOffset;
            candidate.offsetIdentifier = tsOffset + 8;
            candidate.offsetState = tsOffset + 12;
            candidate.offsetFingerID = tsOffset + 16;
            candidate.offsetHandID = tsOffset + 20;
            candidate.offsetPosition = posOff;
            candidate.offsetSize = posOff + 16;
            candidate.offsetAngle = posOff + 24;

            if (candidate.offsetAngle + 12 > stride) continue;

            int score = GLMTScoreLayout(frame, count, &candidate, timestamp);
            if (score > bestScore) {
                bestScore = score;
                best = candidate;
                found = true;
            }
        }
    }

    if (found && bestScore >= count) {
        *outLayout = best;
        return YES;
    }
    return NO;
}

static int GLMTFrameCallbackTrampoline(MTDeviceRef device,
                                       void *touches,
                                       int32_t numTouches,
                                       double timestamp,
                                       int32_t frameNumber,
                                       void *refcon) {
    GLMultitouchBridge *bridge = (__bridge GLMultitouchBridge *)refcon;
    if (bridge != nil) {
        @autoreleasepool {
            [bridge ES_handleFrameFromDevice:device
                                     touches:touches
                                  touchCount:numTouches
                                   timestamp:timestamp
                                 frameNumber:frameNumber];
        }
    }
    return 0;
}

// MARK: Diagnostics

- (NSString *)diagnosticsDescription {
    const GLMTSymbols *s = GLMTSymbolsShared();
    NSMutableString *out = [NSMutableString string];

    [out appendString:@"MultitouchSupport bridge\n"];
    [out appendFormat:@"  framework loaded : %@\n", s->loaded ? @"yes" : @"no"];
    if (!s->loaded) {
        [out appendFormat:@"  reason           : %s\n", s->failureReason];
        return out;
    }

    [out appendFormat:@"  optional symbols : release=%d isBuiltIn=%d guid=%d surfaceDims=%d sensorDims=%d isAlive=%d\n",
     s->release != NULL, s->isBuiltIn != NULL, s->getGUID != NULL,
     s->getSurfaceDimensions != NULL, s->getSensorDimensions != NULL, s->isAlive != NULL];

    pthread_mutex_lock(&_lock);
    GLMTLayout l = _layout;
    NSArray *devs = [_devices copy];
    int32_t frames = _framesSeen;
    int32_t rejections = _layoutRejections;
    pthread_mutex_unlock(&_lock);

    static const char *originNames[] = { "assumed", "validated", "recovered", "FAILED" };
    int oi = (l.origin >= 0 && l.origin <= 3) ? l.origin : 0;

    [out appendFormat:@"  frames seen      : %d (layout rejections: %d)\n", frames, rejections];
    [out appendFormat:@"  MTTouch layout   : %s, stride=%d\n", originNames[oi], l.stride];
    [out appendFormat:@"    offsets        : ts=%d id=%d state=%d finger=%d hand=%d pos=%d size=%d angle=%d\n",
     l.offsetTimestamp, l.offsetIdentifier, l.offsetState, l.offsetFingerID,
     l.offsetHandID, l.offsetPosition, l.offsetSize, l.offsetAngle];
    [out appendFormat:@"  devices          : %lu\n", (unsigned long)devs.count];
    for (GLMultitouchDeviceInfo *d in devs) {
        [out appendFormat:@"    - %@ [%@] builtIn=%@ id=0x%llx family=%d surface=%d x %d (1/100 mm) sensor=%d x %d\n",
         d.displayName, d.key, d.isBuiltIn ? @"yes" : @"no",
         (unsigned long long)d.deviceID, d.familyID,
         d.surfaceWidth, d.surfaceHeight, d.sensorColumns, d.sensorRows];
    }
    return out;
}

- (NSString *)lastFrameHexDump {
    pthread_mutex_lock(&_lock);
    NSInteger n = _lastFrameByteCount;
    int32_t touches = _lastFrameTouchCount;
    uint8_t bytes[160];
    memcpy(bytes, _lastFrameBytes, sizeof(bytes));
    pthread_mutex_unlock(&_lock);

    if (n == 0) return @"";

    NSMutableString *out = [NSMutableString string];
    [out appendFormat:@"last frame: %d contact(s), %ld bytes captured\n", touches, (long)n];
    for (NSInteger row = 0; row < n; row += 16) {
        [out appendFormat:@"  %04ld  ", (long)row];
        for (NSInteger c = 0; c < 16 && row + c < n; c++) {
            [out appendFormat:@"%02x ", bytes[row + c]];
        }
        [out appendString:@"\n"];
    }
    return out;
}

@end
