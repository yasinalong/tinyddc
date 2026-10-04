/* tinyddc — an on-demand Apple Silicon display input CLI.
 * SPDX-License-Identifier: MIT
 * IOAVService signatures, registry keys and DDC conventions are adapted from
 * waydabber/m1ddc, AppleSiliconDDC and MonitorControl
 * (see THIRD_PARTY_NOTICES.md). */
#import <Foundation/Foundation.h>
#import <CoreGraphics/CoreGraphics.h>
#import <IOKit/IOKitLib.h>
#include <dlfcn.h>
#include <ctype.h>
#include <errno.h>
#include <limits.h>
#include <unistd.h>
#include "ddc_packet.h"

#if !defined(__arm64__)
#error "tinyddc supports native Apple Silicon (arm64) builds only"
#endif

/* Private Apple APIs: signatures verified against the upstream headers. */
typedef CFTypeRef IOAVServiceRef;
typedef IOAVServiceRef (*AVCreate)(CFAllocatorRef, io_service_t);
typedef IOReturn (*AVI2C)(IOAVServiceRef, uint32_t, uint32_t, void *, uint32_t);
typedef CFDictionaryRef (*DisplayInfo)(CGDirectDisplayID);
static AVCreate av_create;
static AVI2C av_read, av_write;
static DisplayInfo display_info;

@interface Display : NSObject
@property CGDirectDisplayID displayID;
@property (copy) NSString *uuid;
@property (copy) NSString *name;
@property (copy) NSString *serial;
@property (copy) NSString *location;
@property io_service_t proxy;
@property uint32_t chipAddress;
@property (copy) NSString *status;
@end
@implementation Display
- (void)dealloc { if (_proxy) IOObjectRelease(_proxy); }
@end

static void usage(FILE *out) {
    fprintf(out,
        "tinyddc 0.1.0 — on-demand DDC input switching for Apple Silicon\n"
        "Usage:\n"
        "  tinyddc list [--json]\n"
        "  tinyddc input VALUE (--display UUID | --index N) [--dry-run]\n"
        "  tinyddc get-input (--display UUID | --index N)\n"
        "VALUE: dp=15, dp2=16, hdmi1=17, hdmi2=18, usbc=27, or 1..65535\n"
        "Numbers may use decimal or 0x hexadecimal. No default display.\n"
        "list and --dry-run do not send any DDC commands.\n");
}

static int fail(int code, NSString *message) {
    fprintf(stderr, "tinyddc: %s\n", message.UTF8String);
    return code;
}

static bool number(NSString *text, unsigned long max, unsigned long *result) {
    const char *s = text.UTF8String;
    if (!s || !*s || *s == '+' || *s == '-' || isspace((unsigned char)*s)) return false;
    int base = (strlen(s) > 2 && s[0] == '0' && (s[1] == 'x' || s[1] == 'X')) ? 16 : 10;
    char *end = NULL;
    errno = 0;
    unsigned long value = strtoul(s, &end, base);
    if (errno || end == s || *end || value == 0 || value > max) return false;
    *result = value;
    return true;
}

static bool input_value(NSString *text, uint16_t *result) {
    NSDictionary *aliases = @{ @"dp": @15, @"dp2": @16, @"hdmi1": @17,
                              @"hdmi2": @18, @"usbc": @27 };
    NSNumber *alias = aliases[text.lowercaseString];
    unsigned long value;
    if (alias) value = alias.unsignedLongValue;
    else if (!number(text, UINT16_MAX, &value)) return false;
    *result = (uint16_t)value;
    return true;
}

static void load_api(void) {
    /* Keep framework handles for the short process lifetime. */
    void *io = dlopen("/System/Library/Frameworks/IOKit.framework/IOKit", RTLD_LAZY | RTLD_LOCAL);
    void *core = dlopen("/System/Library/Frameworks/CoreDisplay.framework/CoreDisplay", RTLD_LAZY | RTLD_LOCAL);
    if (io) {
        av_create = (AVCreate)dlsym(io, "IOAVServiceCreateWithService");
        av_read = (AVI2C)dlsym(io, "IOAVServiceReadI2C");
        av_write = (AVI2C)dlsym(io, "IOAVServiceWriteI2C");
    }
    if (core) display_info = (DisplayInfo)dlsym(core, "CoreDisplay_DisplayCreateInfoDictionary");
}

