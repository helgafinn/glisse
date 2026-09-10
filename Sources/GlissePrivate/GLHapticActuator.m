//
//  GLHapticActuator.m
//  GlissePrivate
//

#import "GLHapticActuator.h"

#import <dlfcn.h>
#import <pthread.h>
#import <string.h>
#import <IOKit/IOKitLib.h>

typedef CFTypeRef MTActuatorRef;

typedef MTActuatorRef (*MTActuatorCreateFromDeviceIDFn)(uint64_t deviceID);
typedef IOReturn (*MTActuatorOpenFn)(MTActuatorRef);
typedef IOReturn (*MTActuatorCloseFn)(MTActuatorRef);
typedef bool     (*MTActuatorIsOpenFn)(MTActuatorRef);
typedef IOReturn (*MTActuatorActuateFn)(MTActuatorRef, int32_t actuationID,
                                        uint32_t unknown1, float unknown2, float unknown3);

typedef struct GLActuatorSymbols {
    void *handle;
    MTActuatorCreateFromDeviceIDFn create;
    MTActuatorOpenFn open;
    MTActuatorCloseFn close;
    MTActuatorIsOpenFn isOpen;
    MTActuatorActuateFn actuate;
    bool available;
    char failure[200];
} GLActuatorSymbols;

static GLActuatorSymbols gAct;
static pthread_once_t gActOnce = PTHREAD_ONCE_INIT;

static void GLActuatorLoad(void) {
    memset(&gAct, 0, sizeof(gAct));

    gAct.handle = dlopen(
        "/System/Library/PrivateFrameworks/MultitouchSupport.framework/MultitouchSupport",
        RTLD_LAZY | RTLD_LOCAL);
    if (gAct.handle == NULL) {
        snprintf(gAct.failure, sizeof(gAct.failure), "dlopen failed: %s", dlerror() ?: "unknown");
        return;
    }

    gAct.create  = (MTActuatorCreateFromDeviceIDFn)dlsym(gAct.handle, "MTActuatorCreateFromDeviceID");
    gAct.open    = (MTActuatorOpenFn)dlsym(gAct.handle, "MTActuatorOpen");
    gAct.close   = (MTActuatorCloseFn)dlsym(gAct.handle, "MTActuatorClose");
    gAct.isOpen  = (MTActuatorIsOpenFn)dlsym(gAct.handle, "MTActuatorIsOpen");
    gAct.actuate = (MTActuatorActuateFn)dlsym(gAct.handle, "MTActuatorActuate");

    gAct.available = (gAct.create != NULL && gAct.open != NULL && gAct.actuate != NULL);
    if (!gAct.available) {
        snprintf(gAct.failure, sizeof(gAct.failure),
                 "symbols missing (create=%d open=%d actuate=%d)",
                 gAct.create != NULL, gAct.open != NULL, gAct.actuate != NULL);
    }
}

static const GLActuatorSymbols *GLActuatorSymbolsShared(void) {
    pthread_once(&gActOnce, GLActuatorLoad);
    return &gAct;
}

@implementation GLHapticActuator {
    pthread_mutex_t _lock;
    MTActuatorRef _actuator;
    uint64_t _deviceID;
    BOOL _open;
    int32_t _consecutiveFailures;
}

+ (BOOL)isFrameworkAvailable {
    return GLActuatorSymbolsShared()->available;
}

+ (NSArray<NSNumber *> *)allPatterns {
    return @[ @(GLActuationPatternWeak), @(GLActuationPatternLight),
              @(GLActuationPatternMedium), @(GLActuationPatternFirm),
              @(GLActuationPatternStrong), @(GLActuationPatternStrongest),
              @(GLActuationPatternAlt1), @(GLActuationPatternAlt2) ];
}

- (instancetype)init {
    self = [super init];
    if (self) {
        pthread_mutexattr_t attr;
        pthread_mutexattr_init(&attr);
        pthread_mutexattr_settype(&attr, PTHREAD_MUTEX_RECURSIVE);
        pthread_mutex_init(&_lock, &attr);
        pthread_mutexattr_destroy(&attr);
    }
    return self;
}

