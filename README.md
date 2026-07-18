# honeycube_game_ads

Shared ad package for Honeycube Flutter games.

Game code owns ad policy, rewards, analytics, and screen flow. This package owns SDK initialization and ad load/show calls.

```dart
final ads = HCAdService(config: HCAdConfig.fromDartDefine());

await ads.initialize();
final result = await ads.showRewarded();
if (result == HCAdShowResult.rewarded) {
  // Apply the game reward.
}
```

## Banner lifecycle

`loadBanner()` reuses a loaded banner and never replaces it implicitly. To replace or release a banner, first remove the widget returned by `buildBannerWidget()` from Flutter's widget tree. After that widget has unmounted, call `disposeBanner()`; call `loadBanner()` again only when a new banner is needed. Calling `disposeBanner()` while its `AdWidget` is mounted is unsupported.
