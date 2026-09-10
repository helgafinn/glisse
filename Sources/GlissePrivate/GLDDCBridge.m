//
//  GLDDCBridge.m
//  GlissePrivate
//

#import "GLDDCBridge.h"

#import <dlfcn.h>
#import <pthread.h>
#import <unistd.h>
#import <string.h>
#import <IOKit/IOKitLib.h>
#import <IOKit/graphics/IOGraphicsLib.h>
#import <IOKit/i2c/IOI2CInterface.h>

// ---------------------------------------------------------------------------
// MARK: - DDC/CI protocol constants
// ---------------------------------------------------------------------------

/// 7-bit I2C address of the DDC/CI slave inside a monitor.
static const uint32_t kDDCChipAddress7Bit = 0x37;
/// 8-bit write form of the above; the checksum seed for host->display frames.
static const uint8_t  kDDCDestinationAddress = 0x6E;
/// Host source address as it appears on the wire.
static const uint8_t  kDDCSourceAddress = 0x51;

static const uint8_t kDDCOpSetVCP      = 0x03;
static const uint8_t kDDCOpGetVCP      = 0x01;
static const uint8_t kDDCOpGetVCPReply = 0x02;

/// Monitors are slow. These are the delays every DDC implementation converges
/// on; going lower produces sporadic NAKs on real hardware.
static const useconds_t kDDCWriteSettleUs  = 12000;   // 12 ms after a write
static const useconds_t kDDCReplyDelayUs   = 45000;   // 45 ms before reading

// ---------------------------------------------------------------------------
// MARK: - IOAVService (Apple Silicon) symbols
// ---------------------------------------------------------------------------

typedef CFTypeRef IOAVServiceRef;

typedef IOAVServiceRef (*IOAVServiceCreateWithServiceFn)(CFAllocatorRef, io_service_t);
typedef IOReturn (*IOAVServiceWriteI2CFn)(IOAVServiceRef, uint32_t chip, uint32_t offset,
                                          const void *buffer, uint32_t length);
typedef IOReturn (*IOAVServiceReadI2CFn)(IOAVServiceRef, uint32_t chip, uint32_t offset,
                                         void *buffer, uint32_t length);

typedef struct GLDDCSymbols {
    void *handle;
    IOAVServiceCreateWithServiceFn createWithService;
    IOAVServiceWriteI2CFn write;
    IOAVServiceReadI2CFn read;
    bool available;
    char failure[200];
} GLDDCSymbols;

static GLDDCSymbols gDDC;
static pthread_once_t gDDCOnce = PTHREAD_ONCE_INIT;

static void GLDDCLoad(void) {
    memset(&gDDC, 0, sizeof(gDDC));

    // The symbols live in IOKit itself; RTLD_DEFAULT finds them because IOKit is
    // already linked. dlopen of the framework path is a belt-and-braces retry.
    gDDC.createWithService = (IOAVServiceCreateWithServiceFn)dlsym(RTLD_DEFAULT, "IOAVServiceCreateWithService");
    gDDC.write = (IOAVServiceWriteI2CFn)dlsym(RTLD_DEFAULT, "IOAVServiceWriteI2C");
    gDDC.read  = (IOAVServiceReadI2CFn)dlsym(RTLD_DEFAULT, "IOAVServiceReadI2C");

    if (gDDC.createWithService == NULL || gDDC.write == NULL || gDDC.read == NULL) {
        gDDC.handle = dlopen("/System/Library/Frameworks/IOKit.framework/IOKit",
                             RTLD_LAZY | RTLD_LOCAL);
        if (gDDC.handle) {
            if (!gDDC.createWithService)
                gDDC.createWithService = (IOAVServiceCreateWithServiceFn)dlsym(gDDC.handle, "IOAVServiceCreateWithService");
            if (!gDDC.write)
                gDDC.write = (IOAVServiceWriteI2CFn)dlsym(gDDC.handle, "IOAVServiceWriteI2C");
            if (!gDDC.read)
                gDDC.read = (IOAVServiceReadI2CFn)dlsym(gDDC.handle, "IOAVServiceReadI2C");
        }
    }

    gDDC.available = (gDDC.createWithService != NULL && gDDC.write != NULL && gDDC.read != NULL);
    if (!gDDC.available) {
        snprintf(gDDC.failure, sizeof(gDDC.failure),
                 "IOAVService symbols unavailable (create=%d write=%d read=%d)",
                 gDDC.createWithService != NULL, gDDC.write != NULL, gDDC.read != NULL);
    }
}

