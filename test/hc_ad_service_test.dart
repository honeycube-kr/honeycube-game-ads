import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:google_mobile_ads/google_mobile_ads.dart';
import 'package:honeycube_game_ads/honeycube_game_ads.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  const enabledConfig = HCAdConfig(
    enabled: true,
    admob: HCAdMobConfig(
      androidAppId: 'android-app-id',
      androidBannerId: 'banner-id',
      androidRewardedId: 'rewarded-id',
      androidInterstitialId: 'interstitial-id',
    ),
    platform: TargetPlatform.android,
  );

  test('fromDartDefine disables ads by default', () {
    final config = HCAdConfig.fromDartDefine(platform: TargetPlatform.android);

    expect(config.canRequestAds, isFalse);
  });

  test('common config requires enabled flag, Android platform, and app id', () {
    expect(enabledConfig.canRequestAds, isTrue);
    expect(
      const HCAdConfig(
        enabled: false,
        admob: HCAdMobConfig(
          androidAppId: 'android-app-id',
          androidBannerId: 'banner-id',
          androidRewardedId: 'rewarded-id',
          androidInterstitialId: 'interstitial-id',
        ),
        platform: TargetPlatform.android,
      ).canRequestAds,
      isFalse,
    );
    expect(
      const HCAdConfig(
        enabled: true,
        admob: HCAdMobConfig(
          androidAppId: '',
          androidBannerId: 'banner-id',
          androidRewardedId: 'rewarded-id',
          androidInterstitialId: 'interstitial-id',
        ),
        platform: TargetPlatform.android,
      ).canRequestAds,
      isFalse,
    );
    expect(
      const HCAdConfig(
        enabled: true,
        admob: HCAdMobConfig(
          androidAppId: 'android-app-id',
          androidBannerId: 'banner-id',
          androidRewardedId: 'rewarded-id',
          androidInterstitialId: 'interstitial-id',
        ),
        platform: TargetPlatform.iOS,
      ).canRequestAds,
      isFalse,
    );
  });

  test('disabled service never initializes or shows ads', () async {
    final service = HCAdService(config: const HCAdConfig.disabled());

    expect(await service.initialize(), HCAdInitializeResult.disabled);
    expect(await service.loadBanner(), HCAdLoadResult.disabled);
    expect(await service.loadRewarded(), HCAdLoadResult.disabled);
    expect(await service.showRewarded(), HCAdShowResult.disabled);
    expect(await service.loadInterstitial(), HCAdLoadResult.disabled);
    expect(await service.showInterstitial(), HCAdShowResult.disabled);
  });

  test(
    'enabled service falls back before initialization and before loaded ads',
    () async {
      final uninitialized = HCAdService(config: enabledConfig);
      final initialized = HCAdService.initializedForTest(config: enabledConfig);

      expect(await uninitialized.loadBanner(), HCAdLoadResult.notInitialized);
      expect(await uninitialized.loadRewarded(), HCAdLoadResult.notInitialized);
      expect(await uninitialized.showRewarded(), HCAdShowResult.notInitialized);
      expect(
        await uninitialized.loadInterstitial(),
        HCAdLoadResult.notInitialized,
      );
      expect(
        await uninitialized.showInterstitial(),
        HCAdShowResult.notInitialized,
      );
      expect(await initialized.showRewarded(), HCAdShowResult.notLoaded);
      expect(await initialized.showInterstitial(), HCAdShowResult.notLoaded);
    },
  );

  test('loaded banner is reused until explicitly disposed', () async {
    final banner = BannerAd(
      adUnitId: 'banner-id',
      size: AdSize.banner,
      request: const AdRequest(),
      listener: const BannerAdListener(),
    );
    final service = HCAdService.initializedForTest(
      config: enabledConfig,
      banner: banner,
    );

    expect(await service.loadBanner(), HCAdLoadResult.loaded);

    await service.disposeBanner();

    expect(service.hasBanner, isFalse);
    expect(service.buildBannerWidget(), isNull);
  });

  test('banner widget preserves slot key and identifies its ad widget', () {
    final banner = BannerAd(
      adUnitId: 'banner-id',
      size: AdSize.banner,
      request: const AdRequest(),
      listener: const BannerAdListener(),
    );
    final service = HCAdService.initializedForTest(
      config: enabledConfig,
      banner: banner,
    );
    const slotKey = ValueKey<String>('slot');

    final widget = service.buildBannerWidget(key: slotKey)! as SizedBox;
    final adWidget = widget.child! as AdWidget;

    expect(widget.key, slotKey);
    expect(adWidget.key, ValueKey<BannerAd>(banner));
  });
}
