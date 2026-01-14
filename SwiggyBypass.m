#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>
#import <objc/runtime.h>
#include <sys/sysctl.h>

// --- Preferences Keys ---
#define kSpoofedUDID @"kSpoofedUDID"
#define kSpoofedSerial @"kSpoofedSerial"
#define kSpoofedIDFV @"kSpoofedIDFV"
#define kSpoofedIDFA @"kSpoofedIDFA"

// --- Helper Functions ---

static NSString *GenerateRandomUUID() {
    return [[NSUUID UUID] UUIDString];
}

static NSString *GenerateRandomSerial() {
    NSString *alphabet = @"ABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789";
    NSMutableString *serial = [NSMutableString stringWithCapacity:12];
    for (int i = 0; i < 12; i++) {
        u_int32_t r = arc4random_uniform((u_int32_t)[alphabet length]);
        [serial appendFormat:@"%C", [alphabet characterAtIndex:r]];
    }
    return serial;
}

static void RotateIDs() {
    NSUserDefaults *defaults = [NSUserDefaults standardUserDefaults];
    [defaults setObject:GenerateRandomUUID() forKey:kSpoofedUDID];
    [defaults setObject:GenerateRandomSerial() forKey:kSpoofedSerial];
    [defaults setObject:GenerateRandomUUID() forKey:kSpoofedIDFV];
    [defaults setObject:GenerateRandomUUID() forKey:kSpoofedIDFA];
    [defaults synchronize];
}

static void EnsureIDsExist() {
    NSUserDefaults *defaults = [NSUserDefaults standardUserDefaults];
    if (![defaults stringForKey:kSpoofedUDID]) {
        RotateIDs();
    }
}

// --- Hooks ---

@interface UIDevice (Swizzle)
@end

@implementation UIDevice (Swizzle)

+ (void)load {
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        Class class = [self class];
        Method originalMethod = class_getInstanceMethod(class, @selector(identifierForVendor));
        Method swizzledMethod = class_getInstanceMethod(class, @selector(swizzled_identifierForVendor));
        method_exchangeImplementations(originalMethod, swizzledMethod);
    });
}

- (NSUUID *)swizzled_identifierForVendor {
    // EnsureIDsExist(); // Call this here to be safe
    NSString *uuidString = [[NSUserDefaults standardUserDefaults] stringForKey:kSpoofedIDFV];
    if (!uuidString) {
        RotateIDs(); 
        uuidString = [[NSUserDefaults standardUserDefaults] stringForKey:kSpoofedIDFV];
    }
    return [[NSUUID alloc] initWithUUIDString:uuidString];
}

@end

// --- UI / Interaction ---

@interface SwiggyBypassController : NSObject
@end

@implementation SwiggyBypassController

+ (instancetype)sharedInstance {
    static SwiggyBypassController *sharedInstance = nil;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        sharedInstance = [[SwiggyBypassController alloc] init];
    });
    return sharedInstance;
}

- (void)presentAlert:(NSString *)title message:(NSString *)message {
    dispatch_async(dispatch_get_main_queue(), ^{
        UIWindow *window = [self findActiveWindow];
        if (!window) return;

        UIViewController *topController = window.rootViewController;
        while (topController.presentedViewController) {
            topController = topController.presentedViewController;
        }
        
        UIAlertController *alert = [UIAlertController alertControllerWithTitle:title
                                                                       message:message
                                                                preferredStyle:UIAlertControllerStyleAlert];
        [alert addAction:[UIAlertAction actionWithTitle:@"OK" style:UIAlertActionStyleDefault handler:nil]];
        [topController presentViewController:alert animated:YES completion:nil];
    });
}

- (UIWindow *)findActiveWindow {
    // Try Modern Scenes (iOS 13+)
    for (UIScene *scene in [UIApplication sharedApplication].connectedScenes) {
        if (scene.activationState == UISceneActivationStateForegroundActive && [scene isKindOfClass:[UIWindowScene class]]) {
            for (UIWindow *window in ((UIWindowScene *)scene).windows) {
                if (window.isKeyWindow) return window;
            }
        }
    }
    
    // Fallback
    return [UIApplication sharedApplication].windows.firstObject;
}

- (void)rotateTapped {
    RotateIDs();
    [self presentAlert:@"Success" message:@"New Device IDs Generated.\nPlease RESTART the app now."];
}

- (void)setupFloatingButton {
    UIWindow *window = [self findActiveWindow];
    if (!window) {
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(1.0 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
            [self setupFloatingButton];
        });
        return;
    }
    
    // Check if duplicate
    for (UIView *subview in window.subviews) {
        if (subview.tag == 9999) return;
    }

    // Larger, high contrast button
    UIButton *btn = [UIButton buttonWithType:UIButtonTypeSystem];
    btn.frame = CGRectMake(20, 150, 140, 50);
    btn.backgroundColor = [UIColor redColor];
    [btn setTitle:@"ROTATE ID" forState:UIControlStateNormal];
    [btn setTitleColor:[UIColor whiteColor] forState:UIControlStateNormal];
    btn.titleLabel.font = [UIFont boldSystemFontOfSize:18];
    btn.layer.cornerRadius = 25;
    btn.layer.borderColor = [UIColor whiteColor].CGColor;
    btn.layer.borderWidth = 3;
    btn.layer.zPosition = 9999;
    btn.tag = 9999;
    
    [btn addTarget:self action:@selector(rotateTapped) forControlEvents:UIControlEventTouchUpInside];
    
    [window addSubview:btn];
    [window bringSubviewToFront:btn];
    
    // Also present initial alert
    [self presentAlert:@"Bypass Active" message:@"Shake device or Tap button to rotate ID."];
}

@end


// --- Shake Gesture Hook ---

@implementation UIWindow (ShakeListen)

- (void)motionEnded:(UIEventSubtype)motion withEvent:(UIEvent *)event {
    if (motion == UIEventSubtypeMotionShake) {
        [[SwiggyBypassController sharedInstance] rotateTapped];
    }
    [super motionEnded:motion withEvent:event];
}

@end


// --- Constructor ---

__attribute__((constructor))
static void initialize_hack() {
    EnsureIDsExist();
    NSLog(@"[SwiggyBypass] Constructor Loaded");

    // Start trying to show UI slightly delayed to let Scene load
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(3.0 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        [[SwiggyBypassController sharedInstance] setupFloatingButton];
    });
    
    // Also Observer
    [[NSNotificationCenter defaultCenter] addObserverForName:UIApplicationDidBecomeActiveNotification object:nil queue:[NSOperationQueue mainQueue] usingBlock:^(NSNotification * _Nonnull note) {
         [[SwiggyBypassController sharedInstance] setupFloatingButton];
    }];
}