static const GLDDCSymbols *GLDDCSymbolsShared(void) {
    pthread_once(&gDDCOnce, GLDDCLoad);
    return &gDDC;
}

static BOOL GLIsAppleSilicon(void) {
#if defined(__arm64__) || defined(__aarch64__)
    return YES;
#else
    return NO;
#endif
}

// ---------------------------------------------------------------------------
// MARK: - IORegistry walk: pair external displays with AV services
//
// On Apple Silicon each display hangs off a DCP. Within a display's registry
// branch the framebuffer node (AppleCLCD2 / IOMobileFramebufferShim) carries
// `DisplayAttributes` describing the panel, and a sibling `DCPAVServiceProxy`
// node with Location == "External" is the I2C endpoint.
//
// Walking the registry in order therefore yields (attributes, av-service) pairs
// per display, which is how they get correlated back to a CGDirectDisplayID.
// ---------------------------------------------------------------------------

typedef struct GLAVCandidate {
    io_service_t service;      // retained
    uint32_t vendorID;
    uint32_t productID;
    uint32_t serialNumber;
    bool hasAttributes;
} GLAVCandidate;

static CFTypeRef GLCopyProperty(io_registry_entry_t entry, CFStringRef key) {
    return IORegistryEntryCreateCFProperty(entry, key, kCFAllocatorDefault, kNilOptions);
}

static uint32_t GLNumberFromDict(CFDictionaryRef dict, CFStringRef key) {
    if (dict == NULL) return 0;
    CFTypeRef value = CFDictionaryGetValue(dict, key);
    if (value == NULL || CFGetTypeID(value) != CFNumberGetTypeID()) return 0;
    uint32_t out = 0;
    CFNumberGetValue((CFNumberRef)value, kCFNumberSInt32Type, &out);
    return out;
}

/// Depth-first walk collecting external AV service candidates in registry order.
static void GLCollectAVCandidates(io_registry_entry_t entry,
                                  GLAVCandidate *pending,
                                  GLAVCandidate *out,
                                  int *outCount,
                                  int maxOut) {
    if (*outCount >= maxOut) return;

    io_name_t className = {0};
    if (IOObjectGetClass(entry, className) == KERN_SUCCESS) {
        // Framebuffer node: remember the panel identity for the branch.
        if (strcmp(className, "AppleCLCD2") == 0 ||
            strcmp(className, "IOMobileFramebufferShim") == 0) {
            CFDictionaryRef attrs = (CFDictionaryRef)GLCopyProperty(entry, CFSTR("DisplayAttributes"));
            if (attrs && CFGetTypeID(attrs) == CFDictionaryGetTypeID()) {
                CFDictionaryRef product = CFDictionaryGetValue(attrs, CFSTR("ProductAttributes"));
                if (product && CFGetTypeID(product) == CFDictionaryGetTypeID()) {
                    uint32_t vendor = GLNumberFromDict(product, CFSTR("ManufacturerID"));
                    if (vendor == 0) vendor = GLNumberFromDict(product, CFSTR("LegacyManufacturerID"));
                    pending->vendorID     = vendor;
                    pending->productID    = GLNumberFromDict(product, CFSTR("ProductID"));
                    pending->serialNumber = GLNumberFromDict(product, CFSTR("SerialNumber"));
                    pending->hasAttributes = true;
                }
            }
            if (attrs) CFRelease(attrs);
        }

        // I2C endpoint.
        if (strcmp(className, "DCPAVServiceProxy") == 0) {
            CFStringRef location = (CFStringRef)GLCopyProperty(entry, CFSTR("Location"));
            BOOL external = (location != NULL &&
                             CFGetTypeID(location) == CFStringGetTypeID() &&
                             CFStringCompare(location, CFSTR("External"), 0) == kCFCompareEqualTo);
            if (location) CFRelease(location);

            if (external) {
                GLAVCandidate candidate = *pending;
                candidate.service = entry;
                IOObjectRetain(entry);
                out[*outCount] = candidate;
                *outCount += 1;
                memset(pending, 0, sizeof(*pending));
                if (*outCount >= maxOut) return;
            }
        }
    }

    io_iterator_t children = IO_OBJECT_NULL;
    if (IORegistryEntryGetChildIterator(entry, kIOServicePlane, &children) == KERN_SUCCESS) {
        io_registry_entry_t child = IO_OBJECT_NULL;
        while ((child = IOIteratorNext(children)) != IO_OBJECT_NULL) {
            GLCollectAVCandidates(child, pending, out, outCount, maxOut);
            IOObjectRelease(child);
            if (*outCount >= maxOut) break;
        }
        IOObjectRelease(children);
    }
}

