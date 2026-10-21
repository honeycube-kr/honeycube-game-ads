# honeycube_game_ads

Honeycube Flutter 게임의 Android AdMob SDK 어댑터다. 게임의 노출 정책·보상 내구 저장·분석·화면 흐름·앱 개인정보 동의는 소비 앱이 소유한다. 패키지는 SDK 초기화, UMP 준비, 광고 로드·표시와 SDK 이벤트만 담당한다.

## 설정과 호환

기존 `HCAdService({HCAdConfig? config})`, `HCAdService.initializedForTest({required config, BannerAd? banner})`, 무인자 `showRewarded()`·`showInterstitial()`, 기존 initialize/load/show 결과 enum의 이름·순서를 유지한다. `initializedForTest`는 테스트에서만 SDK 초기화와 UMP 준비를 생략한다.

광고는 `ADS_ENABLED=false`가 기본이며 Android만 지원한다. `HCAdConfig.canRequestAds`는 enabled·Android·Android 앱 ID를 검사하는 **공통 초기화 조건**이다. `canRequestBanner/canRequestRewarded/canRequestInterstitial`은 공통 조건과 해당 형식의 단위 ID를 검사한다. 빈 배너 ID는 유효한 rewarded/interstitial을 막지 않는다. `HCAdMobConfig.hasRequiredIds`는 기존 전체 ID 검사 의미를 유지한다. Android manifest의 AdMob 앱 ID 설정은 소비 앱 책임이다.

## 즉시 이벤트

```dart
final ads = HCAdService(config: HCAdConfig.fromDartDefine());
final initialized = await ads.initialize();
if (initialized == HCAdInitializeResult.initialized) {
  await ads.loadRewarded();
  var earned = false;
  final result = await ads.showRewarded(
    onShown: () {},
    onRewardEarned: () { earned = true; },
    onImpression: () {},
  );
  // earned는 SDK 보상 영수증이다. 실제 게임 보상과 저장은 앱이 처리한다.
  // earned=true 이후 result=failed도 가능하며 이미 받은 영수증을 취소하지 않는다.
}
await ads.dispose();
```

공개 서명은 `showRewarded({VoidCallback? onShown, VoidCallback? onRewardEarned, VoidCallback? onImpression})`와 `showInterstitial({VoidCallback? onShown, VoidCallback? onImpression})`다. 콜백은 각 SDK 이벤트가 들어오는 즉시 표시 시도당 최대 한 번 호출한다. SDK 순서를 유지하며 dismiss에서 shown·earned·impression을 만들어내지 않는다. impression만 실제 impression이다.

관찰자는 동기 콜백이다. 동기 예외는 격리되어 다른 이벤트나 객체 해제·최종 결과를 막지 않는다. 앱이 시작한 비동기 저장·분석의 오류 처리는 앱 책임이다. 보상 receipt 후 표시 오류는 `onRewardEarned` 전달과 최종 `HCAdShowResult.failed`를 모두 유지한다. 보상 후 정상 dismiss는 `rewarded`, 무보상 dismiss는 `dismissed`다. 종료·dispose 후 늦은 callback은 무시한다.

서비스 하나의 rewarded/interstitial은 공통 single-flight다. 다른 표시가 진행 중이면 `failed`를 반환하고 대기 중인 다른 형식의 광고를 소비하지 않는다. 최종 show Future는 native 객체 해제를 시도한 뒤 완료한다. 해제 예외도 정리 완료를 막지 않는다.

## UMP 준비와 앱 guard

```dart
final ads = HCAdService(
  config: HCAdConfig.fromDartDefine(),
  presentConsentForm: (present) async {
    // 앱은 이 함수 진입 전에 focus/audio/input/lifecycle presentation guard를 획득한다.
    try {
      await present();
    } finally {
      // 앱은 실제 native form 종료 후 guard를 복구한다.
    }
  },
);
await ads.prepareConsent();
await ads.initialize();
```

`HCAdConsentPresentation = Future<void> Function(Future<void> Function() present)`는 선택적인 생성자 인자다. 앱은 `present()`를 정확히 한 번 호출하고 반드시 await하며 finally에서 guard를 복구한다. 패키지는 폼이 불필요한 경우에도 해당 SDK 호출 전체를 이 wrapper 안에서 수행한다. wrapper가 예외를 던지거나 present를 실행하지 않으면 준비 실패다. 폼을 OS/SDK에서 프로그램으로 닫는 기능은 제공하지 않는다. 폼 중 서비스가 dispose되어도 wrapper Future는 실제 폼 종료까지 유지되고, 종료 후 준비 상태가 살아나지 않는다. **R4는 두 종류의 UMP 폼 모두에서 이 hook을 앱 guard로 연결해야 한다.**

