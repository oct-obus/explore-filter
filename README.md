# ExploreFilter

Instagram tweak that filters unwanted posts from the Explore page grid.

## Filters

1. **Already-liked posts** — removes posts you've already liked
2. **Image-only posts** — removes static photos (mediaType 1)
3. **Vertical reels** — removes portrait videos with aspect ratio < 0.6

Items with unknown like status pass through safely. Ad cells and non-media items are detected and left untouched.

## Logging

Debug builds log each filtered post as an Instagram URL (deduplicated):
```
[ExploreFilter] FILTERED [liked] https://www.instagram.com/p/DUEq5y6iDOx/
[ExploreFilter] FILTERED [vreel] https://www.instagram.com/p/ABC123/ (720x1280 = 0.56)
```

Logs go to both `NSLog` (Console.app) and `Documents/explore_filter.txt`.

Controlled at compile time via `EF_LOGGING`:
```
make EF_LOGGING=1    # debug (logging enabled, default)
make EF_LOGGING=0    # release (logging stripped at compile time)
```

## Target

Instagram v415.0.0 (arm64), loaded via LiveContainer TweakLoader.

## Building

Requires [Theos](https://theos.dev/docs/installation):

```bash
export THEOS=~/theos
make              # debug build (logging on)
make EF_LOGGING=0 # release build (no logging)
```

## CI

GitHub Actions builds both debug and release dylibs on every push to `master`. Download artifacts from the [Actions tab](../../actions).

## Installation

1. Place `ExploreFilter.dylib` in `Tweaks/` inside the app bundle
2. Enable TweakLoader in LiveContainer
3. If TweakLoader is grayed out, delete and re-import the app to clear the `LCTweakLoaderCantInject` flag

Also compatible with [DylibLoader](https://github.com/oct-obus/dylib-loader-poc) — add the `payload.json` manifest URL to load automatically.
