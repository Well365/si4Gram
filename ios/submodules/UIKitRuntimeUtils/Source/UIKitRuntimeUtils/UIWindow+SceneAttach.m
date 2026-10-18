#import "UIWindow+SceneAttach.h"

#import <ObjCRuntimeUtils/RuntimeUtils.h>

@implementation UIWindow (SceneAttach)

+ (void)load {
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        [RuntimeUtils swizzleInstanceMethodOfClass:[UIWindow class] currentSelector:@selector(initWithFrame:) newSelector:@selector(_5e3c1a7d_initWithFrame:)];
    });
}

+ (UIWindowScene * _Nullable)secutgCurrentWindowScene {
    UIWindowScene *fallback = nil;
    for (UIScene *scene in [UIApplication sharedApplication].connectedScenes) {
        if (![scene isKindOfClass:[UIWindowScene class]]) {
            continue;
        }
        if (scene.activationState == UISceneActivationStateForegroundActive) {
            return (UIWindowScene *)scene;
        }
        if (fallback == nil) {
            fallback = (UIWindowScene *)scene;
        }
    }
    return fallback;
}

static bool isSystemWindowClass(Class windowClass) {
    NSString *name = NSStringFromClass(windowClass);
    return [name hasPrefix:@"_"] || [name hasPrefix:@"UI"];
}

- (instancetype)_5e3c1a7d_initWithFrame:(CGRect)frame {
    UIWindow *window = [self _5e3c1a7d_initWithFrame:frame];
    if (window != nil && window.windowScene == nil && !isSystemWindowClass([window class])) {
        UIWindowScene *scene = [UIWindow secutgCurrentWindowScene];
        if (scene != nil) {
            window.windowScene = scene;
        }
    }
    return window;
}

@end
