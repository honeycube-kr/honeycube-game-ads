import 'dart:async';
import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:google_mobile_ads/google_mobile_ads.dart';
import 'package:honeycube_game_ads/honeycube_game_ads.dart';
import 'support/sdk_boundary.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late SdkBoundary sdk;
  late HCAdService service;
  setUp(() {
    sdk = SdkBoundary()..install();
    service = HCAdService(config: config());
  });
  tearDown(() async {
    await service.dispose();
    sdk.uninstall();
  });
  const update = 'ConsentInformation#requestConsentInfoUpdate';
  const form = 'UserMessagingPlatform#loadAndShowConsentFormIfRequired';
  const canRequest = 'ConsentInformation#canRequestAds';
  const options = 'ConsentInformation#getPrivacyOptionsRequirementStatus';
  const privacyForm = 'UserMessagingPlatform#showPrivacyOptionsForm';

  test(
    'initialization performs update then form then native readiness before SDK init',
    () async {
      expect(await service.initialize(), HCAdInitializeResult.initialized);
      expect(sdk.umpCalls, [update, form, canRequest, options]);
      expect(service.isConsentReady, isTrue);
      expect(sdk.count('MobileAds#initialize'), 1);
      expect(await service.initialize(), HCAdInitializeResult.initialized);
      expect(await service.prepareConsent(), HCAdConsentResult.ready);
      expect(sdk.umpCalls.where((c) => c == update).length, 1);
      expect(sdk.count('MobileAds#initialize'), 1);
    },
  );

  test(
    'each new service refreshes UMP rather than trusting app persistence',
    () async {
      await service.initialize();
      await service.dispose();
      service = HCAdService(config: config());
      expect(await service.initialize(), HCAdInitializeResult.initialized);
      expect(sdk.umpCalls.where((c) => c == update).length, 2);
    },
  );

  test(
    'pending UMP keeps all ad requests and shows unavailable and coalesces init',
    () async {
      sdk.held[update] = Completer<Object?>();
      final first = service.initialize();
      final second = service.initialize();
      final consent = service.prepareConsent();
      await flush();
      expect(await service.loadRewarded(), HCAdLoadResult.notInitialized);
      expect(await service.loadInterstitial(), HCAdLoadResult.notInitialized);
      expect(await service.loadBanner(), HCAdLoadResult.notInitialized);
      expect(await service.showRewarded(), HCAdShowResult.notInitialized);
      expect(await service.showInterstitial(), HCAdShowResult.notInitialized);
      expect(sdk.calls, isEmpty);
      expect(sdk.umpCalls, [update]);
      sdk.held[update]!.complete(null);
      expect(await consent, HCAdConsentResult.ready);
      expect(await first, HCAdInitializeResult.initialized);
      expect(await second, HCAdInitializeResult.initialized);
      expect(sdk.count('MobileAds#initialize'), 1);
    },
  );

  for (final failing in [update, form]) {
    test(
      '$failing failure may use only SDK-verified prior readiness',
      () async {
        sdk.failures.add(failing);
        expect(await service.initialize(), HCAdInitializeResult.initialized);
        expect(service.isConsentReady, isTrue);
        expect(sdk.umpCalls, contains(canRequest));
        if (failing == update) expect(sdk.umpCalls, isNot(contains(form)));
      },
    );
    test(
      '$failing failure without SDK readiness returns failed without rewards',
      () async {
        sdk.failures.add(failing);
        sdk.ready = false;
        expect(await service.prepareConsent(), HCAdConsentResult.failed);
        expect(await service.initialize(), HCAdInitializeResult.failed);
        expect(await service.loadRewarded(), HCAdLoadResult.notInitialized);
        var earned = false;
        expect(
          await service.showRewarded(onRewardEarned: () => earned = true),
          HCAdShowResult.notInitialized,
        );
        expect(earned, isFalse);
        expect(sdk.calls, isEmpty);
      },
    );
  }

  test(
    'successful consent with canRequest false is unavailable until explicit refresh',
    () async {
      sdk.ready = false;
      expect(await service.prepareConsent(), HCAdConsentResult.unavailable);
      expect(await service.initialize(), HCAdInitializeResult.failed);
      expect(sdk.calls, isEmpty);
      sdk.ready = true;
      expect(await service.updateConsent(), HCAdConsentResult.ready);
      expect(await service.initialize(), HCAdInitializeResult.initialized);
      expect(sdk.umpCalls.where((c) => c == update).length, 2);
    },
  );

  test(
    'readiness lookup errors fail closed and explicit update can recover',
    () async {
      sdk.failures.add(canRequest);
      expect(await service.initialize(), HCAdInitializeResult.failed);
      expect(service.isConsentReady, isFalse);
      expect(sdk.calls, isEmpty);
      sdk.failures.clear();
      expect(await service.updateConsent(), HCAdConsentResult.ready);
      expect(await service.initialize(), HCAdInitializeResult.initialized);
    },
  );

  test('privacy entry point is only available when SDK requires it', () async {
    expect(await service.showPrivacyOptions(), HCAdConsentResult.unavailable);
    expect(sdk.umpCalls, isEmpty);
    await service.initialize();
    expect(service.isPrivacyOptionsRequired, isFalse);
    expect(await service.showPrivacyOptions(), HCAdConsentResult.unavailable);
    expect(sdk.umpCalls, isNot(contains(privacyForm)));
    sdk.privacy = 1;
    await service.updateConsent();
    expect(service.isPrivacyOptionsRequired, isTrue);
    expect(await service.showPrivacyOptions(), HCAdConsentResult.ready);
    expect(sdk.umpCalls.lastIndexOf(privacyForm), greaterThan(0));
  });

  test(
    'privacy form uses host guard for entire async lifetime and coalesces duplicate requests',
    () async {
      sdk.privacy = 1;
      final guard = <String>[];
      service = HCAdService(
        config: config(),
        presentConsentForm: (present) async {
          guard.add('pause');
          try {
            await present();
          } finally {
            guard.add('restore');
          }
        },
      );
      await service.initialize();
      guard.clear();
      sdk.held[privacyForm] = Completer<Object?>();
      final first = service.showPrivacyOptions();
      final second = service.showPrivacyOptions();
      await flush();
      expect(guard, ['pause']);
      expect(service.isConsentReady, isFalse);
      expect(await service.loadRewarded(), HCAdLoadResult.notInitialized);
      sdk.ready = false;
      sdk.held[privacyForm]!.complete(null);
      expect(await first, HCAdConsentResult.unavailable);
      expect(await second, HCAdConsentResult.unavailable);
      expect(guard, ['pause', 'restore']);
      expect(sdk.umpCalls.where((c) => c == privacyForm).length, 1);
      expect(service.isConsentReady, isFalse);
    },
  );

  test(
    'privacy form error rechecks SDK readiness and restores presentation guard',
    () async {
      sdk.privacy = 1;
      var restored = false;
      service = HCAdService(
        config: config(),
        presentConsentForm: (present) async {
          try {
            await present();
          } finally {
            restored = true;
          }
        },
      );
      await service.initialize();
      restored = false;
      sdk.failures.add(privacyForm);
      sdk.ready = false;
      expect(await service.showPrivacyOptions(), HCAdConsentResult.failed);
      expect(restored, isTrue);
      expect(service.isConsentReady, isFalse);
    },
  );

  test('guard exception fails readiness and no SDK request is made', () async {
    service = HCAdService(
      config: config(),
      presentConsentForm: (_) async {
        throw StateError('guard');
      },
    );
    expect(await service.initialize(), HCAdInitializeResult.failed);
    expect(service.isConsentReady, isFalse);
    expect(sdk.calls, isEmpty);
    expect(sdk.umpCalls, [update]);
  });

  test(
    'consent refresh discards loaded fullscreen and pending request generations',
    () async {
      await service.initialize();
      final old = await sdk.loadRewarded(service);
      final pending = service.loadInterstitial();
      await flush();
      final late = sdk.ad<InterstitialAd>(sdk.id('loadInterstitialAd'));
      sdk.held[update] = Completer<Object?>();
      final refresh = service.updateConsent();
      await flush();
      expect(await pending, HCAdLoadResult.failed);
      expect(service.hasRewarded || service.hasInterstitial, isFalse);
      sdk.held[update]!.complete(null);
      expect(await refresh, HCAdConsentResult.ready);
      late.adLoadCallback.onAdLoaded(late);
      await flush();
      expect(service.hasInterstitial, isFalse);
      expect(sdk.count('disposeAd'), 2);
      expect(old, isA<RewardedAd>());
      expect(await service.showRewarded(), HCAdShowResult.notLoaded);
    },
  );

  test('consent form cannot overlap active fullscreen show', () async {
    await service.initialize();
    sdk.privacy = 1;
    await service.updateConsent();
    final ad = await sdk.loadRewarded(service);
    final showing = service.showRewarded();
    final updates = sdk.umpCalls.length;
    expect(await service.updateConsent(), HCAdConsentResult.failed);
    expect(await service.showPrivacyOptions(), HCAdConsentResult.failed);
    expect(sdk.umpCalls.length, updates);
    ad.fullScreenContentCallback!.onAdDismissedFullScreenContent!(ad);
    await showing;
  });

  test(
    'dispose while refreshing prevents late init/readiness resurrection',
    () async {
      sdk.held[update] = Completer<Object?>();
      final init = service.initialize();
      await flush();
      await service.dispose();
      sdk.held[update]!.complete(null);
      expect(await init, HCAdInitializeResult.failed);
      expect(service.isInitialized || service.isConsentReady, isFalse);
      expect(await service.updateConsent(), HCAdConsentResult.failed);
      expect(sdk.calls, isEmpty);
      expect(sdk.umpCalls, [update]);
    },
  );

  test(
    'dispose during native form keeps host guard until real dismissal',
    () async {
      final guard = <String>[];
      service = HCAdService(
        config: config(),
        presentConsentForm: (present) async {
          guard.add('pause');
          try {
            await present();
          } finally {
            guard.add('restore');
          }
        },
      );
      sdk.held[form] = Completer<Object?>();
      final init = service.initialize();
      await flush();
      expect(guard, ['pause']);
      await service.dispose();
      expect(guard, ['pause']);
      sdk.held[form]!.complete(null);
      expect(await init, HCAdInitializeResult.failed);
      expect(guard, ['pause', 'restore']);
      expect(sdk.calls, isEmpty);
      expect(service.isConsentReady, isFalse);
    },
  );

  test(
    'dispose during native initialization rejects late completion',
    () async {
      sdk.held['MobileAds#initialize'] = Completer<Object?>();
      final init = service.initialize();
      await flush();
      expect(sdk.count('MobileAds#initialize'), 1);
      await service.dispose();
      sdk.held['MobileAds#initialize']!.complete(InitializationStatus({}));
      expect(await init, HCAdInitializeResult.failed);
      expect(service.isInitialized, isFalse);
    },
  );

  test('different consent operations do not falsely coalesce', () async {
    sdk.privacy = 1;
    await service.initialize();
    sdk.held[privacyForm] = Completer<Object?>();
    final showing = service.showPrivacyOptions();
    await flush();
    expect(await service.updateConsent(), HCAdConsentResult.failed);
    sdk.held[privacyForm]!.complete(null);
    expect(await showing, HCAdConsentResult.ready);
  });
  for (final cfg in [
    config(enabled: false),
    config(platform: TargetPlatform.iOS),
    config(app: ''),
  ]) {
    test(
      'disabled or unsupported configuration never enters native UMP/ads ${cfg.debugSummary}',
      () async {
        service = HCAdService(config: cfg);
        expect(await service.prepareConsent(), HCAdConsentResult.disabled);
        expect(await service.initialize(), HCAdInitializeResult.disabled);
        expect(await service.loadRewarded(), HCAdLoadResult.disabled);
        expect(await service.showRewarded(), HCAdShowResult.disabled);
        expect(sdk.umpCalls, isEmpty);
        expect(sdk.calls, isEmpty);
      },
    );
  }
}
