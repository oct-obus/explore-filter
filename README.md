# ExploreFilter

Instagram tweak that filters out already-liked posts from the Explore page grid.

## How it works

Hooks `IGDiscoveryGridDataStore` and `IGDiscoveryGridSection` items getters to filter out media where `hasLiked.boolValue == YES`.

- Items with nil/unknown like status pass through (safe default)
- After hydration populates like data, the grid auto-refreshes and filtering kicks in
- Comprehensive logging with `[ExploreFilter]` prefix for Console.app debugging

## Target

Instagram v415.0.0 (arm64)

## Build

Requires Theos:
```
export THEOS=~/theos
make clean && make
```

## Integration

Designed for use with [DylibLoader](https://github.com/oct-obus/dylib-loader-poc) — add the manifest URL to load automatically.