static id property(io_registry_entry_t entry, CFStringRef key, bool recursive) {
    CFTypeRef value = recursive
        ? IORegistryEntrySearchCFProperty(entry, kIOServicePlane, key, kCFAllocatorDefault,
                                         kIORegistryIterateRecursively)
        : IORegistryEntryCreateCFProperty(entry, key, kCFAllocatorDefault, 0);
    return CFBridgingRelease(value);
}

static NSString *string_value(id value) {
    return [value isKindOfClass:NSString.class] ? value : nil;
}

/* Apple's DCP proxy is not necessarily a framebuffer descendant. Follow the
 * mature upstream root-iterator convention: a proxy belongs to the preceding
 * IOMobileFramebuffer. Match that framebuffer by registry ID from the selected
 * CoreDisplay location; require exactly one external proxy in its segment. */
static void map_transport(Display *display, io_service_t framebuffer) {
    display.chipAddress = 0x37;
    display.status = @"unavailable: no unique DCP transport";
    if (!IOObjectConformsTo(framebuffer, "IOMobileFramebuffer")) return;
    uint64_t selectedID = 0;
    if (IORegistryEntryGetRegistryEntryID(framebuffer, &selectedID) != KERN_SUCCESS) return;
    io_registry_entry_t root = IORegistryGetRootEntry(kIOMainPortDefault);
    if (!root) return;
    io_iterator_t iterator = IO_OBJECT_NULL;
    if (IORegistryEntryCreateIterator(root, kIOServicePlane,
                                     kIORegistryIterateRecursively, &iterator) != KERN_SUCCESS) {
        IOObjectRelease(root);
        return;
    }
    IOObjectRelease(root);
    bool matches = false;
    unsigned proxies = 0;
    io_service_t entry, candidate = IO_OBJECT_NULL;
    while ((entry = IOIteratorNext(iterator))) {
        if (IOObjectConformsTo(entry, "IOMobileFramebuffer")) {
            uint64_t entryID = 0;
            matches = IORegistryEntryGetRegistryEntryID(entry, &entryID) == KERN_SUCCESS && entryID == selectedID;
        }
        io_name_t name = {0};
        if (matches && IORegistryEntryGetName(entry, name) == KERN_SUCCESS &&
            strcmp(name, "DCPAVServiceProxy") == 0 &&
            [string_value(property(entry, CFSTR("Location"), true)) isEqualToString:@"External"]) {
            ++proxies;
            if (!candidate) { IOObjectRetain(entry); candidate = entry; }
        }
        IOObjectRelease(entry);
    }
    bool valid = IOIteratorIsValid(iterator);
    IOObjectRelease(iterator);
    if (!valid || proxies != 1) {
        if (candidate) IOObjectRelease(candidate);
        return;
    }
    display.proxy = candidate;
    io_registry_entry_t provider = IO_OBJECT_NULL;
    if (IORegistryEntryGetParentEntry(candidate, kIOServicePlane, &provider) == KERN_SUCCESS) {
        if ([string_value(property(provider, CFSTR("EPICProviderClass"), false))
                isEqualToString:@"AppleDCPMCDP29XX"]) display.chipAddress = 0xb7;
        IOObjectRelease(provider);
    }
    display.status = av_create && av_write && av_read
        ? @"available (DDC response untested)" : @"unavailable: private IOAVService API missing";
}