// ---------------------------------------------------------------------------
// MARK: - Intel: IOFramebuffer lookup
// ---------------------------------------------------------------------------

static io_service_t GLCopyFramebufferForDisplay(CGDirectDisplayID displayID) {
    io_iterator_t iterator = IO_OBJECT_NULL;
    if (IOServiceGetMatchingServices(kIOMainPortDefault,
                                     IOServiceMatching("IOFramebuffer"),
                                     &iterator) != KERN_SUCCESS) {
        return IO_OBJECT_NULL;
    }

    uint32_t wantVendor = CGDisplayVendorNumber(displayID);
    uint32_t wantModel  = CGDisplayModelNumber(displayID);
    uint32_t wantSerial = CGDisplaySerialNumber(displayID);

    io_service_t result = IO_OBJECT_NULL;
    io_service_t candidate = IO_OBJECT_NULL;
    while ((candidate = IOIteratorNext(iterator)) != IO_OBJECT_NULL) {
        CFDictionaryRef info = IODisplayCreateInfoDictionary(candidate, kIODisplayOnlyPreferredName);
        if (info == NULL) { IOObjectRelease(candidate); continue; }

        uint32_t vendor = GLNumberFromDict(info, CFSTR(kDisplayVendorID));
        uint32_t product = GLNumberFromDict(info, CFSTR(kDisplayProductID));
        uint32_t serial = GLNumberFromDict(info, CFSTR(kDisplaySerialNumber));
        CFRelease(info);

        if (vendor == wantVendor && product == wantModel &&
            (wantSerial == 0 || serial == wantSerial)) {
            result = candidate;   // ownership out
            break;
        }
        IOObjectRelease(candidate);
    }
    IOObjectRelease(iterator);
    return result;
}

// ---------------------------------------------------------------------------
// MARK: - GLDDCLink
// ---------------------------------------------------------------------------

@interface GLDDCLink ()
- (nullable instancetype)initCommonWithDisplay:(CGDirectDisplayID)displayID;
- (nullable instancetype)initAppleSiliconWithDisplay:(CGDirectDisplayID)displayID;
- (nullable instancetype)initIntelWithDisplay:(CGDirectDisplayID)displayID;
- (BOOL)ES_i2cSend:(const uint8_t *)message
            length:(size_t)length
             reply:(uint8_t * _Nullable)reply
       replyLength:(size_t)replyLength;
+ (void)ES_purgeCache;
@end

@implementation GLDDCLink {
    IOAVServiceRef _avService;      // arm64
    io_service_t _framebuffer;      // Intel
    pthread_mutex_t _ioLock;        // serialises I2C on this link
}

@synthesize displayID = _displayID;
@synthesize transport = _transport;
@synthesize matchStrategy = _matchStrategy;

// Cache: one link per display. DDC channel setup is expensive and monitors
// dislike being probed repeatedly.
static NSMutableDictionary<NSNumber *, GLDDCLink *> *gLinkCache;
static pthread_mutex_t gLinkCacheLock = PTHREAD_MUTEX_INITIALIZER;

+ (nullable GLDDCLink *)linkForDisplay:(CGDirectDisplayID)displayID {
    if (CGDisplayIsBuiltin(displayID)) return nil;

    pthread_mutex_lock(&gLinkCacheLock);
    if (gLinkCache == nil) gLinkCache = [NSMutableDictionary dictionary];
    GLDDCLink *cached = gLinkCache[@(displayID)];
    pthread_mutex_unlock(&gLinkCacheLock);
    if (cached != nil) return cached;

    GLDDCLink *link = nil;
    if (GLIsAppleSilicon()) {
        link = [[GLDDCLink alloc] initAppleSiliconWithDisplay:displayID];
    } else {
        link = [[GLDDCLink alloc] initIntelWithDisplay:displayID];
    }
    if (link == nil) return nil;

    pthread_mutex_lock(&gLinkCacheLock);
    gLinkCache[@(displayID)] = link;
    pthread_mutex_unlock(&gLinkCacheLock);
    return link;
}

