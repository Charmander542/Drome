#import "DromeOpenURL.h"
#import <objc/message.h>

static id DromeFindApplication(UIResponder *start) {
    Class appClass = NSClassFromString(@"UIApplication");
    for (UIResponder *r = start; r != nil; r = r.nextResponder) {
        if (appClass != Nil && [r isKindOfClass:appClass]) {
            return r;
        }
    }
    SEL sharedSel = NSSelectorFromString(@"sharedApplication");
    if (appClass == Nil || ![appClass respondsToSelector:sharedSel]) {
        return nil;
    }
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Warc-performSelector-leaks"
    id app = [appClass performSelector:sharedSel];
#pragma clang diagnostic pop
    return app;
}

static void DromeInvokeOpen(id app, NSURL *url, void (^completion)(BOOL)) {
    SEL modern = NSSelectorFromString(@"openURL:options:completionHandler:");
    if (![app respondsToSelector:modern]) {
        if (completion) { completion(NO); }
        return;
    }
    void (*open)(id, SEL, NSURL *, NSDictionary *, void (^)(BOOL)) =
        (void (*)(id, SEL, NSURL *, NSDictionary *, void (^)(BOOL)))objc_msgSend;
    open(app, modern, url, @{}, ^(BOOL success) {
        if (completion) { completion(success); }
    });
}

void DromeOpenURL(NSURL *url, UIResponder *start, void (^completion)(BOOL success)) {
    if (url == nil) {
        if (completion) { completion(NO); }
        return;
    }
    id app = DromeFindApplication(start);
    if (app == nil) {
        if (completion) { completion(NO); }
        return;
    }
    DromeInvokeOpen(app, url, completion);
}
