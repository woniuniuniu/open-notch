#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

/// Activates a macOS 27 MenuBarAgent visibility assertion. The returned opaque
/// object is retained and must be released with ONInvalidateVisibilityAssertion.
void * _Nullable ONCreateVisibilityAssertion(
    NSArray<NSNumber *> *allowedSystemItems,
    NSArray<NSString *> *allowedBundleIdentifiers
);

void ONInvalidateVisibilityAssertion(void * _Nullable assertion);

NS_ASSUME_NONNULL_END