+ (void)ES_purgeCache {
    pthread_mutex_lock(&gLinkCacheLock);
    [gLinkCache removeAllObjects];
    pthread_mutex_unlock(&gLinkCacheLock);
}

- (instancetype)initCommonWithDisplay:(CGDirectDisplayID)displayID {
    self = [super init];
    if (self) {
        _displayID = displayID;
        _matchStrategy = @"none";
        pthread_mutex_init(&_ioLock, NULL);
    }
    return self;
}

- (nullable instancetype)initAppleSiliconWithDisplay:(CGDirectDisplayID)displayID {
    const GLDDCSymbols *s = GLDDCSymbolsShared();
    if (!s->available) return nil;

    self = [self initCommonWithDisplay:displayID];
    if (self == nil) return nil;

    enum { kMaxCandidates = 16 };
    GLAVCandidate candidates[kMaxCandidates];
    memset(candidates, 0, sizeof(candidates));
    int count = 0;

    io_registry_entry_t root = IORegistryGetRootEntry(kIOMainPortDefault);
    if (root != IO_OBJECT_NULL) {
        GLAVCandidate pending;
        memset(&pending, 0, sizeof(pending));
        GLCollectAVCandidates(root, &pending, candidates, &count, kMaxCandidates);
        IOObjectRelease(root);
    }

    if (count == 0) {
        for (int i = 0; i < count; i++) {
            if (candidates[i].service) IOObjectRelease(candidates[i].service);
        }
        return nil;
    }

    uint32_t wantVendor = CGDisplayVendorNumber(displayID);
    uint32_t wantProduct = CGDisplayModelNumber(displayID);
    uint32_t wantSerial = CGDisplaySerialNumber(displayID);

    int chosen = -1;
    NSString *strategy = @"none";

    // 1) vendor + product + serial
    for (int i = 0; i < count && chosen < 0; i++) {
        if (!candidates[i].hasAttributes) continue;
        if (candidates[i].vendorID == wantVendor &&
            candidates[i].productID == wantProduct &&
            wantSerial != 0 && candidates[i].serialNumber == wantSerial) {
            chosen = i; strategy = @"edid";
        }
    }
    // 2) vendor + product
    for (int i = 0; i < count && chosen < 0; i++) {
        if (!candidates[i].hasAttributes) continue;
        if (candidates[i].vendorID == wantVendor && candidates[i].productID == wantProduct) {
            chosen = i; strategy = @"serial";
        }
    }
    // 3) positional: nth external display -> nth external AV service.
    if (chosen < 0) {
        uint32_t displayCount = 0;
        CGDirectDisplayID ids[32];
        if (CGGetOnlineDisplayList(32, ids, &displayCount) == kCGErrorSuccess) {
            int externalIndex = 0;
            for (uint32_t i = 0; i < displayCount; i++) {
                if (CGDisplayIsBuiltin(ids[i])) continue;
                if (ids[i] == displayID) break;
                externalIndex += 1;
            }
            if (externalIndex < count) {
                chosen = externalIndex;
                strategy = @"index";
            }
        }
    }

    IOAVServiceRef av = NULL;
    if (chosen >= 0 && candidates[chosen].service != IO_OBJECT_NULL) {
        av = s->createWithService(kCFAllocatorDefault, candidates[chosen].service);
    }

    for (int i = 0; i < count; i++) {
        if (candidates[i].service) IOObjectRelease(candidates[i].service);
    }

    if (av == NULL) return nil;

    _avService = av;
    _transport = GLDDCTransportKindIOAVService;
    _matchStrategy = strategy;
    return self;
}

- (nullable instancetype)initIntelWithDisplay:(CGDirectDisplayID)displayID {
    io_service_t fb = GLCopyFramebufferForDisplay(displayID);
    if (fb == IO_OBJECT_NULL) return nil;

    IOItemCount busCount = 0;
    if (IOFBGetI2CInterfaceCount(fb, &busCount) != KERN_SUCCESS || busCount == 0) {
        IOObjectRelease(fb);
        return nil;
    }

    self = [self initCommonWithDisplay:displayID];
    if (self == nil) { IOObjectRelease(fb); return nil; }

    _framebuffer = fb;
    _transport = GLDDCTransportKindIOI2C;
    _matchStrategy = @"edid";
    return self;
}

