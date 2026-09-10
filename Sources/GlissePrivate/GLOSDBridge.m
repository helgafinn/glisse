//
//  GLOSDBridge.m
//  GlissePrivate
//
//  Two routes to the system HUD, tried in order.
//
//  Route 1 — XPC to `com.apple.OSDUIHelper`.
//    OSDUIHelper is the on-demand agent that actually draws the HUD. Talking to
//    it directly is what current macOS releases respond to. The protocol must be
//    declared in Objective-C: NSXPCInterface reads extended method signature
//    metadata that the Swift compiler does not emit, and throws
//    NSInvalidArgumentException ("Use of clang is required for NSXPCInterface")
//    for a Swift-declared protocol.
//
//  Route 2 — `-[OSDManager showImage:…]`.
//    The older path. Kept as a fallback for macOS versions where it still works.
//
//  Everything is reached through runtime lookup and wrapped so a shape change
//  degrades to "native HUD unavailable" and Glisse draws its own panel.
//

#import "GLOSDBridge.h"

#import <dlfcn.h>
#import <pthread.h>
#import <math.h>
#import <objc/message.h>

// ---------------------------------------------------------------------------
// MARK: - OSDUIHelper
// ---------------------------------------------------------------------------

/// Reconstructed interface of the OSDUIHelper XPC service.
///
/// Argument widths matter here in a way they do not for objc_msgSend: NSXPCConnection
/// encodes each argument from the protocol's type signature, so `int` must be
/// `int` and `unsigned int` must be `unsigned int`.
@protocol GLOSDUIHelperProtocol <NSObject>

- (void)showImage:(int)image
      onDisplayID:(unsigned int)displayID
         priority:(unsigned int)priority
    msecUntilFade:(unsigned int)msecUntilFade
   filledChiclets:(unsigned int)filledChiclets
    totalChiclets:(unsigned int)totalChiclets
           locked:(BOOL)locked;

- (void)showImage:(int)image
      onDisplayID:(unsigned int)displayID
         priority:(unsigned int)priority
    msecUntilFade:(unsigned int)msecUntilFade;

- (void)fadeClassicImageOnDisplay:(unsigned int)displayID;

@end

/// Locally declared shape of the private OSDManager class.
@protocol GLOSDManagerShim <NSObject>
- (void)showImage:(long long)image
      onDisplayID:(unsigned int)displayID
         priority:(unsigned int)priority
    msecUntilFade:(unsigned int)msecUntilFade
   filledChiclets:(unsigned int)filledChiclets
    totalChiclets:(unsigned int)totalChiclets
           locked:(BOOL)locked;

- (void)showImage:(long long)image
      onDisplayID:(unsigned int)displayID
         priority:(unsigned int)priority
    msecUntilFade:(unsigned int)msecUntilFade;
@end

// ---------------------------------------------------------------------------
// MARK: - State
// ---------------------------------------------------------------------------

static pthread_mutex_t gOSDLock = PTHREAD_MUTEX_INITIALIZER;

static NSXPCConnection *gHelperConnection;
static BOOL gHelperUsable = YES;          // until proven otherwise
static NSInteger gHelperFailures;

static void *gOSDHandle;
static id<GLOSDManagerShim> gManager;
static BOOL gManagerSupportsMetered;
static BOOL gManagerProbed;

static GLOSDRoute gRouteOverride = GLOSDRouteNone;
static GLOSDRoute gLastUsedRoute = GLOSDRouteNone;
static char gFailure[240];

// ---------------------------------------------------------------------------
// MARK: - Route 1: OSDUIHelper
// ---------------------------------------------------------------------------

/// Lock held.
static id<GLOSDUIHelperProtocol> _Nullable GLOSDHelperProxyLocked(void) {
    if (!gHelperUsable) return nil;

    if (gHelperConnection == nil) {
        // The helper is a per-user on-demand agent. `.privileged` is what reaches
        // it; a plain connection is refused.
        NSXPCConnection *connection =
            [[NSXPCConnection alloc] initWithMachServiceName:@"com.apple.OSDUIHelper"
                                                    options:NSXPCConnectionPrivileged];
        @try {
            connection.remoteObjectInterface =
                [NSXPCInterface interfaceWithProtocol:@protocol(GLOSDUIHelperProtocol)];
        } @catch (NSException *exception) {
            snprintf(gFailure, sizeof(gFailure),
                     "NSXPCInterface rejected the protocol: %s",
                     exception.reason.UTF8String ?: "?");
            gHelperUsable = NO;
            return nil;
        }

        connection.interruptionHandler = ^{
            // The helper exits when idle; that is normal, not a failure.
            pthread_mutex_lock(&gOSDLock);
            gHelperConnection = nil;
            pthread_mutex_unlock(&gOSDLock);
        };
        connection.invalidationHandler = ^{
            pthread_mutex_lock(&gOSDLock);
            gHelperConnection = nil;
            gHelperFailures += 1;
            // Invalidation means the service could not be reached at all.
            if (gHelperFailures >= 3) {
                gHelperUsable = NO;
                snprintf(gFailure, sizeof(gFailure),
                         "com.apple.OSDUIHelper connection invalidated %ld times",
                         (long)gHelperFailures);
            }
            pthread_mutex_unlock(&gOSDLock);
        };

        [connection resume];
        gHelperConnection = connection;
    }

    id proxy = gHelperConnection.remoteObjectProxy;
    return (id<GLOSDUIHelperProtocol>)proxy;
}

