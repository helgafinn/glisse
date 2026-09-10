//
//  GLBrightnessBridge.h
//  GlissePrivate
//
//  PRIVATE API: DisplayServices.framework and CoreDisplay.framework.
//
//  Why this is unavoidable
//  -----------------------
//  There is no public API to set the built-in display's backlight level.
//  `IODisplaySetFloatParameter(kIODisplayBrightnessKey)` worked on Intel Macs
//  but the Apple Silicon backlight is not exposed through IODisplay, so on
//  every current Mac the only options are DisplayServices or CoreDisplay.
//
//  Both are probed at runtime; whichever answers is used. If neither answers,
//  built-in brightness reports itself unsupported rather than faking a change
//  with a gamma ramp or a translucent overlay.
//
//  Symbols used (all dlsym'd, all individually optional):
//    DisplayServicesGetBrightness(CGDirectDisplayID, float *)
//    DisplayServicesSetBrightness(CGDirectDisplayID, float)
//    DisplayServicesCanChangeBrightness(CGDirectDisplayID)
//    DisplayServicesBrightnessChanged(CGDirectDisplayID, double)   [absent on macOS 27]
//    DisplayServicesGetLinearBrightness / SetLinearBrightness
//    CoreDisplay_Display_GetUserBrightness(CGDirectDisplayID)          -> double
//    CoreDisplay_Display_SetUserBrightness(CGDirectDisplayID, double)
//

#import <Foundation/Foundation.h>
#import <CoreGraphics/CoreGraphics.h>

NS_ASSUME_NONNULL_BEGIN

typedef NS_ENUM(int32_t, GLBrightnessBackendKind) {
    GLBrightnessBackendKindNone           = 0,
    GLBrightnessBackendKindDisplayServices = 1,
    GLBrightnessBackendKindCoreDisplay     = 2,
    GLBrightnessBackendKindIODisplay       = 3,  ///< Intel fallback
};

@interface GLBrightnessBridge : NSObject

/// YES when at least one backend resolved.
@property (class, nonatomic, readonly) BOOL isAvailable;

/// Which backends resolved, for diagnostics.
+ (NSString *)diagnosticsDescription;

/// Asks the system whether this display's brightness is settable.
/// Conservative: returns YES if any backend reports success reading a value.
+ (BOOL)canControlDisplay:(CGDirectDisplayID)display;

/// Best backend for a display, or `None`.
+ (GLBrightnessBackendKind)preferredBackendForDisplay:(CGDirectDisplayID)display;

/// @return NO if no backend could read a value.
+ (BOOL)getBrightness:(double *)outValue forDisplay:(CGDirectDisplayID)display;

/// Writes brightness and notifies the system so the Control Centre slider and
/// the brightness key HUD stay in sync where the notification symbol exists.
+ (BOOL)setBrightness:(double)value forDisplay:(CGDirectDisplayID)display;

@end

NS_ASSUME_NONNULL_END
