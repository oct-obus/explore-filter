/*
 * ExploreFilter — Filters Instagram Explore grid items
 *
 * Filters:
 *   1. Already-liked posts (hasLiked == YES)
 *   2. Image-only posts (no video content)
 *   3. Vertical reels (single video with aspect ratio < 0.6)
 *
 * Hook strategy:
 *   Swizzle -[IGDiscoveryGridDataStore items] and -[IGDiscoveryGridSection items]
 *   to remove matching items before the grid renders them.
 *
 * Safety:
 *   Ad items and non-media items are detected and passed through untouched.
 *   All property accesses are guarded with respondsToSelector: checks.
 */

#import <Foundation/Foundation.h>
#import <objc/runtime.h>
#import <objc/message.h>

#pragma mark - Logging

#define EF_LOG_PREFIX @"[ExploreFilter]"

static NSString *sLogPath = nil;
static dispatch_queue_t sLogQueue = nil;

static void EFLogInit(void) {
    sLogQueue = dispatch_queue_create("explore.filter.log", DISPATCH_QUEUE_SERIAL);
    NSArray *paths = NSSearchPathForDirectoriesInDomains(NSDocumentDirectory, NSUserDomainMask, YES);
    if (paths.count > 0) {
        sLogPath = [paths[0] stringByAppendingPathComponent:@"explore_filter.txt"];
    }
}

static void EFLog(NSString *format, ...) NS_FORMAT_FUNCTION(1,2);
static void EFLog(NSString *format, ...) {
    if (!sLogPath) return;
    va_list args;
    va_start(args, format);
    NSString *msg = [[NSString alloc] initWithFormat:format arguments:args];
    va_end(args);

    NSString *fullMsg = [NSString stringWithFormat:@"%@ %@", EF_LOG_PREFIX, msg];
    NSLog(@"%@", fullMsg);

    dispatch_async(sLogQueue, ^{
        NSDateFormatter *df = [NSDateFormatter new];
        df.dateFormat = @"yyyy-MM-dd HH:mm:ss.SSS";
        NSString *ts = [df stringFromDate:[NSDate date]];
        NSString *line = [NSString stringWithFormat:@"[%@] %@\n", ts, fullMsg];
        NSData *data = [line dataUsingEncoding:NSUTF8StringEncoding];
        NSFileHandle *fh = [NSFileHandle fileHandleForWritingAtPath:sLogPath];
        if (fh) {
            [fh seekToEndOfFile];
            [fh writeData:data];
            [fh closeFile];
        } else {
            [data writeToFile:sLogPath atomically:YES];
        }
    });
}

#pragma mark - Statistics

static _Atomic NSUInteger sTotalItemsSeen = 0;
static _Atomic NSUInteger sFilteredLiked = 0;
static _Atomic NSUInteger sFilteredImageOnly = 0;
static _Atomic NSUInteger sFilteredVerticalReel = 0;
static _Atomic NSUInteger sSkippedAds = 0;
static _Atomic NSUInteger sSkippedNilLike = 0;

#pragma mark - Cached Selectors

static SEL sSel_model = NULL;
static SEL sSel_media = NULL;
static SEL sSel_hasLiked = NULL;
static SEL sSel_boolValue = NULL;
static SEL sSel_integerValue = NULL;
static SEL sSel_mediaType = NULL;
static SEL sSel_video = NULL;
static SEL sSel_originalWidth = NULL;
static SEL sSel_originalHeight = NULL;
static SEL sSel_isCarousel = NULL;

static void EFCacheSelectors(void) {
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        sSel_model = sel_registerName("model");
        sSel_media = sel_registerName("media");
        sSel_hasLiked = sel_registerName("hasLiked");
        sSel_boolValue = sel_registerName("boolValue");
        sSel_integerValue = sel_registerName("integerValue");
        sSel_mediaType = sel_registerName("mediaType");
        sSel_video = sel_registerName("video");
        sSel_originalWidth = sel_registerName("originalWidth");
        sSel_originalHeight = sel_registerName("originalHeight");
        sSel_isCarousel = sel_registerName("isCarousel");
    });
}

#pragma mark - Filter Reason Enum

typedef NS_ENUM(NSUInteger, EFFilterReason) {
    EFFilterReasonNone = 0,
    EFFilterReasonLiked,
    EFFilterReasonImageOnly,
    EFFilterReasonVerticalReel,
};

#pragma mark - Safe Media Access