| API | 의미 |
| --- | --- |
| `Future<HCAdConsentResult> prepareConsent()` | 서비스당 최초 한 번 `requestConsentInfoUpdate`를 호출한다. 동일 서비스의 이미 완료한 결과를 재사용한다. 서비스는 앱 시작마다 새로 만든다. 광고 초기화·요청은 하지 않는다. |
| `Future<HCAdConsentResult> updateConsent()` | 명시적으로 UMP 정보 갱신을 재시도한다. 성공 시 필요한 폼을 표시한 다음 `canRequestAds`와 privacy entry point 필요 여부를 읽는다. |
| `Future<HCAdConsentResult> showPrivacyOptions()` | 필요 여부가 확인된 경우 privacy options 폼을 표시하고 준비 상태·entry point 필요 여부를 다시 읽는다. 필요하지 않거나 아직 확인되지 않았으면 폼 없이 `unavailable`이다. |
| `bool isConsentReady` | 이번 서비스의 UMP 절차 이후 SDK가 요청 가능하다고 확인한 상태다. 갱신·폼 처리 중과 dispose 후에는 false다. |
| `bool isPrivacyOptionsRequired` | SDK가 required라고 확인한 경우 true다. 앱은 이 값에 따라 설정 화면의 진입점을 표시하고 각 동의 API 완료 후 값을 다시 읽는다. |

새 `HCAdConsentResult`의 `disabled`는 공통 설정 비활성·미지원, `ready`는 SDK의 `canRequestAds=true`, `unavailable`은 오류 없이 완료했지만 요청 불가(또는 privacy entry point 없음), `failed`는 준비 오류·dispose·표시 충돌이다. UMP 정보/폼 오류 후에도 SDK가 이전 세션의 유효한 요청 가능 상태를 확인하면 공식 SDK 계약에 따라 `ready`가 될 수 있다. 앱 자체 동의 캐시를 SDK 준비 증거로 사용하지 않는다.

동일 종류 동의 요청의 동시 호출은 한 작업을 공유한다. 갱신과 privacy options처럼 종류가 다른 동의 작업이나 전체 화면 광고가 이미 진행 중이면 새 작업은 `failed`다. `prepareConsent()`와 `initialize()`는 진행 중인 동의 준비 결과를 기다린다. 자동 초기화는 최초 prepare를 포함하고, SDK 준비 불가면 기존 `HCAdInitializeResult.failed`다. 명시적 `updateConsent()` 뒤 다시 initialize할 수 있다. 실제 native SDK 초기화는 중복하지 않는다.

동의 갱신·privacy options를 시작하면 이전 동의로 로드된 광고를 모두 해제하고 진행 중 load를 실패·무효화한다. 새 준비 완료 후 필요한 광고를 다시 로드한다. 배너를 사용한다면 **동의 갱신·privacy options 호출 전에 기존 AdWidget을 먼저 unmount**해야 한다. 앱 개인정보 동의도 충족한 뒤 이 API를 호출·사용하는 책임은 앱에 있다. SDK 준비 전에는 load/show가 `notInitialized`이며 무료 보상을 주지 않는다.

## 요청 수명과 배너

동일 형식 load는 하나로 합치고, 이미 로드한 객체를 재사용한다. native load 메서드가 지연되어도 요청 시작부터 30초 후 `failed`다. timeout·dispose·동의 갱신 후 늦게 전달되는 객체는 해제하고 채택하지 않는다. 이전 요청의 역순 완료는 새 객체를 대체하지 않는다. 늦은 native 호출 오류는 해당 요청이 현재 세대와 pending을 소유할 때만 로딩 객체를 해제하므로 후속 배너를 해제하지 않는다. 시간 초과 후 자동 재시도는 하지 않으며 다음 load는 소비 앱의 별도 호출로만 시작한다. UMP 정보 갱신과 native SDK 초기화도 30초 제한이며 사용자 입력을 기다리는 native 폼 자체에는 인위적 timeout을 두지 않는다.

`loadBanner()`는 로드된 배너를 자동으로 교체하지 않는다. `buildBannerWidget({Key? key})`의 기존 SizedBox 크기·slot key·AdWidget 객체 key를 유지한다. `disposeBanner()` 또는 전체 `dispose()` 전에 AdWidget을 트리에서 제거하고 unmount를 기다린다. mounted 상태의 dispose는 지원하지 않는다. `disposeBanner()`는 배너 요청만 취소하며 새 load를 허용한다. 전체 `dispose()`는 영구 종료이며 재초기화할 수 없다. 진행 중 show는 failed로 종료되고 load는 failed로 취소된다.

공식 근거: [UMP 준비·오류 후 SDK 상태·privacy options](https://developers.google.com/admob/flutter/privacy), [rewarded 표시·보상·impression 이벤트](https://developers.google.com/admob/flutter/rewarded). 설치된 google_mobile_ads 9.0.0 API와 대조했다. 실제 광고 공급·폼 UI·기기 동작은 단위 테스트와 별도로 확인해야 한다.
