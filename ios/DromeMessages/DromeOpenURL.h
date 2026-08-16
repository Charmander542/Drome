#import <UIKit/UIKit.h>

NS_ASSUME_NONNULL_BEGIN

/// Opens a URL with `UIApplication.openURL:options:completionHandler:` found via
/// the responder chain or `sharedApplication`. iOS 18 no-ops the deprecated
/// `openURL:` API, so this must use the modern selector.
void DromeOpenURL(NSURL *url, UIResponder *_Nullable start, void (^_Nullable completion)(BOOL success))
    NS_SWIFT_NAME(DromeOpenURL(_:from:completion:));

NS_ASSUME_NONNULL_END