- (void)dealloc {
    if (_avService) { CFRelease(_avService); _avService = NULL; }
    if (_framebuffer != IO_OBJECT_NULL) { IOObjectRelease(_framebuffer); _framebuffer = IO_OBJECT_NULL; }
    pthread_mutex_destroy(&_ioLock);
}

// MARK: Framing

static uint8_t GLDDCChecksum(uint8_t seed, const uint8_t *bytes, size_t count) {
    uint8_t sum = seed;
    for (size_t i = 0; i < count; i++) sum ^= bytes[i];
    return sum;
}

// MARK: Write

- (BOOL)writeVCPCode:(uint8_t)code value:(uint16_t)value {
    if (_transport == GLDDCTransportKindIOAVService) {
        // [0x80|len][SetVCP][code][hi][lo][checksum]
        uint8_t packet[6];
        packet[0] = 0x80 | 4;
        packet[1] = kDDCOpSetVCP;
        packet[2] = code;
        packet[3] = (uint8_t)(value >> 8);
        packet[4] = (uint8_t)(value & 0xFF);
        packet[5] = GLDDCChecksum(kDDCDestinationAddress ^ kDDCSourceAddress, packet, 5);

        const GLDDCSymbols *s = GLDDCSymbolsShared();
        pthread_mutex_lock(&_ioLock);
        IOReturn err = s->write(_avService, kDDCChipAddress7Bit, kDDCSourceAddress,
                                packet, (uint32_t)sizeof(packet));
        usleep(kDDCWriteSettleUs);
        pthread_mutex_unlock(&_ioLock);
        return err == kIOReturnSuccess;
    }

    if (_transport == GLDDCTransportKindIOI2C) {
        uint8_t message[7];
        message[0] = kDDCSourceAddress;
        message[1] = 0x80 | 4;
        message[2] = kDDCOpSetVCP;
        message[3] = code;
        message[4] = (uint8_t)(value >> 8);
        message[5] = (uint8_t)(value & 0xFF);
        message[6] = GLDDCChecksum(kDDCDestinationAddress, message, 6);
        return [self ES_i2cSend:message length:sizeof(message) reply:NULL replyLength:0];
    }

    return NO;
}

// MARK: Read

- (BOOL)readVCPCode:(uint8_t)code
         outCurrent:(uint16_t *)outCurrent
             outMax:(uint16_t *)outMax {
    uint8_t reply[16];
    memset(reply, 0, sizeof(reply));

    if (_transport == GLDDCTransportKindIOAVService) {
        uint8_t request[4];
        request[0] = 0x80 | 2;
        request[1] = kDDCOpGetVCP;
        request[2] = code;
        request[3] = GLDDCChecksum(kDDCDestinationAddress ^ kDDCSourceAddress, request, 3);

        const GLDDCSymbols *s = GLDDCSymbolsShared();
        pthread_mutex_lock(&_ioLock);
        IOReturn err = s->write(_avService, kDDCChipAddress7Bit, kDDCSourceAddress,
                                request, (uint32_t)sizeof(request));
        if (err == kIOReturnSuccess) {
            usleep(kDDCReplyDelayUs);
            err = s->read(_avService, kDDCChipAddress7Bit, kDDCSourceAddress, reply, 12);
        }
        pthread_mutex_unlock(&_ioLock);
        if (err != kIOReturnSuccess) return NO;
    } else if (_transport == GLDDCTransportKindIOI2C) {
        uint8_t message[5];
        message[0] = kDDCSourceAddress;
        message[1] = 0x80 | 2;
        message[2] = kDDCOpGetVCP;
        message[3] = code;
        message[4] = GLDDCChecksum(kDDCDestinationAddress, message, 4);
        if (![self ES_i2cSend:message length:sizeof(message) reply:reply replyLength:12]) {
            return NO;
        }
    } else {
        return NO;
    }

    // Locate the "Get VCP Feature Reply" body rather than assuming a fixed
    // offset: transports differ in whether they hand back the address bytes.
    //   [0x02][result][code][type][maxHi][maxLo][curHi][curLo]
    for (size_t k = 0; k + 7 < sizeof(reply); k++) {
        if (reply[k] != kDDCOpGetVCPReply) continue;
        if (reply[k + 1] != 0x00) continue;          // non-zero == unsupported code
        if (reply[k + 2] != code) continue;

        uint16_t maxValue = (uint16_t)((reply[k + 4] << 8) | reply[k + 5]);
        uint16_t current  = (uint16_t)((reply[k + 6] << 8) | reply[k + 7]);
        if (maxValue == 0) continue;                 // nonsense; keep scanning
        if (current > maxValue) current = maxValue;

        if (outMax) *outMax = maxValue;
        if (outCurrent) *outCurrent = current;
        return YES;
    }
    return NO;
}

