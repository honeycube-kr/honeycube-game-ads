import 'dart:async';

import 'package:flutter/widgets.dart';
import 'package:google_mobile_ads/google_mobile_ads.dart';
import 'package:honeycube_game_ads/src/hc_ad_config.dart';
import 'package:honeycube_game_ads/src/hc_ad_result.dart';

class HCAdService {
  HCAdService({HCAdConfig? config})
    : config = config ?? HCAdConfig.fromDartDefine(),
      _initialized = false;

  HCAdService.initializedForTest({required this.config}) : _initialized = true;

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
    if (ad == null) {
      return null;
    }
    return SizedBox(
      key: key,
      width: ad.size.width.toDouble(),
      height: ad.size.height.toDouble(),
      child: AdWidget(ad: ad),
    );
  }

  Future<HCAdInitializeResult> initialize() async {
    if (!config.canRequestAds) {
      _logInfo('initialize skipped: ${config.debugSummary}');
      return HCAdInitializeResult.disabled;
    }
    if (_initialized) {
      _logDebug('initialize skipped: already initialized');
      return HCAdInitializeResult.initialized;
    }
    try {
      _logInfo('initialize start: ${config.debugSummary}');
      await MobileAds.instance.initialize();
      _initialized = true;
      _logInfo('initialize success');
      return HCAdInitializeResult.initialized;
    } catch (error, stackTrace) {
      _logWarning('initialize failed', error, stackTrace);
      return HCAdInitializeResult.failed;
    }
  }

  Future<HCAdLoadResult> loadBanner() async {
    if (!config.canRequestAds) {
      _logInfo('banner load skipped: ${config.debugSummary}');
      return HCAdLoadResult.disabled;
    }
    if (!_initialized) {
      _logWarning('banner load skipped: not initialized');
      return HCAdLoadResult.notInitialized;
    }

    await _bannerAd?.dispose();
    _bannerAd = null;
    final completer = Completer<HCAdLoadResult>();
    late final BannerAd ad;
    const size = AdSize.banner;
    _logInfo('banner load start size=${size.width}x${size.height}');
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
          _logInfo(
            'banner load success size=${_bannerAd!.size.width}x${_bannerAd!.size.height}',
          );
          _completeOnce(completer, HCAdLoadResult.loaded);
        },
        onAdFailedToLoad: (failedAd, error) async {
          await failedAd.dispose();
          _logWarning('banner load failed: ${_formatLoadAdError(error)}');
          _completeOnce(completer, HCAdLoadResult.failed);
        },
      ),
    );

    try {
      await ad.load();
    } catch (error, stackTrace) {
      await ad.dispose();
      _logWarning('banner load threw', error, stackTrace);
      _completeOnce(completer, HCAdLoadResult.failed);
    }
    return _waitForLoadResult(completer, 'banner load', onTimeout: ad.dispose);
  }

  Future<HCAdLoadResult> loadRewarded() async {
    if (!config.canRequestAds) {
      _logInfo('rewarded load skipped: ${config.debugSummary}');
      return HCAdLoadResult.disabled;
    }
    if (!_initialized) {
      _logWarning('rewarded load skipped: not initialized');
      return HCAdLoadResult.notInitialized;
    }

    await _rewardedAd?.dispose();
    _rewardedAd = null;
    final completer = Completer<HCAdLoadResult>();
    try {
      _logInfo('rewarded load start');
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
            _logInfo('rewarded load success');
            _completeOnce(completer, HCAdLoadResult.loaded);
          },
          onAdFailedToLoad: (error) {
            _logWarning('rewarded load failed: ${_formatLoadAdError(error)}');
            _completeOnce(completer, HCAdLoadResult.failed);
          },
        ),
      );
    } catch (error, stackTrace) {
      _logWarning('rewarded load threw', error, stackTrace);
      _completeOnce(completer, HCAdLoadResult.failed);
    }
    return _waitForLoadResult(completer, 'rewarded load');
  }

  Future<HCAdShowResult> showRewarded() async {
    if (!config.canRequestAds) {
      _logInfo('rewarded show skipped: ${config.debugSummary}');
      return HCAdShowResult.disabled;
    }
    if (!_initialized) {
      _logWarning('rewarded show skipped: not initialized');
      return HCAdShowResult.notInitialized;
    }
    final ad = _rewardedAd;
    if (ad == null) {
      _logWarning('rewarded show skipped: not loaded');
      return HCAdShowResult.notLoaded;
    }
    _rewardedAd = null;

    var rewarded = false;
    final completer = Completer<HCAdShowResult>();
    ad.fullScreenContentCallback = FullScreenContentCallback(
      onAdFailedToShowFullScreenContent: (failedAd, error) async {
        await failedAd.dispose();
        _logWarning('rewarded show failed: ${_formatAdError(error)}');
        _completeOnce(completer, HCAdShowResult.failed);
      },
      onAdDismissedFullScreenContent: (dismissedAd) async {
        await dismissedAd.dispose();
        _logInfo('rewarded dismissed rewarded=$rewarded');
        _completeOnce(
          completer,
          rewarded ? HCAdShowResult.rewarded : HCAdShowResult.dismissed,
        );
      },
    );

    try {
      _logInfo('rewarded show start');
      await ad.show(onUserEarnedReward: (_, _) => rewarded = true);
    } catch (error, stackTrace) {
      await ad.dispose();
      _logWarning('rewarded show threw', error, stackTrace);
      _completeOnce(completer, HCAdShowResult.failed);
    }
    return completer.future;
  }

  Future<HCAdLoadResult> loadInterstitial() async {
    if (!config.canRequestAds) {
      _logInfo('interstitial load skipped: ${config.debugSummary}');
      return HCAdLoadResult.disabled;
    }
    if (!_initialized) {
      _logWarning('interstitial load skipped: not initialized');
      return HCAdLoadResult.notInitialized;
    }

    await _interstitialAd?.dispose();
    _interstitialAd = null;
    final completer = Completer<HCAdLoadResult>();
    try {
      _logInfo('interstitial load start');
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
            _logInfo('interstitial load success');
            _completeOnce(completer, HCAdLoadResult.loaded);
          },
          onAdFailedToLoad: (error) {
            _logWarning(
              'interstitial load failed: ${_formatLoadAdError(error)}',
            );
            _completeOnce(completer, HCAdLoadResult.failed);
          },
        ),
      );
    } catch (error, stackTrace) {
      _logWarning('interstitial load threw', error, stackTrace);
      _completeOnce(completer, HCAdLoadResult.failed);
    }
    return _waitForLoadResult(completer, 'interstitial load');
  }

  Future<HCAdShowResult> showInterstitial() async {
    if (!config.canRequestAds) {
      _logInfo('interstitial show skipped: ${config.debugSummary}');
      return HCAdShowResult.disabled;
    }
    if (!_initialized) {
      _logWarning('interstitial show skipped: not initialized');
      return HCAdShowResult.notInitialized;
    }
    final ad = _interstitialAd;
    if (ad == null) {
      _logWarning('interstitial show skipped: not loaded');
      return HCAdShowResult.notLoaded;
    }
    _interstitialAd = null;

    final completer = Completer<HCAdShowResult>();
    ad.fullScreenContentCallback = FullScreenContentCallback(
      onAdFailedToShowFullScreenContent: (failedAd, error) async {
        await failedAd.dispose();
        _logWarning('interstitial show failed: ${_formatAdError(error)}');
        _completeOnce(completer, HCAdShowResult.failed);
      },
      onAdDismissedFullScreenContent: (dismissedAd) async {
        await dismissedAd.dispose();
        _logInfo('interstitial dismissed');
        _completeOnce(completer, HCAdShowResult.dismissed);
      },
    );

    try {
      _logInfo('interstitial show start');
      await ad.show();
    } catch (error, stackTrace) {
      await ad.dispose();
      _logWarning('interstitial show threw', error, stackTrace);
      _completeOnce(completer, HCAdShowResult.failed);
    }
    return completer.future;
  }

  Future<void> dispose() async {
    await _bannerAd?.dispose();
    await _rewardedAd?.dispose();
    await _interstitialAd?.dispose();
    _bannerAd = null;
    _rewardedAd = null;
    _interstitialAd = null;
  }

  void _completeOnce<T>(Completer<T> completer, T value) {
    if (!completer.isCompleted) {
      completer.complete(value);
    }
  }

  Future<HCAdLoadResult> _waitForLoadResult(
    Completer<HCAdLoadResult> completer,
    String label, {
    Future<void> Function()? onTimeout,
  }) async {
    final timer = Timer(_adLoadTimeout, () {
      if (completer.isCompleted) {
        return;
      }
      _logWarning('$label timed out after ${_adLoadTimeout.inSeconds}s');
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

  String _formatLoadAdError(LoadAdError error) {
    return 'code=${error.code} domain=${error.domain} message=${error.message}';
  }

  String _formatAdError(AdError error) {
    return 'code=${error.code} domain=${error.domain} message=${error.message}';
  }

  void _logInfo(String message) {}

  void _logDebug(String message) {}

  void _logWarning(String message, [Object? error, StackTrace? stackTrace]) {}
}