// Returns the IGMedia object for a grid item, or nil if it's an ad/non-media item
static id EFGetMediaForItem(id gridItem) {
    if (!gridItem) return nil;

    id model = ((id (*)(id, SEL))objc_msgSend)(gridItem, sSel_model);
    if (!model) return nil;

    // Ad items have models that don't implement the media selector
    if (![model respondsToSelector:sSel_media]) return nil;

    return ((id (*)(id, SEL))objc_msgSend)(model, sSel_media);
}

// Returns the integer media type: 1=photo, 2=video, 8=carousel, 0=unknown
static NSInteger EFGetMediaType(id media) {
    if (![media respondsToSelector:sSel_mediaType]) return 0;
    id boxed = ((id (*)(id, SEL))objc_msgSend)(media, sSel_mediaType);
    if (!boxed || ![boxed respondsToSelector:sSel_integerValue]) return 0;
    return ((NSInteger (*)(id, SEL))objc_msgSend)(boxed, sSel_integerValue);
}

#pragma mark - Filter Checks

static EFFilterReason EFCheckItem(id gridItem) {
    id media = EFGetMediaForItem(gridItem);
    if (!media) {
        sSkippedAds++;
        return EFFilterReasonNone; // pass through ads and non-media items
    }

    // Filter 1: Already-liked posts
    if ([media respondsToSelector:sSel_hasLiked]) {
        id hasLiked = ((id (*)(id, SEL))objc_msgSend)(media, sSel_hasLiked);
        if (!hasLiked || [hasLiked isKindOfClass:[NSNull class]]) {
            sSkippedNilLike++;
        } else if ([hasLiked respondsToSelector:sSel_boolValue]) {
            BOOL liked = ((BOOL (*)(id, SEL))objc_msgSend)(hasLiked, sSel_boolValue);
            if (liked) return EFFilterReasonLiked;
        }
    }

    NSInteger mediaType = EFGetMediaType(media);

    // Filter 2: Image-only posts (mediaType 1 = photo, not carousel)
    if (mediaType == 1) {
        return EFFilterReasonImageOnly;
    }

    // Also filter carousels that contain no video (all images)
    if (mediaType == 8 && [media respondsToSelector:sSel_video]) {
        id videoObj = ((id (*)(id, SEL))objc_msgSend)(media, sSel_video);
        if (!videoObj) {
            return EFFilterReasonImageOnly;
        }
    }

    // Filter 3: Vertical reels — single video with width/height < 0.6
    if (mediaType == 2 && [media respondsToSelector:sSel_originalWidth]
                       && [media respondsToSelector:sSel_originalHeight]) {
        id wBox = ((id (*)(id, SEL))objc_msgSend)(media, sSel_originalWidth);
        id hBox = ((id (*)(id, SEL))objc_msgSend)(media, sSel_originalHeight);
        if (wBox && hBox
            && [wBox respondsToSelector:sSel_integerValue]
            && [hBox respondsToSelector:sSel_integerValue]) {
            NSInteger w = ((NSInteger (*)(id, SEL))objc_msgSend)(wBox, sSel_integerValue);
            NSInteger h = ((NSInteger (*)(id, SEL))objc_msgSend)(hBox, sSel_integerValue);
            if (h > 0 && w > 0) {
                double ratio = (double)w / (double)h;
                if (ratio < 0.6) {
                    return EFFilterReasonVerticalReel;
                }
            }
        }
    }

    return EFFilterReasonNone;
}

#pragma mark - Filter Array

static NSArray *EFFilterGridItems(NSArray *items, NSString *source) {
    if (!items || items.count == 0) return items;

    NSUInteger originalCount = items.count;
    NSMutableArray *filtered = [NSMutableArray arrayWithCapacity:originalCount];
    NSUInteger likedCount = 0, imageCount = 0, reelCount = 0;

    for (id item in items) {
        EFFilterReason reason = EFCheckItem(item);
        switch (reason) {
            case EFFilterReasonLiked:       likedCount++;  break;
            case EFFilterReasonImageOnly:   imageCount++;  break;
            case EFFilterReasonVerticalReel: reelCount++;  break;
            case EFFilterReasonNone:
                [filtered addObject:item];
                break;
        }
    }

    NSUInteger removedTotal = likedCount + imageCount + reelCount;
    sTotalItemsSeen += originalCount;
    sFilteredLiked += likedCount;
    sFilteredImageOnly += imageCount;
    sFilteredVerticalReel += reelCount;

    if (removedTotal > 0) {
        NSUInteger lifetimeTotal = sFilteredLiked + sFilteredImageOnly + sFilteredVerticalReel;
        if ((lifetimeTotal & (lifetimeTotal - 1)) == 0 || lifetimeTotal <= 4) {
            EFLog(@"%@: -%lu/%lu (liked=%lu img=%lu vreel=%lu) | life: seen=%lu L=%lu I=%lu V=%lu ads=%lu nil=%lu",
                  source,
                  (unsigned long)removedTotal, (unsigned long)originalCount,
                  (unsigned long)likedCount, (unsigned long)imageCount, (unsigned long)reelCount,
                  (unsigned long)sTotalItemsSeen,
                  (unsigned long)sFilteredLiked, (unsigned long)sFilteredImageOnly,
                  (unsigned long)sFilteredVerticalReel,
                  (unsigned long)sSkippedAds, (unsigned long)sSkippedNilLike);
        }
        return [filtered copy];
    }

    return items;
}

