import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_hbb/mobile/pages/apple_subscription_page.dart';
import 'package:flutter_hbb/models/apple_billing_model.dart';
import 'package:flutter_hbb/models/apple_billing_types.dart';
import 'package:flutter_hbb/utils/apple_billing_backend.dart';
import 'package:flutter_hbb/utils/apple_purchase_store.dart';
import 'package:flutter_test/flutter_test.dart';

const _accountToken = '12345678-1234-1234-1234-123456789012';
const _session = BillingSession(
  origin: 'https://admin.787.kr',
  userId: 'test-account',
  generation: 1,
  accessToken: 'test-access-token',
);
const _products = [
  AppleStoreProduct(
    id: 'test.monthly',
    title: 'StoreKit 월간 상품',
    description: 'App Store에서 제공한 월간 상품 설명',
    price: '₩10,000',
    currencyCode: 'KRW',
    subscriptionPeriod: 'month',
  ),
  AppleStoreProduct(
    id: 'test.yearly',
    title: 'StoreKit 연간 상품',
    description: 'App Store에서 제공한 연간 상품 설명',
    price: '₩120,000',
    currencyCode: 'KRW',
    subscriptionPeriod: 'year',
  ),
];

class _FakeStore implements ApplePurchaseStore {
  final updates = StreamController<List<AppleStorePurchase>>.broadcast();
  final boughtIds = <String>[];
  int queries = 0;
  int restores = 0;
  final List<bool> restoreModes = [];
  int completions = 0;

  @override
  Stream<List<AppleStorePurchase>> get purchases => updates.stream;

  @override
  Future<bool> isAvailable() async => true;

  @override
  Future<AppleProductQuery> queryProducts(Set<String> ids) async {
    queries++;
    return AppleProductQuery(
      products: _products.where((product) => ids.contains(product.id)).toList(),
      notFoundIds: const {},
    );
  }

  @override
  Future<bool> buy(AppleStoreProduct product, String appAccountToken) async {
    expect(appAccountToken, _accountToken);
    boughtIds.add(product.id);
    return false;
  }

  @override
  Future<void> restore(String appAccountToken,
      {bool synchronize = false}) async {
    expect(appAccountToken, _accountToken);
    restores++;
    restoreModes.add(synchronize);
  }

  @override
  Future<void> complete(AppleStorePurchase purchase) async {
    completions++;
  }
}

class _FakeBackend implements AppleBillingBackend {
  bool enabled = true;
  AppleBillingException? configError;
  AppleBillingException? verificationError;
  Completer<AppleBillingConfig>? delayedConfig;
  int verifications = 0;

  AppleBillingConfig get config => enabled
      ? const AppleBillingConfig(
          enabled: true,
          appAccountToken: _accountToken,
          products: [
            AppleBillingProductConfig(id: 'test.monthly', period: 'month'),
            AppleBillingProductConfig(id: 'test.yearly', period: 'year'),
          ],
        )
      : const AppleBillingConfig(enabled: false);

  @override
  Future<AppleBillingConfig> loadConfig(BillingSession session) async {
    if (configError != null) throw configError!;
    if (delayedConfig != null) return delayedConfig!.future;
    return config;
  }

  @override
  Future<void> verifyTransaction(
      BillingSession session, AppleBillingTransaction transaction) async {
    verifications++;
    if (verificationError != null) throw verificationError!;
  }
}

class _BillingHarness {
  final store = _FakeStore();
  final backend = _FakeBackend();
  BillingSession? session = _session;
  int accountRefreshes = 0;
  late final model = AppleBillingModel(
    store: store,
    backend: backend,
    currentSession: () async => session,
    refreshAccount: () async => accountRefreshes++,
  );

  Future<void> dispose() async {
    model.dispose();
    await store.updates.close();
  }
}

Widget _app(_BillingHarness billing,
    {VoidCallback? onLogin, double textScale = 1}) {
  return MaterialApp(
    builder: (context, child) => MediaQuery(
      data: MediaQuery.of(context)
          .copyWith(textScaler: TextScaler.linear(textScale)),
      child: child!,
    ),
    home: AppleSubscriptionPage(
      model: billing.model,
      onLogin: onLogin ?? () {},
      accountName: () => 'test-user',
    ),
  );
}

Future<void> _reveal(WidgetTester tester, Finder target,
    {double delta = 200}) async {
  if (target.evaluate().isEmpty) {
    await tester.scrollUntilVisible(target, delta, maxScrolls: 100);
  }
  await tester.ensureVisible(target);
  await tester.pumpAndSettle();
}

