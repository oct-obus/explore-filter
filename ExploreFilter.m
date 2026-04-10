/*
 * ExploreFilter — Hides already-liked posts from Instagram Explore grid
 *
 * Hook strategy:
 *   1. Swizzle -[IGDiscoveryGridDataStore items] to filter out liked items
 *   2. Swizzle -[IGDiscoveryGridSection items] as secondary filter (same logic)
 *   3. Comprehensive logging for on-device debugging
 *
 * Data flow:
 *   IGExploreListKitDataSource.dataStore (IGDiscoveryGridDataStore)
 *     → items: [IGDiscoveryGridItem]
 *       → model: id<IGDiscoveryGridItemType>
 *         → media: IGMedia (inherits IGBaseMedia)
 *           → hasLiked: id<FBBoxedBoolean> → boolValue
 *
 * hasLiked is nullable (id<FBBoxedBoolean>). When nil, the item passes through.
 * After hydration, hasLiked gets populated and the grid refreshes automatically.
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
static _Atomic NSUInteger sTotalItemsFiltered = 0;
static _Atomic NSUInteger sTotalNilLikeStatus = 0;

#pragma mark - Cached Selectors

static SEL sSel_model = NULL;
static SEL sSel_media = NULL;
static SEL sSel_hasLiked = NULL;
static SEL sSel_boolValue = NULL;

static void EFCacheSelectors(void) {
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        sSel_model = sel_registerName("model");
        sSel_media = sel_registerName("media");
        sSel_hasLiked = sel_registerName("hasLiked");
        sSel_boolValue = sel_registerName("boolValue");
    });
}

#pragma mark - Filtering Logic

/*
 * Given an IGDiscoveryGridItem, returns YES if it should be REMOVED (is liked).
 * Returns NO if it should be kept (not liked, or like status unknown).
 */
static BOOL EFShouldFilterItem(id gridItem) {
    if (!gridItem) return NO;

    id model = ((id (*)(id, SEL))objc_msgSend)(gridItem, sSel_model);
    if (!model) return NO;

    id media = ((id (*)(id, SEL))objc_msgSend)(model, sSel_media);
    if (!media) return NO;

    id hasLiked = ((id (*)(id, SEL))objc_msgSend)(media, sSel_hasLiked);
    if (!hasLiked || [hasLiked isKindOfClass:[NSNull class]]) {
        sTotalNilLikeStatus++;
        return NO;
    }

    BOOL liked = ((BOOL (*)(id, SEL))objc_msgSend)(hasLiked, sSel_boolValue);
    return liked;
}

/*
 * Filters an array of IGDiscoveryGridItem, removing liked items.
 * Returns the filtered array (may be same array if nothing filtered).
 */
static NSArray *EFFilterGridItems(NSArray *items, NSString *source) {
    if (!items || items.count == 0) return items;

    NSUInteger originalCount = items.count;
    NSMutableArray *filtered = [NSMutableArray arrayWithCapacity:originalCount];
    NSUInteger removedCount = 0;

    for (id item in items) {
        if (EFShouldFilterItem(item)) {
            removedCount++;
        } else {
            [filtered addObject:item];
        }
    }

    sTotalItemsSeen += originalCount;
    sTotalItemsFiltered += removedCount;

    if (removedCount > 0) {
        // Rate-limit logging: only log when lifetime filtered count crosses a power-of-2 boundary
        NSUInteger totalFiltered = sTotalItemsFiltered;
        if ((totalFiltered & (totalFiltered - 1)) == 0 || totalFiltered <= 4) {
            EFLog(@"%@: filtered %lu/%lu items (lifetime: %lu seen, %lu filtered, %lu nil-like)",
                  source,
                  (unsigned long)removedCount,
                  (unsigned long)originalCount,
                  (unsigned long)sTotalItemsSeen,
                  (unsigned long)totalFiltered,
                  (unsigned long)sTotalNilLikeStatus);
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

    // Use class_addMethod to ensure we're adding directly to this class,
    // not accidentally modifying a superclass method that was inherited
    const char *types = method_getTypeEncoding(method);
    if (class_addMethod(cls, originalSel, replacementImp, types)) {
        // Method was inherited — class_addMethod installed our replacement directly on cls
        *outOriginalImp = method_getImplementation(method);
        EFLog(@"swizzled -%@ on %@ (was inherited, added directly; orig IMP: %p)",
              NSStringFromSelector(originalSel),
              NSStringFromClass(cls),
              *outOriginalImp);
    } else {
        // Method exists directly on cls — safe to replace in place
        *outOriginalImp = method_setImplementation(method, replacementImp);
        EFLog(@"swizzled -%@ on %@ (direct replacement; orig IMP: %p)",
              NSStringFromSelector(originalSel),
              NSStringFromClass(cls),
              *outOriginalImp);
    }
}

#pragma mark - Hook: IGDiscoveryGridDataStore items

static IMP sOrigDataStoreItems = NULL;

static NSArray *EFHook_DataStore_items(id self, SEL _cmd) {
    NSArray *original = ((NSArray *(*)(id, SEL))sOrigDataStoreItems)(self, _cmd);
    return EFFilterGridItems(original, @"DataStore.items");
}

#pragma mark - Hook: IGDiscoveryGridSection items

static IMP sOrigSectionItems = NULL;

static NSArray *EFHook_Section_items(id self, SEL _cmd) {
    NSArray *original = ((NSArray *(*)(id, SEL))sOrigSectionItems)(self, _cmd);
    return EFFilterGridItems(original, @"Section.items");
}

#pragma mark - Constructor

__attribute__((constructor))
static void ExploreFilterInit(void) {
    EFLogInit();
    EFLog(@"loaded — scanning for Explore classes...");

    EFCacheSelectors();

    @try {
        // Hook 1: IGDiscoveryGridDataStore items
        Class dataStoreClass = objc_getClass("IGDiscoveryGridDataStore");
        if (dataStoreClass) {
            EFSwizzleMethod(dataStoreClass,
                            sel_registerName("items"),
                            (IMP)EFHook_DataStore_items,
                            &sOrigDataStoreItems);
        } else {
            EFLog(@"WARNING: IGDiscoveryGridDataStore class not found");
        }

        // Hook 2: IGDiscoveryGridSection items
        Class sectionClass = objc_getClass("IGDiscoveryGridSection");
        if (sectionClass) {
            EFSwizzleMethod(sectionClass,
                            sel_registerName("items"),
                            (IMP)EFHook_Section_items,
                            &sOrigSectionItems);
        } else {
            EFLog(@"WARNING: IGDiscoveryGridSection class not found");
        }

        EFLog(@"initialization complete — %d hooks installed",
              (sOrigDataStoreItems ? 1 : 0) + (sOrigSectionItems ? 1 : 0));

    } @catch (NSException *e) {
        EFLog(@"FATAL: initialization failed: %@ — %@", e.name, e.reason);
    }
}
