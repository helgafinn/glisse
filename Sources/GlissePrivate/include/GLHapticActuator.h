//
//  GLHapticActuator.h
//  GlissePrivate
//
//  PRIVATE API: MultitouchSupport.framework — the MTActuator family.
//
//  Why this is unavoidable
//  ----------------------
//  `NSHapticFeedbackManager.defaultPerformer` is the public way to tap the
//  trackpad, and it is documented as feedback "in response to user actions in
//  your app". Measured on macOS 27.0 / M2 Pro: it produces nothing at all from an
//  LSUIElement accessory app that is never the active application — which is
//  exactly what Glisse is. There is no public alternative.
//
//  MTActuator drives the actuator directly. It needs no permission, works from a
//  background process, and exposes several distinct actuation patterns, which is
//  also the only way to offer a real "strength" choice (the public API has three
//  fixed patterns and no intensity control).
//
//  Verified on hardware: MTActuatorCreateFromDeviceID with the value from
//  MTDeviceGetDeviceID returns a live actuator, MTActuatorOpen succeeds, and
//  actuation IDs 1–6, 15 and 16 all return kIOReturnSuccess.
//
//  Symbols (all dlsym'd, all optional — absence means "fall back to AppKit"):
//    MTActuatorCreateFromDeviceID(UInt64) -> MTActuatorRef
//    MTActuatorOpen / MTActuatorClose / MTActuatorIsOpen
//    MTActuatorActuate(ref, actuationID, unknown, Float32, Float32)
//

#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

/// Actuation patterns the trackpad understands. Names describe how firm each one
/// feels; the numbers are the framework's own identifiers.
typedef NS_ENUM(int32_t, GLActuationPattern) {
    GLActuationPatternWeak       = 1,
    GLActuationPatternLight      = 2,
    GLActuationPatternMedium     = 3,
    GLActuationPatternFirm       = 4,
    GLActuationPatternStrong     = 5,
    GLActuationPatternStrongest  = 6,
    GLActuationPatternAlt1       = 15,
    GLActuationPatternAlt2       = 16,
};

@interface GLHapticActuator : NSObject

/// YES when the MTActuator symbols resolved. Does not imply a device is open.
@property (class, nonatomic, readonly) BOOL isFrameworkAvailable;

/// Every actuation id that is valid to pass to `-actuate:`.
@property (class, nonatomic, readonly) NSArray<NSNumber *> *allPatterns;

/// YES once an actuator has been created and opened.
@property (nonatomic, readonly) BOOL isReady;

/// Creates and opens an actuator for a multitouch device id (as reported by
/// `MTDeviceGetDeviceID`). Idempotent for the same id.
/// @return NO when the device has no actuator, or the framework is unavailable.
- (BOOL)prepareForDeviceID:(uint64_t)deviceID;

/// Fires one tap. Safe to call from any thread; safe to call when not ready
/// (returns NO so the caller can fall back).
- (BOOL)actuate:(GLActuationPattern)pattern;

/// Closes and releases. Call before sleep and on device loss — a retained
/// actuator across a sleep can stop responding.
- (void)invalidate;

- (NSString *)diagnosticsDescription;

@end

NS_ASSUME_NONNULL_END
