#ifndef PARAAIR_FINDER_SIDEBAR_BRIDGE_H
#define PARAAIR_FINDER_SIDEBAR_BRIDGE_H

#include <CoreServices/CoreServices.h>
#include <Security/SecTask.h>
#include <stdbool.h>

// kLSSharedFileListItemLast is a virtual reference (0x2), not a CF object.
// Passing it through Swift's takeUnretainedValue triggers objc_retain and
// crashes. Keep the sentinel in C; release only the real inserted item.
static inline bool ParaAirFinderIconDataIsSupported(CFDataRef data) {
    IconRef icon = NULL;
    if (data == NULL || CFDataGetLength(data) < 16 || CFDataGetLength(data) > 1048576) return false;
    OSStatus status = GetIconRefFromIconFamilyPtr(
        (const IconFamilyResource *)CFDataGetBytePtr(data), (Size)CFDataGetLength(data), &icon);
    if (icon != NULL) ReleaseIconRef(icon);
    return status == noErr;
}

static inline bool ParaAirInsertFinderFavorite(LSSharedFileListRef list, CFURLRef url,
                                               CFStringRef name, CFDataRef data, UInt32 *itemID) {
    IconRef icon = NULL;
    if (data != NULL && CFDataGetLength(data) >= 16 && CFDataGetLength(data) <= 1048576) {
        GetIconRefFromIconFamilyPtr((const IconFamilyResource *)CFDataGetBytePtr(data),
                                   (Size)CFDataGetLength(data), &icon);
    }
    LSSharedFileListItemRef item = LSSharedFileListInsertItemURL(
        list, kLSSharedFileListItemLast, name, icon, url, NULL, NULL);
    if (icon != NULL) ReleaseIconRef(icon);
    if (item == NULL) return false;
    if (itemID != NULL) *itemID = LSSharedFileListItemGetID(item);
    CFRelease(item);
    return true;
}

// A provisioned build uses the native mount route only when its live signature
// grants the capability. The existing signed development app keeps its helper.
static inline bool ParaAirHasNativeMountEntitlement(void) {
    SecTaskRef task = SecTaskCreateFromSelf(NULL);
    if (task == NULL) return false;
    CFTypeRef value = SecTaskCopyValueForEntitlement(task, CFSTR("com.apple.developer.fskit.mount"), NULL);
    bool allowed = value != NULL && CFGetTypeID(value) == CFBooleanGetTypeID() && CFBooleanGetValue(value);
    if (value != NULL) CFRelease(value);
    CFRelease(task);
    return allowed;
}

#endif
