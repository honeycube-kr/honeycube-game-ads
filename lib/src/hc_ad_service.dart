import 'dart:async';

import 'package:flutter/widgets.dart';
import 'package:google_mobile_ads/google_mobile_ads.dart';
import 'package:honeycube_game_ads/src/hc_ad_config.dart';
import 'package:honeycube_game_ads/src/hc_ad_result.dart';

class HCAdService {
  HCAdService({HCAdConfig? config})
    : config = config ?? HCAdConfig.fromDartDefine(),
      _initialized = false;

  HCAdService.initializedForTest({required this.config, BannerAd? banner})
    : _initialized = true,
      _bannerAd = banner;

  final HCAdConfig config;
  bool _initialized;
  BannerAd? _bannerAd;
  RewardedAd? _rewardedAd;
  InterstitialAd? _interstitialAd;

  static const Duration _adLoadTimeout = Duration(seconds: 30);

  bool get isEnabled => config.canRequestAds;
  bool get isInitialized => _initialized;
  bool get hasBanner => _bannerAd != null;
  bool get hasRewarded => _rewardedAd != null;
  bool get hasInterstitial => _interstitialAd != null;

  Widget? buildBannerWidget({Key? key}) {
    final ad = _bannerAd;
    if (ad == null) return null;
    return SizedBox(
      key: key,
      width: ad.size.width.toDouble(),
      height: ad.size.height.toDouble(),
      child: AdWidget(key: ValueKey<BannerAd>(ad), ad: ad),
    );
  }

  Future<HCAdInitializeResult> initialize() async {
    if (!config.canRequestAds) {
      return HCAdInitializeResult.disabled;
    }
    if (_initialized) {
      return HCAdInitializeResult.initialized;
    }
    try {
      await MobileAds.instance.initialize();
      _initialized = true;
      return HCAdInitializeResult.initialized;
    } catch (_) {
      return HCAdInitializeResult.failed;
    }
  }

  Future<HCAdLoadResult> loadBanner() async {
    if (!config.canRequestAds) {
      return HCAdLoadResult.disabled;
    }
    if (!_initialized) {
      return HCAdLoadResult.notInitialized;
    }
    if (_bannerAd != null) {
      return HCAdLoadResult.loaded;
    }
    final completer = Completer<HCAdLoadResult>();
    late final BannerAd ad;
    const size = AdSize.banner;
    ad = BannerAd(
      adUnitId: config.admob!.androidBannerId,
      size: size,
      request: const AdRequest(),
      listener: BannerAdListener(
        onAdLoaded: (loadedAd) async {
          if (completer.isCompleted) {
            await loadedAd.dispose();
            return;
          }
          _bannerAd = loadedAd as BannerAd;
          _completeOnce(completer, HCAdLoadResult.loaded);
        },
        onAdFailedToLoad: (failedAd, error) async {
          await failedAd.dispose();
          _completeOnce(completer, HCAdLoadResult.failed);
        },
      ),
    );

    try {
      await ad.load();
    } catch (_) {
      await ad.dispose();
      _completeOnce(completer, HCAdLoadResult.failed);
    }
    return _waitForLoadResult(completer, onTimeout: ad.dispose);
  }

  Future<HCAdLoadResult> loadRewarded() async {
    if (!config.canRequestAds) {
      return HCAdLoadResult.disabled;
    }
    if (!_initialized) {
      return HCAdLoadResult.notInitialized;
    }

    await _rewardedAd?.dispose();
    _rewardedAd = null;
    final completer = Completer<HCAdLoadResult>();
    try {
      await RewardedAd.load(
        adUnitId: config.admob!.androidRewardedId,
        request: const AdRequest(),
        rewardedAdLoadCallback: RewardedAdLoadCallback(
          onAdLoaded: (ad) {
            if (completer.isCompleted) {
              unawaited(ad.dispose());
              return;
            }
            _rewardedAd = ad;
            _completeOnce(completer, HCAdLoadResult.loaded);
          },
          onAdFailedToLoad: (error) {
            _completeOnce(completer, HCAdLoadResult.failed);
          },
        ),
      );
    } catch (_) {
      _completeOnce(completer, HCAdLoadResult.failed);
    }
    return _waitForLoadResult(completer);
  }

