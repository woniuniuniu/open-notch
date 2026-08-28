#import "MacOS27VisibilityBridge.h"
#import <AppKit/AppKit.h>

@interface ONAssessmentModeConfiguration : NSObject
- (instancetype)initWithAllowedSystemItems:(NSArray<NSNumber *> *)items
                   allowedBundleIdentifiers:(NSArray<NSString *> *)bundleIdentifiers;
@end

@interface ONAssessmentModeAssertion : NSObject
- (void)activateWithConfiguration:(id)configuration completionHandler:(id)completionHandler;
- (void)invalidate;
@end

void *ONCreateVisibilityAssertion(
    NSArray<NSNumber *> *allowedSystemItems,
    NSArray<NSString *> *allowedBundleIdentifiers
) {
    NSBundle *framework = [NSBundle bundleWithPath:@"/System/Library/PrivateFrameworks/MenuBarClient.framework"];
    NSBundle *core = [NSBundle bundleWithPath:@"/System/Library/PrivateFrameworks/MenuBarClientCore.framework"];
    if (![framework load] || ![core load]) return NULL;

    Class configurationClass = NSClassFromString(@"MBAssessmentModeConfiguration");
    Class assertionClass = NSClassFromString(@"MBAssessmentModeAssertion");
    if (!configurationClass || !assertionClass) return NULL;

    id configuration = [[configurationClass alloc] initWithAllowedSystemItems:allowedSystemItems
                                                      allowedBundleIdentifiers:allowedBundleIdentifiers];
    id assertion = [[assertionClass alloc] init];
    if (!configuration || !assertion) return NULL;

    // The private completion ABI currently returns two integer status fields.
    // We deliberately ignore them and verify the result from the AX inventory.
    void (^completion)(NSInteger, NSInteger) = ^(NSInteger first, NSInteger second) {
        (void)first;
        (void)second;
    };
    [assertion activateWithConfiguration:configuration completionHandler:completion];
    return (__bridge_retained void *)assertion;
}

void ONInvalidateVisibilityAssertion(void *assertionPointer) {
    if (!assertionPointer) return;
    id assertion = (__bridge_transfer id)assertionPointer;
    [assertion invalidate];
}
