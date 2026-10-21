import 'dart:async';

import 'package:flutter/widgets.dart';
import 'package:google_mobile_ads/google_mobile_ads.dart';
import 'package:honeycube_game_ads/src/hc_ad_config.dart';
import 'package:honeycube_game_ads/src/hc_ad_result.dart';

/// Wraps the entire native form lifetime with the host's presentation guard.
/// The wrapper must await [present] exactly once and restore its guard in finally.
typedef HCAdConsentPresentation =
    Future<void> Function(Future<void> Function() present);

class HCAdService {
  HCAdService({HCAdConfig? config, this.presentConsentForm})
    : config = config ?? HCAdConfig.fromDartDefine();

  HCAdService.initializedForTest({required this.config, BannerAd? banner})
    : presentConsentForm = null,
      _initialized = true,
      _consentReady = true,
      _consentResult = HCAdConsentResult.ready {
    _banner.ad = banner;
  }

  final HCAdConfig config;
  final HCAdConsentPresentation? presentConsentForm;
  bool _initialized = false;
  bool _disposed = false;
  bool _consentReady = false;
  bool _privacyOptionsRequired = false;
  HCAdConsentResult? _consentResult;
  Future<HCAdConsentResult>? _consentFlight;
  bool _consentIsPrivacyOptions = false;
  Future<HCAdInitializeResult>? _initializeFlight;
  Future<void>? _disposeFlight;
  final _banner = _AdSlot<BannerAd>();
  final _rewarded = _AdSlot<RewardedAd>();
  final _interstitial = _AdSlot<InterstitialAd>();
  final _disposals = Expando<Future<void>>();
  _AdShowAttempt? _show;

  static const Duration _adLoadTimeout = Duration(seconds: 30);

  bool get isEnabled => config.canRequestAds;
  bool get isInitialized => _initialized && !_disposed;
  bool get isConsentReady => _consentReady && !_disposed;
  bool get isPrivacyOptionsRequired => _privacyOptionsRequired && !_disposed;
  bool get hasBanner => _banner.ad != null;
  bool get hasRewarded => _rewarded.ad != null;
  bool get hasInterstitial => _interstitial.ad != null;

  Widget? buildBannerWidget({Key? key}) {
    final ad = _banner.ad;
    if (ad == null) return null;
    return SizedBox(
      key: key,
      width: ad.size.width.toDouble(),
      height: ad.size.height.toDouble(),
      child: AdWidget(key: ValueKey<BannerAd>(ad), ad: ad),
    );
  }

  /// Requests fresh UMP information once per service (create one per app launch).
  /// Does not initialize or request ads. Concurrent calls share one operation.
  Future<HCAdConsentResult> prepareConsent() {
    if (_disposed) return Future.value(HCAdConsentResult.failed);
    if (_consentFlight != null) return _consentFlight!;
    if (_consentResult != null) return Future.value(_consentResult);
    return updateConsent();
  }

  /// Explicitly retries/refreshes UMP information; readiness is false meanwhile.
  Future<HCAdConsentResult> updateConsent() =>
      _startConsent(privacyOptions: false);

  /// Presents the required UMP entry point, then rechecks request readiness.
  /// Returns unavailable without presenting when the entry point is not required.
  Future<HCAdConsentResult> showPrivacyOptions() =>
      _startConsent(privacyOptions: true);

  Future<HCAdConsentResult> _startConsent({required bool privacyOptions}) {
    if (_disposed) return Future.value(HCAdConsentResult.failed);
    if (!isEnabled) return Future.value(HCAdConsentResult.disabled);
    if (_consentFlight != null) {
      return _consentIsPrivacyOptions == privacyOptions
          ? _consentFlight!
          : Future.value(HCAdConsentResult.failed);
    }
    if (_show != null) return Future.value(HCAdConsentResult.failed);
    if (privacyOptions && !_privacyOptionsRequired) {
      return Future.value(HCAdConsentResult.unavailable);
    }
    _consentReady = false;
    _consentIsPrivacyOptions = privacyOptions;
    final completer = Completer<HCAdConsentResult>();
    _consentFlight = completer.future;
    unawaited(() async {
      var result = HCAdConsentResult.failed;
      try {
        await Future.wait([
          _disposeSlot(_banner),
          _disposeSlot(_rewarded),
          _disposeSlot(_interstitial),
        ]);
        if (!_disposed) {
          result = await _performConsent(privacyOptions: privacyOptions);
        }
      } catch (_) {
        _consentReady = false;
      } finally {
        if (_disposed) result = HCAdConsentResult.failed;
        _consentResult = result;
        _consentFlight = null;
        completer.complete(result);
      }
    }());
    return completer.future;
  }