// ---------------------------------------------------------------------------
// MARK: - Route 2: OSDManager
// ---------------------------------------------------------------------------

/// Lock held.
static id<GLOSDManagerShim> _Nullable GLOSDManagerLocked(void) {
    if (gManagerProbed) return gManager;
    gManagerProbed = YES;

    gOSDHandle = dlopen("/System/Library/PrivateFrameworks/OSD.framework/OSD",
                        RTLD_LAZY | RTLD_LOCAL);
    if (gOSDHandle == NULL) return nil;

    Class cls = NSClassFromString(@"OSDManager");
    if (cls == Nil) return nil;

    SEL sharedSel = NSSelectorFromString(@"sharedManager");
    if (![cls respondsToSelector:sharedSel]) return nil;

    id manager = ((id (*)(id, SEL))objc_msgSend)((id)cls, sharedSel);
    if (manager == nil) return nil;

    SEL metered = NSSelectorFromString(
        @"showImage:onDisplayID:priority:msecUntilFade:filledChiclets:totalChiclets:locked:");
    gManagerSupportsMetered = [manager respondsToSelector:metered];
    // An unchecked cast is intentional: OSDManager does not declare conformance
    // to our locally reconstructed protocol, so a checked cast would always fail.
    gManager = (id<GLOSDManagerShim>)manager;
    return gManager;
}

// ---------------------------------------------------------------------------
// MARK: - Bridge
// ---------------------------------------------------------------------------

@implementation GLOSDBridge

/// Whether the legacy OSD path can be believed on this OS.
///
/// Measured on macOS 27.0 (26A5416b):
///   * `-[OSDManager showImage:…]` accepts every call and throws nothing, but
///     nothing is drawn.
///   * `com.apple.OSDUIHelper` refuses the XPC connection (invalidated
///     immediately, three attempts).
///   * Critically, pressing the *real* volume keys does not launch OSDUIHelper
///     either — so that service is no longer the renderer, and Apple has moved
///     HUD drawing somewhere that has no reachable interface.
///
/// A private API that silently does nothing is worse than one that fails loudly,
/// because the app would report success while the user sees no HUD. So on macOS
/// 26 and later the native route declares itself unavailable and Glisse draws
/// its own panel, unless a route is explicitly forced (`-overrideRoute:`) — which
/// is what the Settings toggle and `--hudtest` use.
static BOOL GLLegacyOSDIsTrustworthy(void) {
    NSOperatingSystemVersion version = NSProcessInfo.processInfo.operatingSystemVersion;
    return version.majorVersion < 26;
}

+ (BOOL)isAvailable {
    pthread_mutex_lock(&gOSDLock);
    GLOSDRoute override = gRouteOverride;
    BOOL helper = gHelperUsable;
    id manager = GLOSDManagerLocked();
    BOOL metered = gManagerSupportsMetered;
    pthread_mutex_unlock(&gOSDLock);

    BOOL reachable = helper || (manager != nil && metered);
    if (override != GLOSDRouteNone) return reachable;
    return reachable && GLLegacyOSDIsTrustworthy();
}

+ (GLOSDRoute)activeRoute {
    pthread_mutex_lock(&gOSDLock);
    GLOSDRoute route = gLastUsedRoute;
    pthread_mutex_unlock(&gOSDLock);
    return route;
}

+ (void)overrideRoute:(GLOSDRoute)route {
    pthread_mutex_lock(&gOSDLock);
    gRouteOverride = route;
    // Give a forced route a clean slate.
    if (route == GLOSDRouteOSDUIHelper) {
        gHelperUsable = YES;
        gHelperFailures = 0;
    }
    pthread_mutex_unlock(&gOSDLock);
}

+ (void)invalidateConnections {
    pthread_mutex_lock(&gOSDLock);
    NSXPCConnection *connection = gHelperConnection;
    gHelperConnection = nil;
    gHelperUsable = YES;
    gHelperFailures = 0;
    pthread_mutex_unlock(&gOSDLock);
    [connection invalidate];
}

