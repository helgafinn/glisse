//
//  GLMultitouchTypes.h
//  GlissePrivate
//
//  Stable, ABI-safe types handed to Swift.
//
//  PRIVATE API WARNING
//  -------------------
//  The layout of MultitouchSupport.framework's `MTTouch` is not published by
//  Apple and has changed size across releases. Swift never sees `MTTouch`;
//  the Objective-C bridge parses it defensively and emits `GLRawTouch`, which
//  is entirely ours and therefore stable.
//

#ifndef ES_MULTITOUCH_TYPES_H
#define ES_MULTITOUCH_TYPES_H

#include <stdint.h>
#include <stdbool.h>
#import <Foundation/NSObjCRuntime.h>

#ifdef __cplusplus
extern "C" {
#endif

/// Raw MultitouchSupport touch states.
///
/// Verified empirically against MultitouchSupport on macOS; these are the
/// values the framework actually reports (see `GLMTTouchStateIsTouching`).
/// Anything outside 1...8 is treated as a layout-parse failure.
typedef NS_ENUM(int32_t, GLMTTouchState) {
    GLMTTouchStateNotTracking   = 0,
    GLMTTouchStateStartInRange  = 1,
    GLMTTouchStateHoverInRange  = 2,
    GLMTTouchStateMakeTouch     = 3,
    GLMTTouchStateTouching      = 4,
    GLMTTouchStateBreakTouch    = 5,
    GLMTTouchStateLingerInRange = 6,
    GLMTTouchStateOutOfRange    = 7,
};

/// True for states where the finger is physically on the surface.
static inline bool GLMTTouchStateIsTouching(int32_t state) {
    return state == GLMTTouchStateMakeTouch
        || state == GLMTTouchStateTouching
        || state == GLMTTouchStateStartInRange;
}

/// A single contact, in Glisse's canonical coordinate space.
///
/// `x`/`y` are normalised 0...1 with the origin at the **bottom-left** of the
/// trackpad surface and +y pointing towards the top edge (away from the user),
/// matching AppKit's `NSTouch.normalizedPosition`. The bridge performs any
/// flipping required so consumers never have to care.
typedef struct GLRawTouch {
    int32_t identifier;   ///< MT "path index": stable for the life of a contact.
    int32_t fingerID;
    int32_t handID;
    int32_t state;        ///< GLMTTouchState
    double  x;            ///< 0...1, left -> right
    double  y;            ///< 0...1, bottom -> top
    double  velocityX;
    double  velocityY;
    double  pressure;     ///< MT "z total"; arbitrary units, >= 0
    double  majorAxis;
    double  minorAxis;
    double  angle;
    double  timestamp;    ///< Seconds, MT clock (mach uptime based).
} GLRawTouch;

/// How a byte layout was arrived at, for diagnostics.
typedef NS_ENUM(int32_t, GLMTLayoutOrigin) {
    GLMTLayoutOriginAssumed   = 0,  ///< canonical layout, not yet corroborated
    GLMTLayoutOriginValidated = 1,  ///< corroborated against >= 2-contact frames
    GLMTLayoutOriginRecovered = 2,  ///< canonical failed, offsets re-discovered
    GLMTLayoutOriginFailed    = 3,  ///< could not parse; source unusable
};

/// The byte layout the bridge is currently using to read `MTTouch`.
typedef struct GLMTLayout {
    int32_t stride;             ///< sizeof(MTTouch)
    int32_t offsetTimestamp;
    int32_t offsetIdentifier;
    int32_t offsetState;
    int32_t offsetFingerID;
    int32_t offsetHandID;
    int32_t offsetPosition;     ///< float x, float y, float vx, float vy
    int32_t offsetSize;
    int32_t offsetAngle;        ///< float angle, float major, float minor
    int32_t origin;             ///< GLMTLayoutOrigin
    int32_t confirmations;
} GLMTLayout;

#ifdef __cplusplus
}
#endif

#endif /* ES_MULTITOUCH_TYPES_H */