  Future<HCAdConsentResult> _performConsent({
    required bool privacyOptions,
  }) async {
    var sdkError = false;
    if (!privacyOptions) {
      final info = Completer<bool>();
      ConsentInformation.instance.requestConsentInfoUpdate(
        ConsentRequestParameters(),
        () {
          if (!info.isCompleted) info.complete(true);
        },
        (_) {
          if (!info.isCompleted) info.complete(false);
        },
      );
      sdkError = !await info.future.timeout(
        _adLoadTimeout,
        onTimeout: () => false,
      );
    }
    if (_disposed) return HCAdConsentResult.failed;
    if (!sdkError) {
      var presented = false;
      Future<void> present() async {
        if (presented || _disposed)
          throw StateError('Consent presentation closed');
        presented = true;
        if (privacyOptions) {
          await ConsentForm.showPrivacyOptionsForm(
            (error) => sdkError = error != null,
          );
        } else {
          await ConsentForm.loadAndShowConsentFormIfRequired(
            (error) => sdkError = error != null,
          );
        }
      }

      final wrapper = presentConsentForm;
      if (wrapper == null) {
        await present();
      } else {
        await wrapper(present);
        if (!presented)
          throw StateError('Consent presentation was not awaited');
      }
    }
    if (_disposed) return HCAdConsentResult.failed;
    // UMP may retain valid prior-session consent even when refresh/form fails.
    final ready = await ConsentInformation.instance.canRequestAds().timeout(
      _adLoadTimeout,
    );
    final options = await ConsentInformation.instance
        .getPrivacyOptionsRequirementStatus()
        .timeout(_adLoadTimeout);
    if (_disposed) return HCAdConsentResult.failed;
    _privacyOptionsRequired =
        options == PrivacyOptionsRequirementStatus.required;
    _consentReady = ready;
    return ready
        ? HCAdConsentResult.ready
        : sdkError
        ? HCAdConsentResult.failed
        : HCAdConsentResult.unavailable;
  }

  Future<HCAdInitializeResult> initialize() {
    if (_disposed) return Future.value(HCAdInitializeResult.failed);
    if (!isEnabled) return Future.value(HCAdInitializeResult.disabled);
    if (_initializeFlight != null) return _initializeFlight!;
    final completer = Completer<HCAdInitializeResult>();
    _initializeFlight = completer.future;
    unawaited(() async {
      var result = HCAdInitializeResult.failed;
      try {
        if (await prepareConsent() == HCAdConsentResult.ready && !_disposed) {
          if (!_initialized) {
            await MobileAds.instance.initialize().timeout(_adLoadTimeout);
          }
          if (!_disposed && isConsentReady) {
            _initialized = true;
            result = HCAdInitializeResult.initialized;
          }
        }
      } catch (_) {
        // A failed native call must not leave an initialized service behind.
      } finally {
        _initializeFlight = null;
        completer.complete(result);
      }
    }());
    return completer.future;
  }

  Future<HCAdLoadResult> loadBanner() => _load(
    _banner,
    enabled: config.canRequestBanner,
    start: (loaded, failed) async {
      final ad = BannerAd(
        adUnitId: config.admob!.androidBannerId,
        size: AdSize.banner,
        request: const AdRequest(),
        listener: BannerAdListener(
          onAdLoaded: (ad) => loaded(ad as BannerAd),
          onAdFailedToLoad: (ad, _) {
            unawaited(_disposeAd(ad));
            failed();
          },
        ),
      );
      _banner.loadingAd = ad;
      await ad.load();
    },
  );

