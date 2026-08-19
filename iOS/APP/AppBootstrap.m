
#import <UIKit/UIKit.h>

extern bool KrkrIsLandscapeLocked(void);

@interface SDLUIKitDelegate : NSObject
@end
@interface SDLUIKitDelegate (KrKrCatOrientation)
@end
@implementation SDLUIKitDelegate (KrKrCatOrientation)
- (UIInterfaceOrientationMask)application:(UIApplication *)application
    supportedInterfaceOrientationsForWindow:(UIWindow *)window
{
    return KrkrIsLandscapeLocked() ? UIInterfaceOrientationMaskLandscape
                                   : UIInterfaceOrientationMaskAll;
}
@end
