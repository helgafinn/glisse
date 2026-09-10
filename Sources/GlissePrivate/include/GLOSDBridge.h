//
//  GLOSDBridge.h
//  GlissePrivate
//
//  PRIVATE API: /System/Library/PrivateFrameworks/OSD.framework — `OSDManager`.
//
//  Why this is unavoidable
//  -----------------------
//  Apple ships no public API for showing the system volume / brightness HUD.
//  `OSDManager` is the object the window server itself uses. Everything here
//  goes through NSClassFromString + respondsToSelector, so a renamed class or
//  changed selector degrades to "native HUD unavailable" and Glisse falls
//  back to its own minimal HUD. Gestures keep working either way.
//
//  Selector (stable since ~10.9):
//    -showImage:onDisplayID:priority:msecUntilFade:filledChiclets:totalChiclets:locked:
//

#import <Foundation/Foundation.h>
#import <CoreGraphics/CoreGraphics.h>

NS_ASSUME_NONNULL_BEGIN

/// Graphic identifiers understood by the OSD. Only the three Glisse needs.
typedef NS_ENUM(NSInteger, GLOSDGraphic) {
    GLOSDGraphicBrightness        = 1,
    GLOSDGraphicSpeaker           = 3,
    GLOSDGraphicSpeakerMuted      = 4,
};

/// Which mechanism is actually driving the HUD.
typedef NS_ENUM(int32_t, GLOSDRoute) {
    GLOSDRouteNone         = 0,
    /// XPC to com.apple.OSDUIHelper — the service that renders the HUD.
    GLOSDRouteOSDUIHelper  = 1,
    /// -[OSDManager showImage:…]. Historically worked; see the note in the .m.
    GLOSDRouteOSDManager   = 2,
};

@interface GLOSDBridge : NSObject

/// YES when OSD.framework loaded, `OSDManager` exists, a shared instance was
/// obtained and it responds to the metered show selector.
@property (class, nonatomic, readonly) BOOL isAvailable;

+ (NSString *)diagnosticsDescription;

/// @param level     0...1
/// @param chiclets  number of segments; 16 matches the native HUD.
/// @return NO when the native HUD could not be driven.
+ (BOOL)showGraphic:(GLOSDGraphic)graphic
              level:(double)level
           chiclets:(NSInteger)chiclets
          onDisplay:(CGDirectDisplayID)display;

/// The route currently in use, for diagnostics.
@property (class, nonatomic, readonly) GLOSDRoute activeRoute;

/// Forces a specific route, for troubleshooting and for the `--hudtest` mode.
/// Pass `GLOSDRouteNone` to restore automatic selection.
+ (void)overrideRoute:(GLOSDRoute)route;

/// Drops the XPC connection. Call on wake: the helper is an on-demand agent and
/// the connection does not survive a long sleep.
+ (void)invalidateConnections;

@end

NS_ASSUME_NONNULL_END
