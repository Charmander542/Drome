#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

/// Catches Objective-C exceptions so Swift can probe CarPlay template support
/// without terminating (unsupported templates throw NSInvalidArgumentException).
@interface DromeExceptionCatcher : NSObject
@property (class, readonly, nullable) NSString *lastFailureReason;
+ (BOOL)perform:(void (NS_NOESCAPE ^)(void))block;
@end

NS_ASSUME_NONNULL_END