#pragma mark - Method Swizzling Helpers

static void EFSwizzleMethod(Class cls, SEL originalSel, IMP replacementImp, IMP *outOriginalImp) {
    if (!cls) {
        EFLog(@"swizzle FAILED: class is nil for -%@", NSStringFromSelector(originalSel));
        return;
    }

    Method method = class_getInstanceMethod(cls, originalSel);
    if (!method) {
        EFLog(@"swizzle FAILED: method -%@ not found on %@",
              NSStringFromSelector(originalSel),
              NSStringFromClass(cls));
        return;
    }

    const char *types = method_getTypeEncoding(method);
    // Capture original IMP before class_addMethod to avoid TOCTOU with other tweaks
    IMP origImp = method_getImplementation(method);
    if (class_addMethod(cls, originalSel, replacementImp, types)) {
        *outOriginalImp = origImp;
        EFLog(@"swizzled -%@ on %@ (inherited; orig: %p)",
              NSStringFromSelector(originalSel), NSStringFromClass(cls), *outOriginalImp);
    } else {
        *outOriginalImp = method_setImplementation(method, replacementImp);
        EFLog(@"swizzled -%@ on %@ (direct; orig: %p)",
              NSStringFromSelector(originalSel), NSStringFromClass(cls), *outOriginalImp);
    }
}

#pragma mark - Hooks

static IMP sOrigDataStoreItems = NULL;

static NSArray *EFHook_DataStore_items(id self, SEL _cmd) {
    NSArray *original = ((NSArray *(*)(id, SEL))sOrigDataStoreItems)(self, _cmd);
    return EFFilterGridItems(original, @"DS");
}

static IMP sOrigSectionItems = NULL;

static NSArray *EFHook_Section_items(id self, SEL _cmd) {
    NSArray *original = ((NSArray *(*)(id, SEL))sOrigSectionItems)(self, _cmd);
    return EFFilterGridItems(original, @"Sec");
}

#pragma mark - Constructor

__attribute__((constructor))
static void ExploreFilterInit(void) {
    EFLogInit();
    EFLog(@"v5 loaded");

    EFCacheSelectors();

    @try {
        Class dataStoreClass = objc_getClass("IGDiscoveryGridDataStore");
        if (dataStoreClass) {
            EFSwizzleMethod(dataStoreClass, sel_registerName("items"),
                            (IMP)EFHook_DataStore_items, &sOrigDataStoreItems);
        } else {
            EFLog(@"WARNING: IGDiscoveryGridDataStore not found");
        }

        Class sectionClass = objc_getClass("IGDiscoveryGridSection");
        if (sectionClass) {
            EFSwizzleMethod(sectionClass, sel_registerName("items"),
                            (IMP)EFHook_Section_items, &sOrigSectionItems);
        } else {
            EFLog(@"WARNING: IGDiscoveryGridSection not found");
        }

        // Defensive: add no-op showMultipleSelection to ad cell classes
        // Prevents crash when grid layout calls selection on wrong cell type after filtering
        SEL showMultiSel = sel_registerName("showMultipleSelection");
        IMP noopIMP = imp_implementationWithBlock(^(id _self){});
        Class adClasses[] = {
            objc_getClass("IGDiscoveryGridAdCell"),
            objc_getClass("IGDiscoveryGridVideoAdCell"),
        };
        for (int i = 0; i < 2; i++) {
            if (adClasses[i] && !class_getInstanceMethod(adClasses[i], showMultiSel)) {
                class_addMethod(adClasses[i], showMultiSel, noopIMP, "v@:");
                EFLog(@"patched %@ with no-op showMultipleSelection",
                      NSStringFromClass(adClasses[i]));
            }
        }

        EFLog(@"init complete — %d hooks",
              (sOrigDataStoreItems ? 1 : 0) + (sOrigSectionItems ? 1 : 0));
    } @catch (NSException *e) {
        EFLog(@"FATAL: %@ — %@", e.name, e.reason);
    }
}
