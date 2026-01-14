#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>
#import <AdSupport/AdSupport.h>
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

// Hook for MGCopyAnswer (libMobileGestalt)
// We need to declare it as a weak symbol or look it up dynamically to avoid linking errors if not present,
// but usually it's available. For a simple dylib, we can use fishhook or dynamic lookup.
// simplifying with direct function replacement if using substrate, but here we are using standard ObjC method swizzling and maybe fishhook for C functions?
// Since we don't have CydiaSubstrate/Substitute headers easily available for plain clang compile without an SDK,
// Method Swizzling is easier for ObjC methods. MGCopyAnswer is a C function.
// We will try to rely on ObjC hooks where possible.
// IDFV is UIDevice.
// IDFA is ASIdentifierManager.
// UDID/Serial are usually MGCopyAnswer.
// For MGCopyAnswer, we need a C hook. We will implement a basic interposer or just rely on Method Swizzling for the ObjC parts first.
// Creating a simple C hook using rebind_symbols (fishhook) would be ideal, but requires adding fishhook.c/h.
// To keep it single-file, we can attempt to use `dlsym` with `RTLD_NEXT` if we were using a dynamic interposer approach,
// OR just hook the ObjC methods which are the most common ways apps get these.
// Many apps use `[[UIDevice currentDevice] identifierForVendor]`.

@interface UIDevice (Swizzle)
@end

@implementation UIDevice (Swizzle)

+ (void)load {
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        Class class = [self class];
        SEL originalSelector = @selector(identifierForVendor);
        SEL swizzledSelector = @selector(swizzled_identifierForVendor);
        
        Method originalMethod = class_getInstanceMethod(class, originalSelector);
        Method swizzledMethod = class_getInstanceMethod(class, swizzledSelector);
        
        method_exchangeImplementations(originalMethod, swizzledMethod);
    });
}

- (NSUUID *)swizzled_identifierForVendor {
    EnsureIDsExist();
    NSString *uuidString = [[NSUserDefaults standardUserDefaults] stringForKey:kSpoofedIDFV];
    return [[NSUUID alloc] initWithUUIDString:uuidString];
}

@end

@interface ASIdentifierManager (Swizzle)
@end

@implementation ASIdentifierManager (Swizzle)

+ (void)load {
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        Class class = [self class];
        SEL originalSelector = @selector(advertisingIdentifier);
        SEL swizzledSelector = @selector(swizzled_advertisingIdentifier);
        
        Method originalMethod = class_getInstanceMethod(class, originalSelector);
        Method swizzledMethod = class_getInstanceMethod(class, swizzledSelector);
        
        method_exchangeImplementations(originalMethod, swizzledMethod);
    });
}

- (NSUUID *)swizzled_advertisingIdentifier {
    EnsureIDsExist();
    NSString *uuidString = [[NSUserDefaults standardUserDefaults] stringForKey:kSpoofedIDFA];
    return [[NSUUID alloc] initWithUUIDString:uuidString];
}

@end


// --- UI Button ---

@interface FloatingButtonController : UIViewController
@end

@implementation FloatingButtonController
- (void)rotateTapped {
    RotateIDs();
    
    UIAlertController *alert = [UIAlertController alertControllerWithTitle:@"Swiggy Bypass"
                                                                   message:@"Device IDs Rotated!\nPlease force close and restart the app."
                                                            preferredStyle:UIAlertControllerStyleAlert];
    [alert addAction:[UIAlertAction actionWithTitle:@"OK" style:UIAlertActionStyleDefault handler:nil]];
    
    // Find top most view controller to present
    UIViewController *topController = [UIApplication sharedApplication].keyWindow.rootViewController;
    while (topController.presentedViewController) {
        topController = topController.presentedViewController;
    }
    [topController presentViewController:alert animated:YES completion:nil];
}

@end

static UIButton *floatingButton = nil;

static void SetupFloatingButton() {
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(3.0 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        UIWindow *window = [UIApplication sharedApplication].keyWindow;
        if (!window) return;
        
        floatingButton = [UIButton buttonWithType:UIButtonTypeSystem];
        floatingButton.frame = CGRectMake(20, 100, 100, 40);
        floatingButton.backgroundColor = [UIColor orangeColor];
        [floatingButton setTitle:@"Rotate ID" forState:UIControlStateNormal];
        [floatingButton setTitleColor:[UIColor whiteColor] forState:UIControlStateNormal];
        floatingButton.layer.cornerRadius = 20;
        floatingButton.layer.zPosition = 9999;
        
        [floatingButton addTarget:[[FloatingButtonController alloc] init] 
                           action:@selector(rotateTapped) 
                 forControlEvents:UIControlEventTouchUpInside];
        
        UIPanGestureRecognizer *panGesture = [[UIPanGestureRecognizer alloc] initWithTarget:[FloatingButtonController class] action:@selector(handlePan:)];
        // Note: Simple pan handling would need an instance or static wrapper, simplifying for brevity:
        // Let's just keep it fixed or add a simple drag later if needed.
        
        [window addSubview:floatingButton];
    });
}

// C-Constructor to initialize
__attribute__((constructor))
static void initialize_hack() {
    NSLog(@"[SwiggyBypass] Loaded!");
    EnsureIDsExist();
    
    [[NSNotificationCenter defaultCenter] addObserverForName:UIApplicationDidFinishLaunchingNotification object:nil queue:[NSOperationQueue mainQueue] usingBlock:^(NSNotification * _Nonnull note) {
        SetupFloatingButton();
    }];
}