+ (BOOL)showGraphic:(GLOSDGraphic)graphic
              level:(double)level
           chiclets:(NSInteger)chiclets
          onDisplay:(CGDirectDisplayID)display {

    if (!isfinite(level)) return NO;
    if (level < 0.0) level = 0.0;
    if (level > 1.0) level = 1.0;
    if (chiclets < 1) chiclets = 16;
    if (chiclets > 100) chiclets = 100;
    if (display == kCGNullDirectDisplay) display = CGMainDisplayID();

    // Round half up so a nudge above zero lights the first segment, which is
    // what the system HUD does.
    NSInteger filled = (NSInteger)llround(level * (double)chiclets);
    if (filled < 0) filled = 0;
    if (filled > chiclets) filled = chiclets;

    pthread_mutex_lock(&gOSDLock);
    GLOSDRoute override = gRouteOverride;
    pthread_mutex_unlock(&gOSDLock);

    BOOL tryHelper  = (override == GLOSDRouteNone || override == GLOSDRouteOSDUIHelper);
    BOOL tryManager = (override == GLOSDRouteNone || override == GLOSDRouteOSDManager);

    // ---- Route 1 -------------------------------------------------------
    if (tryHelper) {
        pthread_mutex_lock(&gOSDLock);
        id<GLOSDUIHelperProtocol> helper = GLOSDHelperProxyLocked();
        pthread_mutex_unlock(&gOSDLock);

        if (helper != nil) {
            @try {
                [helper showImage:(int)graphic
                      onDisplayID:(unsigned int)display
                         priority:0x1F4              // 500, the value the system uses
                    msecUntilFade:1000
                   filledChiclets:(unsigned int)filled
                    totalChiclets:(unsigned int)chiclets
                           locked:NO];
                pthread_mutex_lock(&gOSDLock);
                gLastUsedRoute = GLOSDRouteOSDUIHelper;
                pthread_mutex_unlock(&gOSDLock);
                return YES;
            } @catch (NSException *exception) {
                pthread_mutex_lock(&gOSDLock);
                snprintf(gFailure, sizeof(gFailure), "OSDUIHelper threw: %s",
                         exception.reason.UTF8String ?: "?");
                gHelperConnection = nil;
                gHelperFailures += 1;
                if (gHelperFailures >= 3) gHelperUsable = NO;
                pthread_mutex_unlock(&gOSDLock);
            }
        }
    }

    // ---- Route 2 -------------------------------------------------------
    if (tryManager) {
        pthread_mutex_lock(&gOSDLock);
        id<GLOSDManagerShim> manager = GLOSDManagerLocked();
        BOOL metered = gManagerSupportsMetered;
        pthread_mutex_unlock(&gOSDLock);

        if (manager != nil && metered) {
            @try {
                [manager showImage:(long long)graphic
                       onDisplayID:(unsigned int)display
                          priority:0x1F4
                     msecUntilFade:1000
                    filledChiclets:(unsigned int)filled
                     totalChiclets:(unsigned int)chiclets
                            locked:NO];
                pthread_mutex_lock(&gOSDLock);
                gLastUsedRoute = GLOSDRouteOSDManager;
                pthread_mutex_unlock(&gOSDLock);
                return YES;
            } @catch (NSException *exception) {
                pthread_mutex_lock(&gOSDLock);
                snprintf(gFailure, sizeof(gFailure), "OSDManager threw: %s",
                         exception.reason.UTF8String ?: "?");
                gManager = nil;
                pthread_mutex_unlock(&gOSDLock);
            }
        }
    }

    pthread_mutex_lock(&gOSDLock);
    gLastUsedRoute = GLOSDRouteNone;
    pthread_mutex_unlock(&gOSDLock);
    return NO;
}

+ (NSString *)diagnosticsDescription {
    pthread_mutex_lock(&gOSDLock);
    id manager = GLOSDManagerLocked();
    BOOL metered = gManagerSupportsMetered;
    BOOL helperUsable = gHelperUsable;
    BOOL helperConnected = gHelperConnection != nil;
    NSInteger helperFailures = gHelperFailures;
    GLOSDRoute route = gLastUsedRoute;
    GLOSDRoute override = gRouteOverride;
    char failure[240];
    memcpy(failure, gFailure, sizeof(failure));
    pthread_mutex_unlock(&gOSDLock);

    static const char *routeNames[] = { "none", "OSDUIHelper (XPC)", "OSDManager" };
    int routeIndex = (route >= 0 && route <= 2) ? route : 0;
    int overrideIndex = (override >= 0 && override <= 2) ? override : 0;

    NSMutableString *out = [NSMutableString string];
    [out appendString:@"Native OSD (HUD) bridge\n"];
    [out appendFormat:@"  route in use     : %s\n", routeNames[routeIndex]];
    if (override != GLOSDRouteNone) {
        [out appendFormat:@"  route forced to  : %s\n", routeNames[overrideIndex]];
    }
    [out appendFormat:@"  OSDUIHelper      : usable=%@ connected=%@ failures=%ld\n",
     helperUsable ? @"yes" : @"no", helperConnected ? @"yes" : @"no", (long)helperFailures];
    [out appendFormat:@"  OSDManager       : %@ metered=%@\n",
     manager ? @"available" : @"unavailable", metered ? @"yes" : @"no"];
    [out appendFormat:@"  legacy OSD trusted: %@ (macOS %ld)\n",
     GLLegacyOSDIsTrustworthy() ? @"yes" : @"no — draws nothing on macOS 26+",
     (long)NSProcessInfo.processInfo.operatingSystemVersion.majorVersion];
    if (failure[0] != '\0') {
        [out appendFormat:@"  last failure     : %s\n", failure];
    }
    return out;
}

@end
