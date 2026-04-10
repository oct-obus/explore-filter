/*
 * ExploreFilter — Filters Instagram Explore grid items
 *
 * Filters (all configurable via Documents/explore_filter_config.json):
 *   1. Already-liked posts (hasLiked == YES)
 *   2. Image-only posts (no video content)
 *   3. Vertical reels (no square crop AND aspect ratio < threshold)
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

// Compile with -DEF_LOGGING_ENABLED=1 for debug builds
#ifndef EF_LOGGING_ENABLED
#define EF_LOGGING_ENABLED 0
#endif

#pragma mark - Logging

#if EF_LOGGING_ENABLED

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

#else
static void EFLogInit(void) {}
static inline void EFLog(NSString *format, ...) {}
#endif

#pragma mark - Statistics

static _Atomic NSUInteger sTotalItemsSeen = 0;
static _Atomic NSUInteger sFilteredLiked = 0;
static _Atomic NSUInteger sFilteredImageOnly = 0;
static _Atomic NSUInteger sFilteredVerticalReel = 0;
static _Atomic NSUInteger sSkippedAds = 0;
static _Atomic NSUInteger sSkippedNilLike = 0;

#pragma mark - Deduplication

static NSMutableSet *sSeenFilteredIDs = nil;
static dispatch_queue_t sSeenQueue = nil;

static void EFDedupeInit(void) {
    sSeenFilteredIDs = [NSMutableSet setWithCapacity:256];
    sSeenQueue = dispatch_queue_create("explore.filter.dedup", DISPATCH_QUEUE_SERIAL);
}

// Returns YES if this ID was already seen (duplicate). NO if first time.
static BOOL EFMarkSeen(NSString *mediaID) {
    if (!mediaID) return YES; // treat nil as duplicate (don't log)
    __block BOOL wasSeen;
    dispatch_sync(sSeenQueue, ^{
        wasSeen = [sSeenFilteredIDs containsObject:mediaID];
        if (!wasSeen) {
            [sSeenFilteredIDs addObject:mediaID];
            // Cap at 2000 to avoid unbounded growth
            if (sSeenFilteredIDs.count > 2000) {
                [sSeenFilteredIDs removeAllObjects];
            }
        }
    });
    return wasSeen;
}

#pragma mark - Cached Selectors

static SEL sSel_model = NULL;
static SEL sSel_media = NULL;
static SEL sSel_hasLiked = NULL;
static SEL sSel_boolValue = NULL;
static SEL sSel_integerValue = NULL;
static SEL sSel_mediaType = NULL;
static SEL sSel_originalWidth = NULL;
static SEL sSel_originalHeight = NULL;
static SEL sSel_code = NULL;
static SEL sSel_mediaCroppingInfo = NULL;
static SEL sSel_squareCrop = NULL;

static void EFCacheSelectors(void) {
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        sSel_model = sel_registerName("model");
        sSel_media = sel_registerName("media");
        sSel_hasLiked = sel_registerName("hasLiked");
        sSel_boolValue = sel_registerName("boolValue");
        sSel_integerValue = sel_registerName("integerValue");
        sSel_mediaType = sel_registerName("mediaType");
        sSel_originalWidth = sel_registerName("originalWidth");
        sSel_originalHeight = sel_registerName("originalHeight");
        sSel_code = sel_registerName("code");
        sSel_mediaCroppingInfo = sel_registerName("mediaCroppingInfo");
        sSel_squareCrop = sel_registerName("squareCrop");
    });
}

#pragma mark - Configuration

typedef struct {
    BOOL filterLiked;
    BOOL filterImages;
    BOOL filterVerticalReels;
    double aspectRatioThreshold;
} EFConfig;

static EFConfig sConfig = { .filterLiked = YES, .filterImages = YES,
                             .filterVerticalReels = YES, .aspectRatioThreshold = 0.6 };

static NSString *EFConfigPath(void) {
    NSArray *paths = NSSearchPathForDirectoriesInDomains(NSDocumentDirectory, NSUserDomainMask, YES);
    if (paths.count == 0) return nil;
    return [paths[0] stringByAppendingPathComponent:@"explore_filter_config.json"];
}

static void EFLoadConfig(void) {
    NSString *path = EFConfigPath();
    if (!path) return;

    NSData *data = [NSData dataWithContentsOfFile:path];
    if (!data) {
        // Generate defaults
        NSDictionary *defaults = @{
            @"filter_liked": @YES,
            @"filter_images": @YES,
            @"filter_vertical_reels": @YES,
            @"aspect_ratio_threshold": @0.6
        };
        NSData *jsonData = [NSJSONSerialization dataWithJSONObject:defaults
                                                           options:NSJSONWritingPrettyPrinted
                                                             error:nil];
        [jsonData writeToFile:path atomically:YES];
        EFLog(@"config: created defaults at %@", path);
        return;
    }

    NSError *err = nil;
    NSDictionary *dict = [NSJSONSerialization JSONObjectWithData:data options:0 error:&err];
    if (!dict || err) {
        EFLog(@"config: parse error — %@", err.localizedDescription);
        return;
    }

    if (dict[@"filter_liked"])           sConfig.filterLiked = [dict[@"filter_liked"] boolValue];
    if (dict[@"filter_images"])          sConfig.filterImages = [dict[@"filter_images"] boolValue];
    if (dict[@"filter_vertical_reels"])  sConfig.filterVerticalReels = [dict[@"filter_vertical_reels"] boolValue];
    if (dict[@"aspect_ratio_threshold"]) sConfig.aspectRatioThreshold = [dict[@"aspect_ratio_threshold"] doubleValue];

    EFLog(@"config: liked=%d images=%d vreels=%d ratio=%.2f",
          sConfig.filterLiked, sConfig.filterImages,
          sConfig.filterVerticalReels, sConfig.aspectRatioThreshold);
}

#pragma mark - Filter Reason Enum

typedef NS_ENUM(NSUInteger, EFFilterReason) {
    EFFilterReasonNone = 0,
    EFFilterReasonLiked,
    EFFilterReasonImageOnly,
    EFFilterReasonVerticalReel,
};

static NSString *EFReasonString(EFFilterReason reason) {
    switch (reason) {
        case EFFilterReasonLiked:       return @"liked";
        case EFFilterReasonImageOnly:   return @"image";
        case EFFilterReasonVerticalReel: return @"vreel";
        default:                        return @"none";
    }
}

#pragma mark - Safe Media Access

static id EFGetMediaForItem(id gridItem) {
    if (!gridItem) return nil;
    id model = ((id (*)(id, SEL))objc_msgSend)(gridItem, sSel_model);
    if (!model) return nil;
    if (![model respondsToSelector:sSel_media]) return nil;
    return ((id (*)(id, SEL))objc_msgSend)(model, sSel_media);
}

static NSInteger EFGetMediaType(id media) {
    if (![media respondsToSelector:sSel_mediaType]) return 0;
    id boxed = ((id (*)(id, SEL))objc_msgSend)(media, sSel_mediaType);
    if (!boxed || ![boxed respondsToSelector:sSel_integerValue]) return 0;
    return ((NSInteger (*)(id, SEL))objc_msgSend)(boxed, sSel_integerValue);
}

// Returns shortcode (e.g. "DUEq5y6iDOx") or nil
static NSString *EFGetShortcode(id media) {
    if (![media respondsToSelector:sSel_code]) return nil;
    id code = ((id (*)(id, SEL))objc_msgSend)(media, sSel_code);
    if ([code isKindOfClass:[NSString class]] && [(NSString *)code length] > 0) {
        return (NSString *)code;
    }
    return nil;
}

// Returns YES if the media has a square crop applied (creator set 1:1 display)
static BOOL EFHasSquareCrop(id media) {
    if (![media respondsToSelector:sSel_mediaCroppingInfo]) return NO;
    id cropInfo = ((id (*)(id, SEL))objc_msgSend)(media, sSel_mediaCroppingInfo);
    if (!cropInfo || [cropInfo isKindOfClass:[NSNull class]]) return NO;
    if (![cropInfo respondsToSelector:sSel_squareCrop]) return NO;
    id squareCrop = ((id (*)(id, SEL))objc_msgSend)(cropInfo, sSel_squareCrop);
    return (squareCrop != nil && ![squareCrop isKindOfClass:[NSNull class]]);
}

#pragma mark - Filter Checks

static EFFilterReason EFCheckItem(id gridItem, id *outMedia) {
    id media = EFGetMediaForItem(gridItem);
    if (outMedia) *outMedia = media;
    if (!media) {
        sSkippedAds++;
        return EFFilterReasonNone;
    }

    // Filter 1: Already-liked posts
    if (sConfig.filterLiked && [media respondsToSelector:sSel_hasLiked]) {
        id hasLiked = ((id (*)(id, SEL))objc_msgSend)(media, sSel_hasLiked);
        if (!hasLiked || [hasLiked isKindOfClass:[NSNull class]]) {
            sSkippedNilLike++;
        } else if ([hasLiked respondsToSelector:sSel_boolValue]) {
            BOOL liked = ((BOOL (*)(id, SEL))objc_msgSend)(hasLiked, sSel_boolValue);
            if (liked) return EFFilterReasonLiked;
        }
    }

    NSInteger mediaType = EFGetMediaType(media);

    // Filter 2: Image-only posts (mediaType 1 = photo)
    if (sConfig.filterImages && mediaType == 1) {
        return EFFilterReasonImageOnly;
    }

    // Filter 3: Vertical reels — single video with width/height < threshold, no square crop
    if (sConfig.filterVerticalReels && mediaType == 2
        && !EFHasSquareCrop(media)
        && [media respondsToSelector:sSel_originalWidth]
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
                if (ratio < sConfig.aspectRatioThreshold) {
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
        id media = nil;
        EFFilterReason reason = EFCheckItem(item, &media);
        switch (reason) {
            case EFFilterReasonLiked:       likedCount++;  break;
            case EFFilterReasonImageOnly:   imageCount++;  break;
            case EFFilterReasonVerticalReel: reelCount++;  break;
            case EFFilterReasonNone:
                [filtered addObject:item];
                continue; // skip logging for kept items
        }

        // Log filtered item (deduplicated by shortcode)
#if EF_LOGGING_ENABLED
        if (media) {
            NSString *shortcode = EFGetShortcode(media);
            if (shortcode && !EFMarkSeen(shortcode)) {
                if (reason == EFFilterReasonVerticalReel) {
                    // Include aspect ratio for reels
                    NSInteger w = 0, h = 0;
                    id wBox = ((id (*)(id, SEL))objc_msgSend)(media, sSel_originalWidth);
                    id hBox = ((id (*)(id, SEL))objc_msgSend)(media, sSel_originalHeight);
                    if (wBox) w = ((NSInteger (*)(id, SEL))objc_msgSend)(wBox, sSel_integerValue);
                    if (hBox) h = ((NSInteger (*)(id, SEL))objc_msgSend)(hBox, sSel_integerValue);
                    EFLog(@"FILTERED [%@] https://www.instagram.com/p/%@/ (%ldx%ld = %.2f)",
                          EFReasonString(reason), shortcode, (long)w, (long)h,
                          h > 0 ? (double)w/(double)h : 0.0);
                } else {
                    EFLog(@"FILTERED [%@] https://www.instagram.com/p/%@/",
                          EFReasonString(reason), shortcode);
                }
            }
        }
#endif
    }

    NSUInteger removedTotal = likedCount + imageCount + reelCount;
    sTotalItemsSeen += originalCount;
    sFilteredLiked += likedCount;
    sFilteredImageOnly += imageCount;
    sFilteredVerticalReel += reelCount;

    if (removedTotal > 0) {
#if EF_LOGGING_ENABLED
        NSUInteger lifetimeTotal = sFilteredLiked + sFilteredImageOnly + sFilteredVerticalReel;
        if ((lifetimeTotal & (lifetimeTotal - 1)) == 0 || lifetimeTotal <= 4) {
            EFLog(@"%@: -%lu/%lu | life: seen=%lu L=%lu I=%lu V=%lu ads=%lu nil=%lu",
                  source,
                  (unsigned long)removedTotal, (unsigned long)originalCount,
                  (unsigned long)sTotalItemsSeen,
                  (unsigned long)sFilteredLiked, (unsigned long)sFilteredImageOnly,
                  (unsigned long)sFilteredVerticalReel,
                  (unsigned long)sSkippedAds, (unsigned long)sSkippedNilLike);
        }
#endif
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
    EFDedupeInit();
    EFLoadConfig();
    EFLog(@"v8 loaded");

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
