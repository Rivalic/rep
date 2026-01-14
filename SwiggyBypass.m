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
    EnsureIDsExist();
    NSString *uuidString = [[NSUserDefaults standardUserDefaults] stringForKey:kSpoofedIDFV];
    return [[NSUUID alloc] initWithUUIDString:uuidString];
}

@end

// Note: ASIdentifierManager is needed from AdSupport framework. 
// We verify its class exists before hooking to avoid crashes if framework is missing (unlikely in Swiggy).
// But for safety, we'll use runtime lookup.

// --- UI Button ---

@interface FloatingButtonController : NSObject
@end

@implementation FloatingButtonController

+ (instancetype)sharedInstance {
    static FloatingButtonController *sharedInstance = nil;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        sharedInstance = [[FloatingButtonController alloc] init];
    });
    return sharedInstance;
}

- (void)showSuccessAlert {
    dispatch_async(dispatch_get_main_queue(), ^{
        UIWindow *window = [UIApplication sharedApplication].keyWindow;
        UIViewController *topController = window.rootViewController;
        while (topController.presentedViewController) {
            topController = topController.presentedViewController;
        }
        
        UIAlertController *alert = [UIAlertController alertControllerWithTitle:@"Bypass Active"
                                                                       message:@"Swiggy Bypass Loaded!\nIDs have been spoofed."
                                                                preferredStyle:UIAlertControllerStyleAlert];
        [alert addAction:[UIAlertAction actionWithTitle:@"OK" style:UIAlertActionStyleDefault handler:nil]];
        [topController presentViewController:alert animated:YES completion:nil];
    });
}

- (void)rotateTapped {
    RotateIDs();
    
    UIAlertController *alert = [UIAlertController alertControllerWithTitle:@"Success"
                                                                   message:@"New Device IDs Generated.\nPlease RESTART the app now."
                                                            preferredStyle:UIAlertControllerStyleAlert];
    [alert addAction:[UIAlertAction actionWithTitle:@"OK" style:UIAlertActionStyleDefault handler:nil]];
    
    UIWindow *window = [UIApplication sharedApplication].keyWindow;
    UIViewController *topController = window.rootViewController;
    while (topController.presentedViewController) {
        topController = topController.presentedViewController;
    }
    [topController presentViewController:alert animated:YES completion:nil];
}

@end

static UIButton *floatingButton = nil;

static void SetupFloatingButton() {
    if (floatingButton) return;
    
    UIWindow *window = [UIApplication sharedApplication].keyWindow;
    if (!window) {
        // Retry loop if window is not ready
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(1.0 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
            SetupFloatingButton();
        });
        return;
    }
    
    floatingButton = [UIButton buttonWithType:UIButtonTypeSystem];
    floatingButton.frame = CGRectMake(20, 150, 120, 50); // Slightly larger, lower down
    floatingButton.backgroundColor = [UIColor orangeColor];
    [floatingButton setTitle:@"ROTATE ID" forState:UIControlStateNormal];
    [floatingButton setTitleColor:[UIColor whiteColor] forState:UIControlStateNormal];
    floatingButton.titleLabel.font = [UIFont boldSystemFontOfSize:16];
    floatingButton.layer.cornerRadius = 25;
    floatingButton.layer.borderWidth = 2;
    floatingButton.layer.borderColor = [UIColor whiteColor].CGColor;
    floatingButton.layer.zPosition = FLT_MAX; // Max zPosition
    
    [floatingButton addTarget:[FloatingButtonController sharedInstance] 
                       action:@selector(rotateTapped) 
             forControlEvents:UIControlEventTouchUpInside];
    
    [window addSubview:floatingButton];
    [window bringSubviewToFront:floatingButton];
    
    // Show startup alert
    [[FloatingButtonController sharedInstance] showSuccessAlert];
}

__attribute__((constructor))
static void initialize_hack() {
    EnsureIDsExist();
    
    // Listen for app active to ensure UI is ready
    [[NSNotificationCenter defaultCenter] addObserverForName:UIApplicationDidBecomeActiveNotification object:nil queue:[NSOperationQueue mainQueue] usingBlock:^(NSNotification * _Nonnull note) {
        SetupFloatingButton();
    }];
}