  Future<HCAdLoadResult> loadRewarded() => _load(
    _rewarded,
    enabled: config.canRequestRewarded,
    start: (loaded, failed) => RewardedAd.load(
      adUnitId: config.admob!.androidRewardedId,
      request: const AdRequest(),
      rewardedAdLoadCallback: RewardedAdLoadCallback(
        onAdLoaded: loaded,
        onAdFailedToLoad: (_) => failed(),
      ),
    ),
  );

  Future<HCAdLoadResult> loadInterstitial() => _load(
    _interstitial,
    enabled: config.canRequestInterstitial,
    start: (loaded, failed) => InterstitialAd.load(
      adUnitId: config.admob!.androidInterstitialId,
      request: const AdRequest(),
      adLoadCallback: InterstitialAdLoadCallback(
        onAdLoaded: loaded,
        onAdFailedToLoad: (_) => failed(),
      ),
    ),
  );

  Future<HCAdLoadResult> _load<T extends Ad>(
    _AdSlot<T> slot, {
    required bool enabled,
    required Future<void> Function(void Function(T) loaded, VoidCallback failed)
    start,
  }) {
    if (_disposed) return Future.value(HCAdLoadResult.failed);
    if (!enabled) return Future.value(HCAdLoadResult.disabled);
    if (!_initialized || !isConsentReady || _consentFlight != null) {
      return Future.value(HCAdLoadResult.notInitialized);
    }
    if (slot.ad != null) return Future.value(HCAdLoadResult.loaded);
    if (slot.pending != null) return slot.pending!.future;
    final generation = ++slot.generation;
    final completer = Completer<HCAdLoadResult>();
    slot.pending = completer;
    void finish(HCAdLoadResult result) {
      if (completer.isCompleted) return;
      completer.complete(result);
      if (identical(slot.pending, completer)) {
        slot.pending = null;
        slot.timer?.cancel();
        slot.timer = null;
        slot.loadingAd = null;
      }
    }

    slot.timer = Timer(_adLoadTimeout, () {
      final loading = slot.loadingAd;
      finish(HCAdLoadResult.failed);
      if (loading != null) unawaited(_disposeAd(loading));
    });
    unawaited(() async {
      try {
        await start((ad) {
          if (identical(slot.ad, ad)) return;
          if (_disposed ||
              generation != slot.generation ||
              completer.isCompleted ||
              !isConsentReady) {
            unawaited(_disposeAd(ad));
            finish(HCAdLoadResult.failed);
            return;
          }
          slot.ad = ad;
          finish(HCAdLoadResult.loaded);
        }, () => finish(HCAdLoadResult.failed));
      } catch (_) {
        final ownsRequest =
            generation == slot.generation &&
            identical(slot.pending, completer) &&
            !completer.isCompleted;
        final loading = ownsRequest ? slot.loadingAd : null;
        finish(HCAdLoadResult.failed);
        if (loading != null) unawaited(_disposeAd(loading));
      }
    }());
    return completer.future;
  }

  Future<HCAdShowResult> showRewarded({
    VoidCallback? onShown,
    VoidCallback? onRewardEarned,
    VoidCallback? onImpression,
  }) => _showAd(
    _rewarded,
    enabled: config.canRequestRewarded,
    onShown: onShown,
    onRewardEarned: onRewardEarned,
    onImpression: onImpression,
  );

  Future<HCAdShowResult> showInterstitial({
    VoidCallback? onShown,
    VoidCallback? onImpression,
  }) => _showAd(
    _interstitial,
    enabled: config.canRequestInterstitial,
    onShown: onShown,
    onImpression: onImpression,
  );

