
#import <Foundation/Foundation.h>

#if defined(__has_attribute)
#if __has_attribute(weak)
#define SDKCOMPAT_WEAK __attribute__((weak))
#else
#define SDKCOMPAT_WEAK
#endif
#endif

SDKCOMPAT_WEAK int __isPlatformVersionAtLeast(unsigned platform, unsigned major,
                                              unsigned minor, unsigned sub)
{
    if (platform != 2 && platform != 1)
        return 0;
    static int cachedVersion = -1;
    if (cachedVersion < 0)
    {
        NSOperatingSystemVersion v = [NSProcessInfo processInfo].operatingSystemVersion;
        cachedVersion = (int)(v.majorVersion * 10000 + v.minorVersion * 100 + v.patchVersion);
    }
    int target = (int)(major * 10000 + minor * 100 + sub);
    return cachedVersion >= target;
}

#if __has_include(<GameController/GCEventInteraction.h>)

#else
@interface GCEventInteraction : NSObject
@end
@implementation GCEventInteraction
@end
#endif
