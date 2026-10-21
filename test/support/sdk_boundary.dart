// SDK 9's own tests use this manager/codec to exercise real Dart SDK objects.
// Imports remain test-only; production has no SDK abstraction or internal import.
// ignore_for_file: implementation_imports
import 'dart:async';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:google_mobile_ads/google_mobile_ads.dart';
import 'package:google_mobile_ads/src/ad_instance_manager.dart';
import 'package:google_mobile_ads/src/ump/user_messaging_codec.dart';
import 'package:honeycube_game_ads/honeycube_game_ads.dart';

HCAdConfig config({
  String banner = 'banner',
  String rewarded = 'rewarded',
  String interstitial = 'interstitial',
  String app = 'app',
  bool enabled = true,
  TargetPlatform platform = TargetPlatform.android,
}) => HCAdConfig(
  enabled: enabled,
  platform: platform,
  admob: HCAdMobConfig(
    androidAppId: app,
    androidBannerId: banner,
    androidRewardedId: rewarded,
    androidInterstitialId: interstitial,
  ),
);

Future<void> flush() => Future<void>.delayed(Duration.zero);

class SdkBoundary {
  final calls = <MethodCall>[];
  final umpCalls = <String>[];
  final failures = <String>{};
  final held = <String, Completer<Object?>>{};
  bool ready = true;
  int privacy = 0;
  static final ump = MethodChannel(
    'plugins.flutter.io/google_mobile_ads/ump',
    StandardMethodCodec(UserMessagingCodec()),
  );

  void install() {
    instanceManager = AdInstanceManager('plugins.flutter.io/google_mobile_ads');
    final messenger =
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    messenger.setMockMethodCallHandler(instanceManager.channel, (call) async {
      calls.add(call);
      if (failures.contains(call.method)) throw PlatformException(code: '1');
      if (held.containsKey(call.method)) return held[call.method]!.future;
      if (call.method == 'MobileAds#initialize')
        return InitializationStatus({});
      return null;
    });
    messenger.setMockMethodCallHandler(ump, (call) async {
      umpCalls.add(call.method);
      if (failures.contains(call.method)) throw PlatformException(code: '1');
      if (held.containsKey(call.method)) return held[call.method]!.future;
      if (call.method == 'ConsentInformation#canRequestAds') return ready;
      if (call.method ==
          'ConsentInformation#getPrivacyOptionsRequirementStatus')
        return privacy;
      return null;
    });
  }

  void uninstall() {
    final messenger =
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    messenger.setMockMethodCallHandler(instanceManager.channel, null);
    messenger.setMockMethodCallHandler(ump, null);
  }

  int count(String method) => calls.where((c) => c.method == method).length;
  int id(String method, [int index = 0]) =>
      calls.where((c) => c.method == method).elementAt(index).arguments['adId']
          as int;
  T ad<T extends Ad>(int id) => instanceManager.adFor(id)! as T;

  Future<void> event(
    int id,
    String event, [
    Map<String, Object?> extra = const {},
  ]) async {
    final data = instanceManager.channel.codec.encodeMethodCall(
      MethodCall('onAdEvent', {'adId': id, 'eventName': event, ...extra}),
    );
    await TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .handlePlatformMessage(
          'plugins.flutter.io/google_mobile_ads',
          data,
          (_) {},
        );
  }

  Future<RewardedAd> loadRewarded(HCAdService service) async {
    final loading = service.loadRewarded();
    await flush();
    final adId = id('loadRewardedAd', count('loadRewardedAd') - 1);
    final result = ad<RewardedAd>(adId);
    await event(adId, 'onAdLoaded');
    expect(await loading, HCAdLoadResult.loaded);
    return result;
  }

  Future<InterstitialAd> loadInterstitial(HCAdService service) async {
    final loading = service.loadInterstitial();
    await flush();
    final adId = id('loadInterstitialAd', count('loadInterstitialAd') - 1);
    final result = ad<InterstitialAd>(adId);
    await event(adId, 'onAdLoaded');
    expect(await loading, HCAdLoadResult.loaded);
    return result;
  }
}