  Future<HCAdShowResult> showRewarded() async {
    if (!config.canRequestAds) {
      return HCAdShowResult.disabled;
    }
    if (!_initialized) {
      return HCAdShowResult.notInitialized;
    }
    final ad = _rewardedAd;
    if (ad == null) {
      return HCAdShowResult.notLoaded;
    }
    _rewardedAd = null;

    var rewarded = false;
    final completer = Completer<HCAdShowResult>();
    ad.fullScreenContentCallback = FullScreenContentCallback(
      onAdFailedToShowFullScreenContent: (failedAd, error) async {
        await failedAd.dispose();
        _completeOnce(completer, HCAdShowResult.failed);
      },
      onAdDismissedFullScreenContent: (dismissedAd) async {
        await dismissedAd.dispose();
        _completeOnce(
          completer,
          rewarded ? HCAdShowResult.rewarded : HCAdShowResult.dismissed,
        );
      },
    );

    try {
      await ad.show(onUserEarnedReward: (_, _) => rewarded = true);
    } catch (_) {
      await ad.dispose();
      _completeOnce(completer, HCAdShowResult.failed);
    }
    return completer.future;
  }

  Future<HCAdLoadResult> loadInterstitial() async {
    if (!config.canRequestAds) {
      return HCAdLoadResult.disabled;
    }
    if (!_initialized) {
      return HCAdLoadResult.notInitialized;
    }

    await _interstitialAd?.dispose();
    _interstitialAd = null;
    final completer = Completer<HCAdLoadResult>();
    try {
      await InterstitialAd.load(
        adUnitId: config.admob!.androidInterstitialId,
        request: const AdRequest(),
        adLoadCallback: InterstitialAdLoadCallback(
          onAdLoaded: (ad) {
            if (completer.isCompleted) {
              unawaited(ad.dispose());
              return;
            }
            _interstitialAd = ad;
            _completeOnce(completer, HCAdLoadResult.loaded);
          },
          onAdFailedToLoad: (error) {
            _completeOnce(completer, HCAdLoadResult.failed);
          },
        ),
      );
    } catch (_) {
      _completeOnce(completer, HCAdLoadResult.failed);
    }
    return _waitForLoadResult(completer);
  }

  Future<HCAdShowResult> showInterstitial() async {
    if (!config.canRequestAds) {
      return HCAdShowResult.disabled;
    }
    if (!_initialized) {
      return HCAdShowResult.notInitialized;
    }
    final ad = _interstitialAd;
    if (ad == null) {
      return HCAdShowResult.notLoaded;
    }
    _interstitialAd = null;

    final completer = Completer<HCAdShowResult>();
    ad.fullScreenContentCallback = FullScreenContentCallback(
      onAdFailedToShowFullScreenContent: (failedAd, error) async {
        await failedAd.dispose();
        _completeOnce(completer, HCAdShowResult.failed);
      },
      onAdDismissedFullScreenContent: (dismissedAd) async {
        await dismissedAd.dispose();
        _completeOnce(completer, HCAdShowResult.dismissed);
      },
    );

    try {
      await ad.show();
    } catch (_) {
      await ad.dispose();
      _completeOnce(completer, HCAdShowResult.failed);
    }
    return completer.future;
  }

  Future<void> dispose() async {
    await disposeBanner();
    await _rewardedAd?.dispose();
    await _interstitialAd?.dispose();
    _rewardedAd = null;
    _interstitialAd = null;
  }

  Future<void> disposeBanner() async {
    final ad = _bannerAd;
    _bannerAd = null;
    await ad?.dispose();
  }

  void _completeOnce<T>(Completer<T> completer, T value) {
    if (!completer.isCompleted) {
      completer.complete(value);
    }
  }

  Future<HCAdLoadResult> _waitForLoadResult(
    Completer<HCAdLoadResult> completer, {
    Future<void> Function()? onTimeout,
  }) async {
    final timer = Timer(_adLoadTimeout, () {
      if (completer.isCompleted) {
        return;
      }
      if (onTimeout != null) {
        unawaited(onTimeout());
      }
      completer.complete(HCAdLoadResult.failed);
    });
    try {
      return await completer.future;
    } finally {
      timer.cancel();
    }
  }
}
