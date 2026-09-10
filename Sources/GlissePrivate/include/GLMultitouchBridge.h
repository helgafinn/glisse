//
//  GLMultitouchBridge.h
//  GlissePrivate
//
//  PRIVATE API: /System/Library/PrivateFrameworks/MultitouchSupport.framework
//
//  Why this is unavoidable
//  ----------------------
//  macOS exposes trackpad contacts publicly only through `NSTouch`, which is
//  delivered to the *focused* application. A background utility therefore has
//  two options: a CGEventTap on gesture events (works, but requires
//  Accessibility permission and only sees events the window server routes), or
//  MultitouchSupport, which streams every contact from the device itself with
//  no permission prompt and much lower latency.
//
//  Glisse uses MultitouchSupport as the primary source and the public
//  NSTouch/CGEventTap path as a fallback (see NSTouchTrackpadSource.swift).
//
//  Safety
//  ------
//  * Every symbol is resolved with dlopen/dlsym. A missing symbol reports
//    "unavailable"; it never causes a dyld launch failure.
//  * `MTTouch` is parsed through a validated byte layout, never a hard-coded
//    struct declaration.
//  * Frame callbacks arrive on a MultitouchSupport-owned thread. The handler
//    must not block.
//

#import <Foundation/Foundation.h>
#import "GLMultitouchTypes.h"

NS_ASSUME_NONNULL_BEGIN

/// Immutable snapshot describing one physical multitouch device.
@interface GLMultitouchDeviceInfo : NSObject
/// Stable identity across replug where the framework provides a GUID,
/// otherwise derived from the device ID. Used as the gesture-session key.
@property (nonatomic, readonly, copy) NSString *key;
@property (nonatomic, readonly, copy) NSString *displayName;
@property (nonatomic, readonly) BOOL isBuiltIn;
@property (nonatomic, readonly) BOOL isOpaqueSurface;
@property (nonatomic, readonly) uint64_t deviceID;
@property (nonatomic, readonly) int32_t familyID;
/// Physical sensor surface, in units of 1/100 mm as reported by the framework.
/// Zero when unavailable.
@property (nonatomic, readonly) int32_t surfaceWidth;
@property (nonatomic, readonly) int32_t surfaceHeight;
/// Sensor element counts (columns/rows). Zero when unavailable.
@property (nonatomic, readonly) int32_t sensorColumns;
@property (nonatomic, readonly) int32_t sensorRows;
@end

/// Frame handler.
///
/// @param deviceKey  matches `GLMultitouchDeviceInfo.key`
/// @param touches    borrowed buffer, valid only for the duration of the call
typedef void (^GLMultitouchFrameHandler)(NSString *deviceKey,
                                        int32_t frameNumber,
                                        double timestamp,
                                        const GLRawTouch * _Nullable touches,
                                        NSInteger touchCount);

@interface GLMultitouchBridge : NSObject

/// YES when MultitouchSupport.framework loaded and the required symbols exist.
@property (class, nonatomic, readonly) BOOL isFrameworkAvailable;
/// Human-readable reason when `isFrameworkAvailable` is NO.
@property (class, nonatomic, readonly, copy) NSString *unavailableReason;

/// Called on a MultitouchSupport thread. Set before `start`.
@property (atomic, copy, nullable) GLMultitouchFrameHandler frameHandler;

/// Invoked (on an arbitrary thread) when the bridge concludes the byte layout
/// cannot be parsed, so the caller can switch to the public fallback source.
@property (atomic, copy, nullable) void (^layoutFailureHandler)(void);

@property (nonatomic, readonly, copy) NSArray<GLMultitouchDeviceInfo *> *devices;
@property (nonatomic, readonly, getter=isRunning) BOOL running;

/// Re-enumerates devices, then registers + starts callbacks on each.
/// Idempotent. Safe to call again after wake or a hot-plug.
- (BOOL)startAndReturnError:(NSError * _Nullable * _Nullable)error;

/// Unregisters callbacks and releases every device reference.
- (void)stop;

/// Full teardown + fresh enumeration. Used on wake and on device hot-plug,
/// where retained MTDeviceRefs can become stale.
- (BOOL)restartAndReturnError:(NSError * _Nullable * _Nullable)error;

/// Current byte layout in use.
- (GLMTLayout)currentLayout;

/// Multi-line human-readable dump for `--diagnose` / the Diagnostics window.
- (NSString *)diagnosticsDescription;

/// Hex dump of the most recently received frame's first 160 bytes.
/// Empty until a frame has been seen. Used to refine the layout if a future
/// macOS release changes `MTTouch` in a way the validator cannot recover from.
- (NSString *)lastFrameHexDump;

@end

NS_ASSUME_NONNULL_END