// MARK: Intel I2C

- (BOOL)ES_i2cSend:(const uint8_t *)message
            length:(size_t)length
             reply:(uint8_t * _Nullable)reply
       replyLength:(size_t)replyLength {
    if (_framebuffer == IO_OBJECT_NULL) return NO;

    IOItemCount busCount = 0;
    if (IOFBGetI2CInterfaceCount(_framebuffer, &busCount) != KERN_SUCCESS || busCount == 0) {
        return NO;
    }

    BOOL success = NO;
    pthread_mutex_lock(&_ioLock);

    for (IOOptionBits bus = 0; bus < busCount && !success; bus++) {
        io_service_t interface = IO_OBJECT_NULL;
        if (IOFBCopyI2CInterfaceForBus(_framebuffer, bus, &interface) != KERN_SUCCESS) continue;

        IOI2CConnectRef connect = NULL;
        if (IOI2CInterfaceOpen(interface, kNilOptions, &connect) == KERN_SUCCESS) {
            IOI2CRequest request;
            memset(&request, 0, sizeof(request));
            request.commFlags = 0;
            request.sendAddress = (uint32_t)(kDDCChipAddress7Bit << 1);
            request.sendTransactionType = kIOI2CSimpleTransactionType;
            request.sendBuffer = (vm_address_t)message;
            request.sendBytes = (uint32_t)length;
            request.minReplyDelay = (uint64_t)kDDCReplyDelayUs * 1000ULL;  // ns

            if (reply != NULL && replyLength > 0) {
                request.replyAddress = (uint32_t)((kDDCChipAddress7Bit << 1) | 1);
                request.replyTransactionType = kIOI2CDDCciReplyTransactionType;
                request.replyBuffer = (vm_address_t)reply;
                request.replyBytes = (uint32_t)replyLength;
            }

            if (IOI2CSendRequest(connect, kNilOptions, &request) == KERN_SUCCESS &&
                request.result == KERN_SUCCESS) {
                success = YES;
            }
            IOI2CInterfaceClose(connect, kNilOptions);
        }
        IOObjectRelease(interface);
    }

    if (success && reply == NULL) usleep(kDDCWriteSettleUs);
    pthread_mutex_unlock(&_ioLock);
    return success;
}

@end

// ---------------------------------------------------------------------------
// MARK: - GLDDCBridge
// ---------------------------------------------------------------------------

@implementation GLDDCBridge

+ (BOOL)isAvailable {
    if (GLIsAppleSilicon()) return GLDDCSymbolsShared()->available;
    return YES;   // Intel path needs no private symbols.
}

+ (GLDDCTransportKind)transportKind {
    if (GLIsAppleSilicon()) {
        return GLDDCSymbolsShared()->available ? GLDDCTransportKindIOAVService
                                               : GLDDCTransportKindNone;
    }
    return GLDDCTransportKindIOI2C;
}

+ (NSString *)diagnosticsDescription {
    const GLDDCSymbols *s = GLDDCSymbolsShared();
    NSMutableString *out = [NSMutableString string];
    [out appendString:@"DDC/CI bridge\n"];
    [out appendFormat:@"  architecture     : %@\n", GLIsAppleSilicon() ? @"arm64 (IOAVService)" : @"x86_64 (IOI2C)"];
    [out appendFormat:@"  IOAVService      : create=%d write=%d read=%d\n",
     s->createWithService != NULL, s->write != NULL, s->read != NULL];
    if (s->failure[0] != '\0') {
        [out appendFormat:@"  failure          : %s\n", s->failure];
    }
    return out;
}

+ (void)invalidateAllLinks {
    [GLDDCLink ES_purgeCache];
}

@end
