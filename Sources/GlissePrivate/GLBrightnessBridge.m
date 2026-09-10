//
//  GLBrightnessBridge.m
//  GlissePrivate
//

#import "GLBrightnessBridge.h"

#import <dlfcn.h>
#import <pthread.h>
#import <math.h>
#import <IOKit/IOKitLib.h>
#import <IOKit/graphics/IOGraphicsLib.h>

// ---------------------------------------------------------------------------
// MARK: - Symbols
// ---------------------------------------------------------------------------

typedef int      (*DSGetBrightnessFn)(CGDirectDisplayID, float *);
typedef int      (*DSSetBrightnessFn)(CGDirectDisplayID, float);
typedef bool     (*DSCanChangeBrightnessFn)(CGDirectDisplayID);
typedef void     (*DSBrightnessChangedFn)(CGDirectDisplayID, double);
typedef int      (*DSGetLinearBrightnessFn)(CGDirectDisplayID, float *);
typedef int      (*DSSetLinearBrightnessFn)(CGDirectDisplayID, float);

typedef double   (*CDGetUserBrightnessFn)(CGDirectDisplayID);
typedef void     (*CDSetUserBrightnessFn)(CGDirectDisplayID, double);

typedef struct GLBrightnessSymbols {
    void *displayServices;
    void *coreDisplay;

    DSGetBrightnessFn dsGet;
    DSSetBrightnessFn dsSet;
    DSCanChangeBrightnessFn dsCanChange;
    DSBrightnessChangedFn dsChanged;
    DSGetLinearBrightnessFn dsGetLinear;
    DSSetLinearBrightnessFn dsSetLinear;

    CDGetUserBrightnessFn cdGet;
    CDSetUserBrightnessFn cdSet;
} GLBrightnessSymbols;

static GLBrightnessSymbols gBS;
static pthread_once_t gBSOnce = PTHREAD_ONCE_INIT;

static void GLBrightnessLoad(void) {
    memset(&gBS, 0, sizeof(gBS));

    gBS.displayServices = dlopen(
        "/System/Library/PrivateFrameworks/DisplayServices.framework/DisplayServices",
        RTLD_LAZY | RTLD_LOCAL);
    gBS.coreDisplay = dlopen(
        "/System/Library/Frameworks/CoreDisplay.framework/CoreDisplay",
        RTLD_LAZY | RTLD_LOCAL);

    if (gBS.displayServices) {
        gBS.dsGet       = (DSGetBrightnessFn)dlsym(gBS.displayServices, "DisplayServicesGetBrightness");
        gBS.dsSet       = (DSSetBrightnessFn)dlsym(gBS.displayServices, "DisplayServicesSetBrightness");
        gBS.dsCanChange = (DSCanChangeBrightnessFn)dlsym(gBS.displayServices, "DisplayServicesCanChangeBrightness");
        gBS.dsChanged   = (DSBrightnessChangedFn)dlsym(gBS.displayServices, "DisplayServicesBrightnessChanged");
        gBS.dsGetLinear = (DSGetLinearBrightnessFn)dlsym(gBS.displayServices, "DisplayServicesGetLinearBrightness");
        gBS.dsSetLinear = (DSSetLinearBrightnessFn)dlsym(gBS.displayServices, "DisplayServicesSetLinearBrightness");
    }
    if (gBS.coreDisplay) {
        gBS.cdGet = (CDGetUserBrightnessFn)dlsym(gBS.coreDisplay, "CoreDisplay_Display_GetUserBrightness");
        gBS.cdSet = (CDSetUserBrightnessFn)dlsym(gBS.coreDisplay, "CoreDisplay_Display_SetUserBrightness");
    }
}

static const GLBrightnessSymbols *GLBrightnessSymbolsShared(void) {
    pthread_once(&gBSOnce, GLBrightnessLoad);
    return &gBS;
}

// ---------------------------------------------------------------------------
// MARK: - CoreDisplay trust probe
//
// CoreDisplay_Display_GetUserBrightness is not reliable on every machine. On
// macOS 27.0 / M2 Pro it returns a constant 1.0 while the real backlight sits
// anywhere. Before believing CoreDisplay, cross-check it against DisplayServices
// once. If they disagree, CoreDisplay is treated as unusable for that display.
// ---------------------------------------------------------------------------