static NSArray<Display *> *displays(NSString **error) {
    CGDisplayCount count = 0;
    if (CGGetOnlineDisplayList(0, NULL, &count) != kCGErrorSuccess) {
        *error = @"cannot enumerate online displays";
        return nil;
    }
    if (count == 0) return @[];
    CGDirectDisplayID *ids = calloc(count, sizeof(*ids));
    if (!ids) { *error = @"out of memory"; return nil; }
    if (CGGetOnlineDisplayList(count, ids, &count) != kCGErrorSuccess) {
        free(ids); *error = @"display list changed; retry"; return nil;
    }
    NSMutableArray *result = [NSMutableArray array];
    for (CGDisplayCount i = 0; i < count; ++i) {
        if (CGDisplayIsBuiltin(ids[i])) continue;
        Display *display = [Display new];
        display.displayID = ids[i];
        display.status = @"unavailable: framebuffer information missing";
        display.name = [NSString stringWithFormat:@"External display (vendor %u, model %u)",
                        CGDisplayVendorNumber(ids[i]), CGDisplayModelNumber(ids[i])];
        NSDictionary *info = display_info ? CFBridgingRelease(display_info(ids[i])) : nil;
        if ([info isKindOfClass:NSDictionary.class]) {
            display.uuid = string_value(info[@"kCGDisplayUUID"]);
            display.location = string_value(info[@"IODisplayLocation"]);
            NSDictionary *names = info[@"DisplayProductName"];
            if ([names isKindOfClass:NSDictionary.class])
                display.name = string_value(names[@"en_US"]) ?: string_value(names.allValues.firstObject) ?: display.name;
        }
        io_service_t framebuffer = display.location
            ? IORegistryEntryCopyFromPath(kIOMainPortDefault, (__bridge CFStringRef)display.location) : IO_OBJECT_NULL;
        if (framebuffer) {
            NSDictionary *attributes = property(framebuffer, CFSTR("DisplayAttributes"), true);
            if ([attributes isKindOfClass:NSDictionary.class]) {
                NSDictionary *product = attributes[@"ProductAttributes"];
                if ([product isKindOfClass:NSDictionary.class]) {
                    display.name = string_value(product[@"ProductName"]) ?: display.name;
                    display.serial = string_value(product[@"AlphanumericSerialNumber"]);
                }
            }
            map_transport(display, framebuffer);
            IOObjectRelease(framebuffer);
        }
        [result addObject:display];
    }
    free(ids);
    return result;
}

static int list_displays(NSArray<Display *> *items, bool json) {
    if (json) {
        NSMutableArray *rows = [NSMutableArray array];
        NSUInteger index = 0;
        for (Display *display in items) {
            [rows addObject:@{ @"index": @(++index), @"uuid": display.uuid ?: NSNull.null,
                               @"name": display.name, @"serial": display.serial ?: NSNull.null,
                               @"transport": display.status }];
        }
        NSData *data = [NSJSONSerialization dataWithJSONObject:rows options:NSJSONWritingPrettyPrinted error:nil];
        if (!data) return fail(1, @"cannot encode display list");
        fwrite(data.bytes, 1, data.length, stdout);
        putchar('\n');
    } else {
        if (!items.count) puts("No online external displays.");
        NSUInteger index = 0;
        for (Display *display in items) {
            printf("%lu  %s\n   UUID: %s\n   Transport: %s\n", (unsigned long)++index,
                   display.name.UTF8String, (display.uuid ?: @"unavailable").UTF8String,
                   display.status.UTF8String);
        }
    }
    return 0;
}

static int communicate(Display *display, bool get, uint16_t value) {
    if (!display.proxy || !av_create || !av_write || (get && !av_read))
        return fail(1, display.status);
    IOAVServiceRef service = av_create(kCFAllocatorDefault, display.proxy);
    if (!service) return fail(1, @"IOAVService refused the selected transport");
    IOReturn status = kIOReturnSuccess;
    if (get) {
        bool valid = false;
        uint16_t current = 0, maximum = 0;
        /* Get VCP writes a query but never sends a Set VCP command. */
        for (unsigned attempt = 0; attempt < 3 && !valid; ++attempt) {
            uint8_t request[4], reply[11] = {0};
            ddc_get_input_packet(request);
            for (unsigned cycle = 0; cycle < 2; ++cycle) {
                usleep(10000);
                status = av_write(service, display.chipAddress, DDC_DATA_ADDRESS, request, sizeof(request));
                if (status != kIOReturnSuccess) break;
            }
            if (status == kIOReturnSuccess) {
                usleep(50000);
                /* Read has no source-address prefix; use offset 0 as in
                 * MonitorControl's current IOAVService implementation. */
                status = av_read(service, display.chipAddress, 0, reply, sizeof(reply));
                valid = status == kIOReturnSuccess && ddc_parse_input_reply(reply, sizeof(reply), &current, &maximum);
            }
            if (!valid && attempt < 2) usleep(20000);
        }
        CFRelease(service);
        if (!valid) return fail(1, [NSString stringWithFormat:
            @"no valid VCP 0x60 reply (IOKit 0x%08x); check DDC/CI and adapter support", (unsigned)status]);
        printf("input=%u (0x%04x), maximum=%u\n", current, current, maximum);
    } else {
        uint8_t packet[6];
        ddc_set_input_packet(value, packet);
        /* Mature IOAVService implementations repeat writes for compatibility.
         * A success is only transport acceptance; input switching can sever DDC. */
        for (unsigned cycle = 0; cycle < 2; ++cycle) {
            usleep(10000);
            status = av_write(service, display.chipAddress, DDC_DATA_ADDRESS, packet, sizeof(packet));
            if (status != kIOReturnSuccess) break;
        }
        CFRelease(service);
        if (status != kIOReturnSuccess) return fail(1, [NSString stringWithFormat:
            @"DDC write returned IOKit 0x%08x; a preceding write may already have switched input", (unsigned)status]);
        printf("Sent VCP 0x60=%u to %s. Transport accepted; monitor switch is not verified.\n",
               value, display.name.UTF8String);
    }
    return 0;
}

