#import <UIKit/UIKit.h>

// SECUTG-HOOK (scene lifecycle): windows created with -initWithFrame: are not attached to any scene under the
// UIScene lifecycle and never appear. App windows (legacy overlay / progress windows) get the app's window scene
// right after init, when one is connected.
@interface UIWindow (SceneAttach)

+ (UIWindowScene * _Nullable)secutgCurrentWindowScene;

@end
