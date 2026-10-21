import 'dart:async';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:google_mobile_ads/google_mobile_ads.dart';
import 'package:honeycube_game_ads/honeycube_game_ads.dart';
import 'support/sdk_boundary.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late SdkBoundary sdk;
  late HCAdService service;
  var disposedInWidget = false;
  setUp(() {
    disposedInWidget = false;
    sdk = SdkBoundary()..install();
    service = HCAdService.initializedForTest(config: config());
  });
  tearDown(() async {
    if (!disposedInWidget) await service.dispose();
    sdk.uninstall();
  });

  test('fullscreen ids are independent from banner', () async {
    service = HCAdService.initializedForTest(config: config(banner: ''));
    expect(service.isEnabled, isTrue);
    expect(await service.loadBanner(), HCAdLoadResult.disabled);
    await sdk.loadRewarded(service);
    await sdk.loadInterstitial(service);
    expect(sdk.count('loadBannerAd'), 0);
  });

  test('each absent id blocks only its format', () async {
    service = HCAdService.initializedForTest(config: config(rewarded: ''));
    expect(await service.loadRewarded(), HCAdLoadResult.disabled);
    expect(await service.showRewarded(), HCAdShowResult.disabled);
    await sdk.loadInterstitial(service);
    expect(sdk.count('loadRewardedAd'), 0);
    await service.dispose();
    service = HCAdService.initializedForTest(config: config(interstitial: ''));
    expect(await service.loadInterstitial(), HCAdLoadResult.disabled);
    expect(await service.showInterstitial(), HCAdShowResult.disabled);
    await sdk.loadRewarded(service);
  });

  test(
    'optional callbacks preserve no argument calls and original enums',
    () async {
      service = HCAdService(config: const HCAdConfig.disabled());
      expect(
        await service.showRewarded(
          onShown: () {},
          onRewardEarned: () {},
          onImpression: () {},
        ),
        HCAdShowResult.disabled,
      );
      expect(
        await service.showInterstitial(onShown: () {}, onImpression: () {}),
        HCAdShowResult.disabled,
      );
      expect(await service.showRewarded(), HCAdShowResult.disabled);
      expect(await service.showInterstitial(), HCAdShowResult.disabled);
      expect(HCAdInitializeResult.values.map((v) => v.name), [
        'disabled',
        'initialized',
        'failed',
      ]);
      expect(HCAdLoadResult.values.map((v) => v.name), [
        'disabled',
        'notInitialized',
        'loaded',
        'failed',
      ]);
      expect(HCAdShowResult.values.map((v) => v.name), [
        'disabled',
        'notInitialized',
        'notLoaded',
        'dismissed',
        'rewarded',
        'failed',
      ]);
    },
  );

  test(
    'real SDK shown earned impression arrive immediately once in SDK order',
    () async {
      final ad = await sdk.loadRewarded(service);
      final id = sdk.id('loadRewardedAd');
      final events = <String>[];
      var completed = false;
      final showing = service.showRewarded(
        onShown: () => events.add('shown'),
        onRewardEarned: () => events.add('earned'),
        onImpression: () => events.add('impression'),
      );
      showing.then((_) => completed = true);
      await sdk.event(id, 'onAdShowedFullScreenContent');
      expect(events, ['shown']);
      await sdk.event(id, 'onRewardedAdUserEarnedReward', {
        'rewardItem': RewardItem(1, 'coin'),
      });
      expect(events, ['shown', 'earned']);
      await sdk.event(id, 'onAdImpression');
      expect(events, ['shown', 'earned', 'impression']);
      expect(completed, isFalse);
      await sdk.event(id, 'onAdShowedFullScreenContent');
      await sdk.event(id, 'onRewardedAdUserEarnedReward', {
        'rewardItem': RewardItem(1, 'coin'),
      });
      await sdk.event(id, 'onAdImpression');
      expect(events, ['shown', 'earned', 'impression']);
      await sdk.event(id, 'onAdDismissedFullScreenContent');
      expect(await showing, HCAdShowResult.rewarded);
      ad.onUserEarnedRewardCallback!(ad, RewardItem(1, 'coin'));
      ad.fullScreenContentCallback!.onAdImpression!(ad);
      expect(events, ['shown', 'earned', 'impression']);
      expect(sdk.count('disposeAd'), 1);
    },
  );

  test('earned then failure retains receipt and final failed enum', () async {
    final ad = await sdk.loadRewarded(service);
    var receipts = 0;
    final result = service.showRewarded(onRewardEarned: () => receipts++);
    ad.onUserEarnedRewardCallback!(ad, RewardItem(1, 'coin'));
    ad.fullScreenContentCallback!.onAdFailedToShowFullScreenContent!(
      ad,
      AdError(1, 'test', 'failure'),
    );
    expect(receipts, 1);
    expect(await result, HCAdShowResult.failed);
    ad.onUserEarnedRewardCallback!(ad, RewardItem(1, 'coin'));
    expect(receipts, 1);
  });

  test('bare dismiss invents no shown reward or impression', () async {
    final ad = await sdk.loadRewarded(service);
    final events = <String>[];
    final result = service.showRewarded(
      onShown: () => events.add('shown'),
      onRewardEarned: () => events.add('earned'),
      onImpression: () => events.add('impression'),
    );
    ad.fullScreenContentCallback!.onAdDismissedFullScreenContent!(ad);
    expect(await result, HCAdShowResult.dismissed);
    expect(events, isEmpty);
  });

  test(
    'observer exceptions do not prevent receipt cleanup or next show',
    () async {
      final ad = await sdk.loadRewarded(service);
      var calls = 0;
      void observer() {
        calls++;
        throw StateError('observer');
      }

      final showing = service.showRewarded(
        onShown: observer,
        onRewardEarned: observer,
        onImpression: observer,
      );
      ad.fullScreenContentCallback!.onAdShowedFullScreenContent!(ad);
      ad.onUserEarnedRewardCallback!(ad, RewardItem(1, 'coin'));
      ad.fullScreenContentCallback!.onAdImpression!(ad);
      ad.fullScreenContentCallback!.onAdDismissedFullScreenContent!(ad);
      expect(await showing, HCAdShowResult.rewarded);
      expect(calls, 3);
      final next = await sdk.loadInterstitial(service);
      final nextResult = service.showInterstitial();
      next.fullScreenContentCallback!.onAdDismissedFullScreenContent!(next);
      expect(await nextResult, HCAdShowResult.dismissed);
    },
  );

  test(
    'interstitial events are independent and ignore closed callbacks',
    () async {
      final ad = await sdk.loadInterstitial(service);
      final events = <String>[];
      final result = service.showInterstitial(
        onShown: () => events.add('shown'),
        onImpression: () => events.add('impression'),
      );
      ad.fullScreenContentCallback!.onAdImpression!(ad);
      ad.fullScreenContentCallback!.onAdShowedFullScreenContent!(ad);
      ad.fullScreenContentCallback!.onAdImpression!(ad);
      expect(events, ['impression', 'shown']);
      ad.fullScreenContentCallback!.onAdDismissedFullScreenContent!(ad);
      ad.fullScreenContentCallback!.onAdShowedFullScreenContent!(ad);
      expect(await result, HCAdShowResult.dismissed);
      expect(events, ['impression', 'shown']);
    },
  );

  test(
    'cross format and repeated show share one full screen lifetime',
    () async {
      final rewarded = await sdk.loadRewarded(service);
      final interstitial = await sdk.loadInterstitial(service);
      final first = service.showRewarded();
      expect(await service.showRewarded(), HCAdShowResult.failed);
      expect(await service.showInterstitial(), HCAdShowResult.failed);
      expect(service.hasInterstitial, isTrue);
      expect(sdk.count('showAdWithoutView'), 1);
      rewarded.fullScreenContentCallback!.onAdDismissedFullScreenContent!(
        rewarded,
      );
      await first;
      final second = service.showInterstitial();
      interstitial.fullScreenContentCallback!.onAdDismissedFullScreenContent!(
        interstitial,
      );
      expect(await second, HCAdShowResult.dismissed);
      expect(sdk.count('showAdWithoutView'), 2);
    },
  );

  for (final format in ['rewarded', 'interstitial', 'banner']) {
    test(
      '$format overlapping loads coalesce and loaded ad is reused',
      () async {
        Future<HCAdLoadResult> load() => switch (format) {
          'rewarded' => service.loadRewarded(),
          'interstitial' => service.loadInterstitial(),
          _ => service.loadBanner(),
        };
        final method = switch (format) {
          'rewarded' => 'loadRewardedAd',
          'interstitial' => 'loadInterstitialAd',
          _ => 'loadBannerAd',
        };
        final first = load();
        final second = load();
        await flush();
        expect(sdk.count(method), 1);
        await sdk.event(sdk.id(method), 'onAdLoaded');
        expect(await first, HCAdLoadResult.loaded);
        expect(await second, HCAdLoadResult.loaded);
        expect(await load(), HCAdLoadResult.loaded);
        expect(sdk.count(method), 1);
      },
    );

    test(
      '$format late success after disposal is released and cannot resurrect',
      () async {
        final method = switch (format) {
          'rewarded' => 'loadRewardedAd',
          'interstitial' => 'loadInterstitialAd',
          _ => 'loadBannerAd',
        };
        final pending = switch (format) {
          'rewarded' => service.loadRewarded(),
          'interstitial' => service.loadInterstitial(),
          _ => service.loadBanner(),
        };
        await flush();
        final ad = sdk.ad<Ad>(sdk.id(method));
        await service.dispose();
        expect(await pending, HCAdLoadResult.failed);
        if (ad is RewardedAd) ad.rewardedAdLoadCallback.onAdLoaded(ad);
        if (ad is InterstitialAd) ad.adLoadCallback.onAdLoaded(ad);
        if (ad is BannerAd) ad.listener.onAdLoaded!(ad);
        await flush();
        expect(
          service.hasBanner || service.hasRewarded || service.hasInterstitial,
          isFalse,
        );
        expect(sdk.count('disposeAd'), 1);
        expect(await service.initialize(), HCAdInitializeResult.failed);
        expect(await service.loadRewarded(), HCAdLoadResult.failed);
        expect(await service.showRewarded(), HCAdShowResult.failed);
      },
    );

    testWidgets(
      '$format timeout then inverse completion never replaces newer ad',
      (tester) async {
        final method = switch (format) {
          'rewarded' => 'loadRewardedAd',
          'interstitial' => 'loadInterstitialAd',
          _ => 'loadBannerAd',
        };
        Future<HCAdLoadResult> load() => switch (format) {
          'rewarded' => service.loadRewarded(),
          'interstitial' => service.loadInterstitial(),
          _ => service.loadBanner(),
        };
        void loaded(Ad ad) {
          if (ad is RewardedAd) ad.rewardedAdLoadCallback.onAdLoaded(ad);
          if (ad is InterstitialAd) ad.adLoadCallback.onAdLoaded(ad);
          if (ad is BannerAd) ad.listener.onAdLoaded!(ad);
        }

        final old = load();
        await tester.pump();
        final oldAd = sdk.ad<Ad>(sdk.id(method));
        await tester.pump(const Duration(seconds: 31));
        expect(await old, HCAdLoadResult.failed);
        final next = load();
        await tester.pump();
        final nextAd = sdk.ad<Ad>(sdk.id(method, 1));
        loaded(nextAd);
        await tester.pump();
        expect(await next, HCAdLoadResult.loaded);
        loaded(oldAd);
        await tester.pump();
        expect(await load(), HCAdLoadResult.loaded);
        expect(sdk.count(method), 2);
        expect(sdk.count('disposeAd'), 1);
        final disposing = service.dispose();
        await tester.pump();
        await disposing;
        disposedInWidget = true;
      },
    );
  }

  test(
    'banner cancellation allows new load and rejects reversed old callback',
    () async {
      final old = service.loadBanner();
      await flush();
      final oldAd = sdk.ad<BannerAd>(sdk.id('loadBannerAd'));
      await service.disposeBanner();
      expect(await old, HCAdLoadResult.failed);
      final next = service.loadBanner();
      await flush();
      final nextAd = sdk.ad<BannerAd>(sdk.id('loadBannerAd', 1));
      nextAd.listener.onAdLoaded!(nextAd);
      expect(await next, HCAdLoadResult.loaded);
      oldAd.listener.onAdLoaded!(oldAd);
      expect(service.hasBanner, isTrue);
      expect(sdk.count('disposeAd'), 1);
    },
  );

  test(
    'dispose during show completes failed and all late observers are ignored',
    () async {
      final ad = await sdk.loadRewarded(service);
      var events = 0;
      final result = service.showRewarded(
        onShown: () => events++,
        onRewardEarned: () => events++,
        onImpression: () => events++,
      );
      await service.dispose();
      expect(await result, HCAdShowResult.failed);
      ad.fullScreenContentCallback!.onAdShowedFullScreenContent!(ad);
      ad.onUserEarnedRewardCallback!(ad, RewardItem(1, 'coin'));
      ad.fullScreenContentCallback!.onAdImpression!(ad);
      expect(events, 0);
      expect(sdk.count('disposeAd'), 1);
    },
  );

  test(
    'native show and native dispose exceptions complete and release all formats',
    () async {
      await sdk.loadRewarded(service);
      await sdk.loadInterstitial(service);
      sdk.failures.addAll(['showAdWithoutView', 'disposeAd']);
      expect(await service.showRewarded(), HCAdShowResult.failed);
      await service.dispose();
      expect(service.hasRewarded || service.hasInterstitial, isFalse);
      expect(sdk.count('disposeAd'), 2);
    },
  );

  for (final cancellation in ['timeout', 'disposeBanner']) {
    testWidgets('banner $cancellation late native error preserves next load', (
      tester,
    ) async {
      final oldNative = Completer<Object?>();
      sdk.held['loadBannerAd'] = oldNative;
      try {
        final old = service.loadBanner();
        await tester.pump();
        if (cancellation == 'timeout') {
          await tester.pump(const Duration(seconds: 31));
        } else {
          final cancel = service.disposeBanner();
          await tester.pump();
          await cancel;
        }
        expect(await old, HCAdLoadResult.failed);
        expect(sdk.count('loadBannerAd'), 1);
        sdk.held.remove('loadBannerAd');
        final next = service.loadBanner();
        await tester.pump();
        final nextId = sdk.id('loadBannerAd', 1);
        final nextAd = sdk.ad<BannerAd>(nextId);
        oldNative.completeError(PlatformException(code: 'late-old-error'));
        await tester.pump();
        expect(
          sdk.calls.where(
            (call) =>
                call.method == 'disposeAd' && call.arguments['adId'] == nextId,
          ),
          isEmpty,
          reason: 'a stale request must not dispose the next banner',
        );
        await sdk.event(nextId, 'onAdLoaded');
        expect(await next, HCAdLoadResult.loaded);
        expect(service.hasBanner, isTrue);
        expect(sdk.ad<BannerAd>(nextId), same(nextAd));
        expect(sdk.count('loadBannerAd'), 2);
      } finally {
        if (!oldNative.isCompleted) oldNative.complete(null);
        final disposing = service.dispose();
        await tester.pump();
        await disposing;
        disposedInWidget = true;
      }
    });
  }
  test('native load error fails without waiting for timeout', () async {
    sdk.failures.add('loadBannerAd');
    expect(await service.loadBanner(), HCAdLoadResult.failed);
    expect(sdk.count('disposeAd'), 1);
  });

  testWidgets('timeout works even if native load method has not returned', (
    tester,
  ) async {
    sdk.held['loadRewardedAd'] = Completer<Object?>();
    final pending = service.loadRewarded();
    await tester.pump();
    final ad = sdk.ad<RewardedAd>(sdk.id('loadRewardedAd'));
    await tester.pump(const Duration(seconds: 31));
    expect(await pending, HCAdLoadResult.failed);
    ad.rewardedAdLoadCallback.onAdLoaded(ad);
    sdk.held['loadRewardedAd']!.complete(null);
    await tester.pump();
    expect(service.hasRewarded, isFalse);
    expect(sdk.count('disposeAd'), 1);
    final disposing = service.dispose();
    await tester.pump();
    await disposing;
    disposedInWidget = true;
  });
}