Future<void> _tap(WidgetTester tester, String key) async {
  final button = find.byKey(ValueKey(key));
  await _reveal(tester, button);
  await tester.tap(button);
  await tester.pumpAndSettle();
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const channel = MethodChannel('plugins.flutter.io/url_launcher');
  final openedUrls = <String>[];
  var linkResult = true;
  var linkThrows = false;

  setUp(() {
    openedUrls.clear();
    linkResult = true;
    linkThrows = false;
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (call) async {
      if (call.method == 'launch') {
        if (linkThrows) {
          throw PlatformException(
              code: 'failure', message: 'private-raw-platform-error');
        }
        final arguments = call.arguments as Map;
        openedUrls.add(arguments['url'] as String);
        expect(arguments['useSafariVC'], isFalse);
        return linkResult;
      }
      return true;
    });
  });

  tearDown(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, null);
  });

  testWidgets('reloads on open and displays only StoreKit product information',
      (tester) async {
    final billing = _BillingHarness();
    addTearDown(billing.dispose);
    await tester.pumpWidget(_app(billing));
    await tester.pumpAndSettle();

    expect(billing.store.queries, 1);
    expect(find.text('MDesk 계정: test-user'), findsOneWidget);
    expect(find.text('StoreKit 월간 상품'), findsOneWidget);
    expect(find.text('App Store에서 제공한 연간 상품 설명'), findsOneWidget);
    expect(find.text('₩10,000 / 1개월'), findsOneWidget);
    expect(find.text('₩120,000 / 1년'), findsOneWidget);
    expect(find.text('갱신 주기: 1개월 (자동 갱신)'), findsOneWidget);
    expect(find.text('갱신 주기: 1년 (자동 갱신)'), findsOneWidget);
    expect(find.textContaining('15대'), findsNothing);
    expect(find.textContaining('기존 유료회원'), findsOneWidget);
    expect(billing.store.boughtIds, isEmpty);
    expect(billing.store.restores, 0);
  });

  testWidgets('buy calls the model with the selected StoreKit product',
      (tester) async {
    final billing = _BillingHarness();
    addTearDown(billing.dispose);
    await tester.pumpWidget(_app(billing));
    await tester.pumpAndSettle();
    await _tap(tester, 'apple-subscription-buy-test.monthly');
    expect(billing.store.boughtIds, ['test.monthly']);
    final message = find.text('구매가 시작되지 않았습니다. 결제되지 않았습니다.');
    await _reveal(tester, message, delta: -200);
    expect(message, findsOneWidget);
    expect(billing.accountRefreshes, 0);
  });

  testWidgets('restore is an explicit action and does not claim entitlement',
      (tester) async {
    final billing = _BillingHarness();
    addTearDown(billing.dispose);
    await tester.pumpWidget(_app(billing));
    await tester.pumpAndSettle();
    await _tap(tester, 'apple-subscription-restore');
    expect(billing.store.restores, 1);
    expect(billing.store.restoreModes, [false]);
    expect(billing.accountRefreshes, 0);
    final message = find.textContaining('복원 조회를 완료했습니다');
    await _reveal(tester, message, delta: -200);
    expect(message, findsOneWidget);
  });

  testWidgets('App Store sync is a separate explicit action without purchase',
      (tester) async {
    final billing = _BillingHarness();
    addTearDown(billing.dispose);
    await tester.pumpWidget(_app(billing));
    await tester.pumpAndSettle();
    expect(billing.store.restoreModes, isEmpty);
    await _tap(tester, 'apple-subscription-sync');
    expect(billing.store.restoreModes, [true]);
    expect(billing.store.boughtIds, isEmpty);
    expect(billing.backend.verifications, 0);
    expect(billing.accountRefreshes, 0);
  });

  testWidgets('logged-out users can login and manage but cannot buy or restore',
      (tester) async {
    final billing = _BillingHarness()..session = null;
    addTearDown(billing.dispose);
    var loginCalls = 0;
    await tester.pumpWidget(_app(billing, onLogin: () => loginCalls++));
    await tester.pumpAndSettle();
    expect(find.text('MDesk 계정 로그인이 필요합니다'), findsOneWidget);
    expect(find.text('MDesk 계정: test-user'), findsNothing);
    expect(find.text('App Store에서 구독하기'), findsNothing);
    final restore = tester.widget<OutlinedButton>(
        find.byKey(const ValueKey('apple-subscription-restore')));
    expect(restore.onPressed, isNull);
    expect(
        tester
            .widget<OutlinedButton>(
                find.byKey(const ValueKey('apple-subscription-sync')))
            .onPressed,
        isNull);
    await _tap(tester, 'apple-subscription-login');
    expect(loginCalls, 1);
    await _tap(tester, 'apple-subscription-manage');
    expect(openedUrls, ['https://apps.apple.com/account/subscriptions']);
    expect(billing.store.boughtIds, isEmpty);
    expect(billing.store.restores, 0);
  });

  testWidgets('disabled configuration blocks purchase and restoration',
      (tester) async {
    final billing = _BillingHarness();
    billing.backend.enabled = false;
    addTearDown(billing.dispose);
    await tester.pumpWidget(_app(billing));
    await tester.pumpAndSettle();
    expect(find.text('App Store 구독을 준비 중입니다. 현재는 결제되지 않습니다.'), findsOneWidget);
    expect(find.text('App Store에서 구독하기'), findsNothing);
    expect(
        tester
            .widget<OutlinedButton>(
                find.byKey(const ValueKey('apple-subscription-restore')))
            .onPressed,
        isNull);
    expect(billing.store.queries, 0);
    expect(billing.store.boughtIds, isEmpty);
    expect(billing.store.restores, 0);
    expect(
        tester
            .widget<TextButton>(
                find.byKey(const ValueKey('apple-subscription-manage')))
            .onPressed,
        isNotNull);
  });

  testWidgets('server errors leave all fixed legal and management links usable',
      (tester) async {
    final billing = _BillingHarness();
    billing.backend.configError =
        const AppleBillingException('구매 서버를 잠시 이용할 수 없습니다.');
    addTearDown(billing.dispose);
    await tester.pumpWidget(_app(billing));
    await tester.pumpAndSettle();
    expect(find.text('구매 서버를 잠시 이용할 수 없습니다.'), findsOneWidget);
    await _tap(tester, 'apple-subscription-manage');
    await _tap(tester, 'apple-subscription-privacy');
    await _tap(tester, 'apple-subscription-terms');
    expect(openedUrls, [
      'https://apps.apple.com/account/subscriptions',
      'https://www.mdesk.co.kr/privacy-policy.html',
      'https://www.apple.com/legal/internet-services/itunes/dev/stdeula/',
    ]);
    expect(billing.store.boughtIds, isEmpty);
  });

  for (final throws in [false, true]) {
    testWidgets('link ${throws ? 'exception' : 'false'} shows only safe error',
        (tester) async {
      final billing = _BillingHarness()..session = null;
      addTearDown(billing.dispose);
      linkResult = false;
      linkThrows = throws;
      await tester.pumpWidget(_app(billing));
      await tester.pumpAndSettle();
      await _tap(tester, 'apple-subscription-manage');
      expect(find.text('링크를 열지 못했습니다. 잠시 후 다시 시도하세요.'), findsOneWidget);
      expect(find.textContaining('private-raw-platform-error'), findsNothing);
      expect(tester.takeException(), isNull);
    });
  }

  testWidgets(
      'loading disables billing actions but never subscription management',
      (tester) async {
    final billing = _BillingHarness();
    billing.backend.delayedConfig = Completer<AppleBillingConfig>();
    addTearDown(billing.dispose);
    await tester.pumpWidget(_app(billing));
    await tester.pump();
    expect(find.text('구독 정보를 불러오는 중입니다.'), findsOneWidget);
    expect(
        tester
            .widget<OutlinedButton>(
                find.byKey(const ValueKey('apple-subscription-reload')))
            .onPressed,
        isNull);
    expect(
        tester
            .widget<TextButton>(
                find.byKey(const ValueKey('apple-subscription-manage')))
            .onPressed,
        isNotNull);
    billing.backend.delayedConfig!.complete(billing.backend.config);
    await tester.pumpAndSettle();
    expect(find.text('구독 정보를 불러오는 중입니다.'), findsNothing);
  });

  testWidgets('failed verification can be retried without a second purchase',
      (tester) async {
    final billing = _BillingHarness();
    billing.backend.verificationError =
        const AppleBillingException('서버 구매 확인에 실패했습니다.', retryable: true);
    billing.model.start();
    addTearDown(billing.dispose);
    await tester.pumpWidget(_app(billing));
    await tester.pumpAndSettle();
    billing.store.updates.add(const [
      AppleStorePurchase(
        status: AppleStorePurchaseStatus.purchased,
        productId: 'test.monthly',
        transactionId: '123456789',
        signedTransactionInfo: 'test.signed.proof',
        appAccountToken: _accountToken,
        pendingComplete: true,
      ),
    ]);
    await tester.pumpAndSettle();
    expect(find.text('서버 구매 확인에 실패했습니다.'), findsOneWidget);
    expect(billing.accountRefreshes, 0);
    billing.backend.verificationError = null;
    await _tap(tester, 'apple-subscription-retry');
    expect(billing.accountRefreshes, 1);
    expect(billing.store.completions, 1);
    expect(billing.store.boughtIds, isEmpty);
    expect(
        find.byKey(const ValueKey('apple-subscription-retry')), findsNothing);
    final message = find.textContaining('서버의 계정 이용 권한을 새로 조회했습니다');
    await _reveal(tester, message, delta: -200);
    expect(message, findsOneWidget);
  });

  testWidgets(
      'narrow phone with large Korean text stays scrollable without overflow',
      (tester) async {
    tester.view.physicalSize = const Size(320, 568);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final billing = _BillingHarness();
    addTearDown(billing.dispose);
    await tester.pumpWidget(_app(billing, textScale: 2));
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
    await _tap(tester, 'apple-subscription-manage');
    expect(openedUrls, ['https://apps.apple.com/account/subscriptions']);
    expect(tester.takeException(), isNull);
  });
}