int main(int argc, const char *argv[]) {
    @autoreleasepool {
        if (argc == 1 || (argc == 2 && (!strcmp(argv[1], "--help") || !strcmp(argv[1], "-h")))) {
            usage(stdout); return 0;
        }
        if (argc == 2 && !strcmp(argv[1], "--version")) { puts("tinyddc 0.1.0"); return 0; }
        NSString *command = @(argv[1]);
        bool list = [command isEqualToString:@"list"], get = [command isEqualToString:@"get-input"];
        if (!list && !get && ![command isEqualToString:@"input"]) {
            usage(stderr); return fail(2, @"unknown command");
        }
        NSString *uuid = nil, *valueText = nil;
        unsigned long index = 0;
        bool json = false, dry = false;
        for (int i = 2; i < argc; ++i) {
            NSString *arg = @(argv[i]);
            if ([arg isEqualToString:@"--display"] || [arg isEqualToString:@"--index"]) {
                if (list || uuid || index || ++i >= argc) return fail(2, @"specify exactly one display selector");
                if ([arg isEqualToString:@"--display"]) {
                    NSUUID *parsed = [[NSUUID alloc] initWithUUIDString:@(argv[i])];
                    if (!parsed) return fail(2, @"invalid display UUID");
                    uuid = parsed.UUIDString;
                } else if (!number(@(argv[i]), UINT_MAX, &index)) return fail(2, @"invalid display index");
            } else if ([arg isEqualToString:@"--json"] && list && !json) json = true;
            else if ([arg isEqualToString:@"--dry-run"] && !list && !get && !dry) dry = true;
            else if (!list && !get && !valueText && ![arg hasPrefix:@"--"]) valueText = arg;
            else return fail(2, [NSString stringWithFormat:@"unexpected argument: %@", arg]);
        }
        uint16_t value = 0;
        if (!list && !uuid && !index) return fail(2, @"--display UUID or --index N is required; run list first");
        if (!list && !get && (!valueText || !input_value(valueText, &value))) return fail(2, @"invalid input value");
        load_api();
        NSString *error = nil;
        NSArray<Display *> *items = displays(&error);
        if (!items) return fail(1, error);
        if (list) return list_displays(items, json);
        Display *selected = nil;
        if (index) {
            if (index <= items.count) selected = items[index - 1];
        } else {
            for (Display *display in items) {
                if (display.uuid && [display.uuid caseInsensitiveCompare:uuid] == NSOrderedSame) {
                    if (selected) return fail(1, @"UUID matches multiple displays; use an explicit index");
                    selected = display;
                }
            }
        }
        if (!selected) return fail(1, @"selected external display is not online; run list again");
        if (dry) {
            uint8_t packet[6]; ddc_set_input_packet(value, packet);
            printf("Dry run: %s, UUID %s, VCP 0x60=%u\nPacket (data address 0x51):",
                   selected.name.UTF8String, (selected.uuid ?: @"unavailable").UTF8String, value);
            for (size_t i = 0; i < sizeof(packet); ++i) printf(" %02x", packet[i]);
            printf("\nTransport: %s\nNo DDC command sent.\n", selected.status.UTF8String);
            return 0;
        }
        return communicate(selected, get, value);
    }
}
