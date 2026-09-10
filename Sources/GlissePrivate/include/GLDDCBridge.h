//
//  GLDDCBridge.h
//  GlissePrivate
//
//  DDC/CI transport for external monitors.
//
//  PRIVATE API (Apple Silicon): IOAVServiceCreateWithService / IOAVServiceReadI2C /
//  IOAVServiceWriteI2C. These live in IOKit.framework but are not declared in
//  any public header, so they are dlsym'd.
//
//  PUBLIC-ish API (Intel): IOI2CSendRequest + IOFBCopyI2CInterfaceForBus, which
//  are in IOGraphicsLib.h but effectively unsupported on modern hardware.
//
//  Why this is needed
//  ------------------
//  macOS provides no API at all for external-monitor brightness. Every utility
//  that offers it speaks DDC/CI over the display's I2C channel. There is no
//  alternative short of not supporting external displays.
//
//  This transport is deliberately dumb: it moves bytes and reports failure.
//  Retry policy, capability caching and the circuit breaker live in Swift
//  (DDCBrightnessBackend / DDCScheduler).
//

#import <Foundation/Foundation.h>
#import <CoreGraphics/CoreGraphics.h>

NS_ASSUME_NONNULL_BEGIN

typedef NS_ENUM(int32_t, GLDDCTransportKind) {
    GLDDCTransportKindNone     = 0,
    GLDDCTransportKindIOAVService = 1,   ///< Apple Silicon
    GLDDCTransportKindIOI2C       = 2,   ///< Intel
};

/// One display's DDC channel. Create once, reuse; recreate after a display
/// reconfiguration.
@interface GLDDCLink : NSObject

@property (nonatomic, readonly) CGDirectDisplayID displayID;
@property (nonatomic, readonly) GLDDCTransportKind transport;
/// How the display was paired with its I2C channel — "edid", "serial",
/// "index" or "none". Index pairing is a guess and is reported as such.
@property (nonatomic, readonly, copy) NSString *matchStrategy;

/// nil when no channel could be opened for this display.
+ (nullable GLDDCLink *)linkForDisplay:(CGDirectDisplayID)displayID
    NS_SWIFT_NAME(makeLink(display:));

/// Set VCP feature. `value` is in the monitor's native units.
- (BOOL)writeVCPCode:(uint8_t)code value:(uint16_t)value;

/// Get VCP feature.
/// @param outCurrent native units
/// @param outMax     native maximum (do not assume 100)
- (BOOL)readVCPCode:(uint8_t)code
         outCurrent:(uint16_t *)outCurrent
             outMax:(uint16_t *)outMax;

@end

@interface GLDDCBridge : NSObject
/// YES when a transport is usable on this machine.
@property (class, nonatomic, readonly) BOOL isAvailable;
@property (class, nonatomic, readonly) GLDDCTransportKind transportKind;
+ (NSString *)diagnosticsDescription;
/// Drops every cached I2C channel. Call on display reconfiguration and on wake.
+ (void)invalidateAllLinks;
@end

NS_ASSUME_NONNULL_END