static BOOL GLCoreDisplayLooksTrustworthy(CGDirectDisplayID display) {
    const GLBrightnessSymbols *s = GLBrightnessSymbolsShared();
    if (s->cdGet == NULL || s->cdSet == NULL) return NO;

    double cd = s->cdGet(display);
    if (!isfinite(cd) || cd < 0.0 || cd > 1.0) return NO;

    // No DisplayServices to compare against: accept CoreDisplay, it is all we
    // have (this is the situation on machines where DisplayServices is gone).
    if (s->dsGet == NULL) return YES;

    float ds = 0.0f;
    if (s->dsGet(display, &ds) != 0 || !isfinite(ds)) return YES;

    return fabs((double)ds - cd) < 0.10;
}

// ---------------------------------------------------------------------------
// MARK: - IODisplay (Intel-era) fallback
// ---------------------------------------------------------------------------

/// Finds the IODisplayConnect service for a display. Only useful on Intel Macs
/// where the backlight is an IODisplay parameter.
static io_service_t GLCopyDisplayServiceForID(CGDirectDisplayID display) {
    io_iterator_t iterator = IO_OBJECT_NULL;
    if (IOServiceGetMatchingServices(kIOMainPortDefault,
                                     IOServiceMatching("IODisplayConnect"),
                                     &iterator) != KERN_SUCCESS) {
        return IO_OBJECT_NULL;
    }

    uint32_t wantVendor = CGDisplayVendorNumber(display);
    uint32_t wantModel  = CGDisplayModelNumber(display);

    io_service_t service = IO_OBJECT_NULL;
    io_service_t candidate = IO_OBJECT_NULL;
    io_service_t firstAny = IO_OBJECT_NULL;

    while ((candidate = IOIteratorNext(iterator)) != IO_OBJECT_NULL) {
        CFDictionaryRef info = IODisplayCreateInfoDictionary(candidate, kIODisplayOnlyPreferredName);
        if (info == NULL) { IOObjectRelease(candidate); continue; }

        CFNumberRef vendorRef = CFDictionaryGetValue(info, CFSTR(kDisplayVendorID));
        CFNumberRef productRef = CFDictionaryGetValue(info, CFSTR(kDisplayProductID));
        uint32_t vendor = 0, product = 0;
        if (vendorRef)  CFNumberGetValue(vendorRef, kCFNumberSInt32Type, &vendor);
        if (productRef) CFNumberGetValue(productRef, kCFNumberSInt32Type, &product);
        CFRelease(info);

        if (firstAny == IO_OBJECT_NULL) {
            firstAny = candidate;
            IOObjectRetain(firstAny);
        }

        if (vendor == wantVendor && product == wantModel) {
            service = candidate;   // ownership transferred out
            break;
        }
        IOObjectRelease(candidate);
    }
    IOObjectRelease(iterator);

    if (service == IO_OBJECT_NULL) {
        service = firstAny;
    } else if (firstAny != IO_OBJECT_NULL) {
        IOObjectRelease(firstAny);
    }
    return service;
}

static BOOL GLIODisplayGet(CGDirectDisplayID display, double *out) {
    io_service_t service = GLCopyDisplayServiceForID(display);
    if (service == IO_OBJECT_NULL) return NO;
    float value = 0.0f;
    kern_return_t kr = IODisplayGetFloatParameter(service, kNilOptions,
                                                 CFSTR(kIODisplayBrightnessKey), &value);
    IOObjectRelease(service);
    if (kr != KERN_SUCCESS || !isfinite(value)) return NO;
    if (out) *out = (double)value;
    return YES;
}

static BOOL GLIODisplaySet(CGDirectDisplayID display, double value) {
    io_service_t service = GLCopyDisplayServiceForID(display);
    if (service == IO_OBJECT_NULL) return NO;
    kern_return_t kr = IODisplaySetFloatParameter(service, kNilOptions,
                                                 CFSTR(kIODisplayBrightnessKey), (float)value);
    IOObjectRelease(service);
    return kr == KERN_SUCCESS;
}

// ---------------------------------------------------------------------------
// MARK: - Bridge
// ---------------------------------------------------------------------------

@implementation GLBrightnessBridge

+ (BOOL)isAvailable {
    const GLBrightnessSymbols *s = GLBrightnessSymbolsShared();
    return (s->dsSet != NULL) || (s->cdSet != NULL);
}

