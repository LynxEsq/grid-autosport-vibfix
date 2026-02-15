// stop_rumble — sends zero rumble to Xbox controller and exits
// Used as cleanup after game process terminates

#import <Foundation/Foundation.h>
#include <IOKit/hid/IOHIDManager.h>
#include <IOKit/hid/IOHIDDevice.h>
#include <stdio.h>
#include <unistd.h>

#define XBOX_VENDOR_ID 0x045E
static const uint16_t XBOX_PIDS[] = {0x0B22, 0x0B05, 0x0B20, 0x0B13, 0x02FD, 0x0B21, 0};

int main(void) {
    IOHIDManagerRef mgr = IOHIDManagerCreate(kCFAllocatorDefault, kIOHIDOptionsTypeNone);
    if (!mgr) return 1;

    IOHIDManagerSetDeviceMatchingMultiple(mgr, NULL); // match all
    IOHIDManagerOpen(mgr, kIOHIDOptionsTypeNone);

    CFSetRef devices = IOHIDManagerCopyDevices(mgr);
    if (!devices) { CFRelease(mgr); return 1; }

    CFIndex count = CFSetGetCount(devices);
    CFTypeRef *devs = malloc(count * sizeof(CFTypeRef));
    CFSetGetValues(devices, devs);

    uint8_t zero[9] = {0x03, 0x0F, 0, 0, 0, 0, 0xFF, 0x00, 0xEB};

    for (CFIndex i = 0; i < count; i++) {
        IOHIDDeviceRef dev = (IOHIDDeviceRef)devs[i];
        uint16_t vid = 0, pid = 0;
        CFNumberRef v = IOHIDDeviceGetProperty(dev, CFSTR(kIOHIDVendorIDKey));
        CFNumberRef p = IOHIDDeviceGetProperty(dev, CFSTR(kIOHIDProductIDKey));
        if (v) CFNumberGetValue(v, kCFNumberSInt16Type, &vid);
        if (p) CFNumberGetValue(p, kCFNumberSInt16Type, &pid);

        if (vid == XBOX_VENDOR_ID) {
            for (int j = 0; XBOX_PIDS[j]; j++) {
                if (pid == XBOX_PIDS[j]) {
                    IOHIDDeviceSetReport(dev, kIOHIDReportTypeOutput, 0x03, zero, sizeof(zero));
                    usleep(50000);
                    IOHIDDeviceSetReport(dev, kIOHIDReportTypeOutput, 0x03, zero, sizeof(zero));
                    printf("Stopped rumble on %04X:%04X\n", vid, pid);
                    break;
                }
            }
        }
    }

    free(devs);
    CFRelease(devices);
    CFRelease(mgr);
    return 0;
}
