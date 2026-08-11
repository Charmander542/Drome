#import "DromeExceptionCatcher.h"

@implementation DromeExceptionCatcher

static NSString *_lastFailureReason = nil;

+ (NSString *)lastFailureReason {
    return _lastFailureReason;
}

+ (BOOL)perform:(void (NS_NOESCAPE ^)(void))block {
    _lastFailureReason = nil;
    @try {
        block();
        return YES;
    } @catch (NSException *exception) {
        _lastFailureReason = exception.reason ?: exception.name ?: @"Objective-C exception";
        return NO;
    }
}

@end