+ (NSString *)diagnosticsDescription {
    const GLBrightnessSymbols *s = GLBrightnessSymbolsShared();
    NSMutableString *out = [NSMutableString string];
    [out appendString:@"Brightness bridge\n"];
    [out appendFormat:@"  DisplayServices  : loaded=%d get=%d set=%d canChange=%d changed=%d linear(get/set)=%d/%d\n",
     s->displayServices != NULL, s->dsGet != NULL, s->dsSet != NULL,
     s->dsCanChange != NULL, s->dsChanged != NULL,
     s->dsGetLinear != NULL, s->dsSetLinear != NULL];
    [out appendFormat:@"  CoreDisplay      : loaded=%d get=%d set=%d trusted(main)=%d\n",
     s->coreDisplay != NULL, s->cdGet != NULL, s->cdSet != NULL,
     GLCoreDisplayLooksTrustworthy(CGMainDisplayID())];
    return out;
}

+ (BOOL)canControlDisplay:(CGDirectDisplayID)display {
    const GLBrightnessSymbols *s = GLBrightnessSymbolsShared();

    // DisplayServicesCanChangeBrightness is the system's own answer; trust a
    // YES immediately.
    if (s->dsCanChange && s->dsCanChange(display)) return YES;

    // Otherwise: if we can read a plausible value, we can almost certainly set it.
    double probe = 0.0;
    return [self getBrightness:&probe forDisplay:display];
}

+ (GLBrightnessBackendKind)preferredBackendForDisplay:(CGDirectDisplayID)display {
    const GLBrightnessSymbols *s = GLBrightnessSymbolsShared();
    float f = 0.0f;

    if (s->dsGet && s->dsSet && s->dsGet(display, &f) == 0 && isfinite(f)) {
        return GLBrightnessBackendKindDisplayServices;
    }
    if (s->cdGet && s->cdSet && GLCoreDisplayLooksTrustworthy(display)) {
        return GLBrightnessBackendKindCoreDisplay;
    }
    double io = 0.0;
    if (GLIODisplayGet(display, &io)) {
        return GLBrightnessBackendKindIODisplay;
    }
    return GLBrightnessBackendKindNone;
}

+ (BOOL)getBrightness:(double *)outValue forDisplay:(CGDirectDisplayID)display {
    const GLBrightnessSymbols *s = GLBrightnessSymbolsShared();

    if (s->dsGet) {
        float f = 0.0f;
        if (s->dsGet(display, &f) == 0 && isfinite(f) && f >= 0.0f && f <= 1.0f) {
            if (outValue) *outValue = (double)f;
            return YES;
        }
    }
    if (s->cdGet && GLCoreDisplayLooksTrustworthy(display)) {
        double v = s->cdGet(display);
        if (isfinite(v) && v >= 0.0 && v <= 1.0) {
            if (outValue) *outValue = v;
            return YES;
        }
    }
    double io = 0.0;
    if (GLIODisplayGet(display, &io)) {
        if (outValue) *outValue = io;
        return YES;
    }
    return NO;
}

+ (BOOL)setBrightness:(double)value forDisplay:(CGDirectDisplayID)display {
    if (!isfinite(value)) return NO;
    if (value < 0.0) value = 0.0;
    if (value > 1.0) value = 1.0;

    const GLBrightnessSymbols *s = GLBrightnessSymbolsShared();
    BOOL wrote = NO;

    if (s->dsSet && s->dsSet(display, (float)value) == 0) {
        wrote = YES;
    }

    // CoreDisplay is a *fallback only*, never a companion write.
    //
    // Measured on macOS 27.0 / M2 Pro: CoreDisplay_Display_GetUserBrightness
    // returns a constant 1.0 regardless of the real backlight level, and
    // CoreDisplay_Display_SetUserBrightness has no observable effect. Writing
    // to it after a successful DisplayServices write would only push a value
    // into a store that disagrees with reality.
    if (!wrote && s->cdSet && GLCoreDisplayLooksTrustworthy(display)) {
        s->cdSet(display, value);
        wrote = YES;
    }

    if (!wrote) {
        wrote = GLIODisplaySet(display, value);
    }

    // Absent on macOS 27; when present it is what refreshes the system UI.
    if (wrote && s->dsChanged) {
        s->dsChanged(display, value);
    }

    return wrote;
}

@end