- (void)dealloc {
    [self invalidate];
    pthread_mutex_destroy(&_lock);
}

- (BOOL)isReady {
    pthread_mutex_lock(&_lock);
    BOOL ready = (_actuator != NULL) && _open;
    pthread_mutex_unlock(&_lock);
    return ready;
}

- (BOOL)prepareForDeviceID:(uint64_t)deviceID {
    const GLActuatorSymbols *s = GLActuatorSymbolsShared();
    if (!s->available) return NO;
    if (deviceID == 0) return NO;

    pthread_mutex_lock(&_lock);

    if (_actuator != NULL && _deviceID == deviceID && _open) {
        pthread_mutex_unlock(&_lock);
        return YES;
    }

    [self ES_teardownLocked];

    MTActuatorRef created = s->create(deviceID);
    if (created == NULL) {
        pthread_mutex_unlock(&_lock);
        return NO;
    }

    IOReturn result = s->open(created);
    if (result != kIOReturnSuccess) {
        CFRelease(created);
        pthread_mutex_unlock(&_lock);
        return NO;
    }

    _actuator = created;
    _deviceID = deviceID;
    _open = YES;
    _consecutiveFailures = 0;

    pthread_mutex_unlock(&_lock);
    return YES;
}

- (BOOL)actuate:(GLActuationPattern)pattern {
    const GLActuatorSymbols *s = GLActuatorSymbolsShared();
    if (!s->available) return NO;

    pthread_mutex_lock(&_lock);

    if (_actuator == NULL || !_open) {
        pthread_mutex_unlock(&_lock);
        return NO;
    }

    // The framework can quietly close the actuator across a sleep; re-open
    // rather than silently going numb.
    if (s->isOpen != NULL && !s->isOpen(_actuator)) {
        if (s->open(_actuator) != kIOReturnSuccess) {
            _open = NO;
            pthread_mutex_unlock(&_lock);
            return NO;
        }
    }

    IOReturn result = s->actuate(_actuator, (int32_t)pattern, 0, 0.0f, 0.0f);

    if (result == kIOReturnSuccess) {
        _consecutiveFailures = 0;
    } else {
        _consecutiveFailures += 1;
        // Stop trying after a run of failures; the caller falls back to AppKit.
        if (_consecutiveFailures >= 5) {
            [self ES_teardownLocked];
        }
    }

    pthread_mutex_unlock(&_lock);
    return result == kIOReturnSuccess;
}

- (void)invalidate {
    pthread_mutex_lock(&_lock);
    [self ES_teardownLocked];
    pthread_mutex_unlock(&_lock);
}

/// Lock held.
- (void)ES_teardownLocked {
    const GLActuatorSymbols *s = GLActuatorSymbolsShared();
    if (_actuator != NULL) {
        if (_open && s->close != NULL) {
            s->close(_actuator);
        }
        CFRelease(_actuator);
        _actuator = NULL;
    }
    _open = NO;
    _deviceID = 0;
    _consecutiveFailures = 0;
}

- (NSString *)diagnosticsDescription {
    const GLActuatorSymbols *s = GLActuatorSymbolsShared();

    pthread_mutex_lock(&_lock);
    uint64_t deviceID = _deviceID;
    BOOL open = _open;
    BOOL created = _actuator != NULL;
    int32_t failures = _consecutiveFailures;
    pthread_mutex_unlock(&_lock);

    NSMutableString *out = [NSMutableString string];
    [out appendString:@"Haptic actuator (MTActuator)\n"];
    [out appendFormat:@"  symbols          : create=%d open=%d close=%d isOpen=%d actuate=%d\n",
     s->create != NULL, s->open != NULL, s->close != NULL, s->isOpen != NULL, s->actuate != NULL];
    if (s->failure[0] != '\0') {
        [out appendFormat:@"  failure          : %s\n", s->failure];
    }
    [out appendFormat:@"  device           : 0x%llx\n", (unsigned long long)deviceID];
    [out appendFormat:@"  created / open   : %@ / %@\n", created ? @"yes" : @"no", open ? @"yes" : @"no"];
    [out appendFormat:@"  recent failures  : %d\n", failures];
    return out;
}

@end