  Future<HCAdShowResult> _showAd<T extends AdWithoutView>(
    _AdSlot<T> slot, {
    required bool enabled,
    VoidCallback? onShown,
    VoidCallback? onRewardEarned,
    VoidCallback? onImpression,
  }) {
    if (_disposed) return Future.value(HCAdShowResult.failed);
    if (!enabled) return Future.value(HCAdShowResult.disabled);
    if (!_initialized || !isConsentReady || _consentFlight != null) {
      return Future.value(HCAdShowResult.notInitialized);
    }
    if (_show != null) return Future.value(HCAdShowResult.failed);
    final ad = slot.ad;
    if (ad == null) return Future.value(HCAdShowResult.notLoaded);
    slot.ad = null;
    final attempt = _AdShowAttempt(ad);
    _show = attempt;
    void emit(VoidCallback? observer) {
      if (attempt.closed || _disposed) return;
      try {
        observer?.call();
      } catch (_) {
        /* Observers do not own SDK lifetime. */
      }
    }

    final callbacks = FullScreenContentCallback<T>(
      onAdShowedFullScreenContent: (_) {
        if (attempt.shown) return;
        attempt.shown = true;
        emit(onShown);
      },
      onAdImpression: (_) {
        if (attempt.impression) return;
        attempt.impression = true;
        emit(onImpression);
      },
      onAdFailedToShowFullScreenContent: (_, _) =>
          _finishShow(attempt, HCAdShowResult.failed),
      onAdDismissedFullScreenContent: (_) => _finishShow(
        attempt,
        attempt.earned ? HCAdShowResult.rewarded : HCAdShowResult.dismissed,
      ),
    );
    unawaited(() async {
      try {
        if (ad is RewardedAd) {
          ad.fullScreenContentCallback =
              callbacks as FullScreenContentCallback<RewardedAd>;
          await ad.show(
            onUserEarnedReward: (_, _) {
              if (attempt.closed || _disposed || attempt.earned) return;
              attempt.earned = true;
              emit(onRewardEarned);
            },
          );
        } else if (ad is InterstitialAd) {
          ad.fullScreenContentCallback =
              callbacks as FullScreenContentCallback<InterstitialAd>;
          await ad.show();
        }
      } catch (_) {
        _finishShow(attempt, HCAdShowResult.failed);
      }
    }());
    return attempt.result.future;
  }

  void _finishShow(_AdShowAttempt attempt, HCAdShowResult result) {
    if (attempt.closed) return;
    attempt.closed = true;
    unawaited(() async {
      await _disposeAd(attempt.ad);
      if (identical(_show, attempt)) _show = null;
      attempt.result.complete(result);
    }());
  }

  Future<void> dispose() {
    if (_disposeFlight != null) return _disposeFlight!;
    _disposed = true;
    _initialized = false;
    _consentReady = false;
    final attempt = _show;
    if (attempt != null) _finishShow(attempt, HCAdShowResult.failed);
    final cleanup = <Future<void>>[
      _disposeSlot(_banner),
      _disposeSlot(_rewarded),
      _disposeSlot(_interstitial),
      if (attempt != null) attempt.result.future.then((_) {}),
    ];
    return _disposeFlight = Future.wait(cleanup).then((_) {});
  }

  Future<void> disposeBanner() => _disposeSlot(_banner);

  Future<void> _disposeSlot<T extends Ad>(_AdSlot<T> slot) async {
    slot.generation++;
    slot.timer?.cancel();
    slot.timer = null;
    final pending = slot.pending;
    slot.pending = null;
    if (pending != null && !pending.isCompleted)
      pending.complete(HCAdLoadResult.failed);
    final ads = [slot.ad, slot.loadingAd];
    slot.ad = null;
    slot.loadingAd = null;
    await Future.wait([
      for (final ad in ads)
        if (ad != null) _disposeAd(ad),
    ]);
  }

  Future<void> _disposeAd(Ad ad) => _disposals[ad] ??= () async {
    try {
      await ad.dispose();
    } catch (_) {
      /* Finish cleanup even if native release fails. */
    }
  }();
}

final class _AdSlot<T extends Ad> {
  T? ad;
  T? loadingAd;
  int generation = 0;
  Completer<HCAdLoadResult>? pending;
  Timer? timer;
}

final class _AdShowAttempt {
  _AdShowAttempt(this.ad);
  final AdWithoutView ad;
  final result = Completer<HCAdShowResult>();
  bool closed = false;
  bool shown = false;
  bool earned = false;
  bool impression = false;
}
