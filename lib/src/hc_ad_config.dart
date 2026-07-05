import 'package:flutter/foundation.dart';

final class HCAdConfig {
  const HCAdConfig({
    required this.enabled,
    required this.admob,
    required this.platform,
  });

  factory HCAdConfig.fromDartDefine({TargetPlatform? platform}) {
    return HCAdConfig(
      enabled: const bool.fromEnvironment('ADS_ENABLED', defaultValue: false),
      admob: const HCAdMobConfig(
        androidAppId: String.fromEnvironment('ADMOB_ANDROID_APP_ID'),
        androidBannerId: String.fromEnvironment('ADMOB_ANDROID_BANNER_ID'),
        androidRewardedId: String.fromEnvironment('ADMOB_ANDROID_REWARDED_ID'),
        androidInterstitialId: String.fromEnvironment(
          'ADMOB_ANDROID_INTERSTITIAL_ID',
        ),
      ),
      platform: platform ?? defaultTargetPlatform,
    );
  }

  const HCAdConfig.disabled()
    : enabled = false,
      admob = null,
      platform = TargetPlatform.android;

  final bool enabled;
  final HCAdMobConfig? admob;
  final TargetPlatform platform;

  bool get isSupportedPlatform => platform == TargetPlatform.android;

  bool get canRequestAds =>
      enabled && isSupportedPlatform && (admob?.hasRequiredIds ?? false);

  String get debugSummary {
    final admob = this.admob;
    return 'enabled=$enabled platform=${platform.name} supported=$isSupportedPlatform '
        'admob=${admob != null} appId=${admob?.androidAppId.isNotEmpty ?? false} '
        'bannerId=${admob?.androidBannerId.isNotEmpty ?? false} '
        'rewardedId=${admob?.androidRewardedId.isNotEmpty ?? false} '
        'interstitialId=${admob?.androidInterstitialId.isNotEmpty ?? false} '
        'canRequest=$canRequestAds';
  }
}

final class HCAdMobConfig {
  const HCAdMobConfig({
    required this.androidAppId,
    required this.androidBannerId,
    required this.androidRewardedId,
    required this.androidInterstitialId,
  });

  final String androidAppId;
  final String androidBannerId;
  final String androidRewardedId;
  final String androidInterstitialId;

  bool get hasRequiredIds =>
      androidAppId.isNotEmpty &&
      androidBannerId.isNotEmpty &&
      androidRewardedId.isNotEmpty &&
      androidInterstitialId.isNotEmpty;
}
