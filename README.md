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
