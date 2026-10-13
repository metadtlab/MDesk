import 'dart:async';

import 'package:flutter_hbb/models/apple_billing_model.dart';
import 'package:flutter_hbb/models/apple_billing_types.dart';
import 'package:flutter_hbb/utils/apple_billing_backend.dart';
import 'package:flutter_hbb/utils/apple_purchase_store.dart';
import 'package:flutter_test/flutter_test.dart';

const _tokenA = 'c197b0ec-0b8d-4a1c-8fc2-989bfdc86eaf';
const _tokenB = '4f163cc3-6b24-4ad1-a5e6-078d08ba36cf';
const _sessionA = BillingSession(
  origin: 'https://admin.787.kr',
  userId: 'account-a',
  generation: 1,
  accessToken: 'test-token-a',
);
const _sessionB = BillingSession(
  origin: 'https://admin.787.kr',
  userId: 'account-b',
  generation: 2,
  accessToken: 'test-token-b',
);
const _monthly = AppleStoreProduct(
  id: 'test.month',
  title: '월간 구독',
  description: '시험 상품',
  price: '₩1,000',
  currencyCode: 'KRW',
  subscriptionPeriod: 'month',
);
const _yearly = AppleStoreProduct(
  id: 'test.year',
  title: '연간 구독',
  description: '시험 상품',
  price: '₩10,000',
  currencyCode: 'KRW',
  subscriptionPeriod: 'year',
);

AppleBillingConfig _config({String token = _tokenA}) => AppleBillingConfig(
      enabled: true,
      appAccountToken: token,
      products: const [
        AppleBillingProductConfig(id: 'test.month', period: 'month'),
        AppleBillingProductConfig(id: 'test.year', period: 'year'),
      ],
    );

AppleStorePurchase _purchase({
  String? id = '123',
  String product = 'test.month',
  String? token = _tokenA,
  String proof = 'header.payload.signature',
  AppleStorePurchaseStatus status = AppleStorePurchaseStatus.purchased,
  bool pendingComplete = true,
  String? errorMessage,
}) =>
    AppleStorePurchase(
      status: status,
      productId: product,
      transactionId: id,
      signedTransactionInfo: proof,
      appAccountToken: token,
      pendingComplete: pendingComplete,
      errorMessage: errorMessage,
    );

Future<void> _until(bool Function() condition) async {
  for (var attempt = 0; attempt < 100; attempt++) {
    if (condition()) {
      // Flush continuations after the state change being observed.
      await Future<void>.delayed(Duration.zero);
      return;
    }
    await Future<void>.delayed(Duration.zero);
  }
  fail('Billing operation did not settle');
}

void main() {
  test('signed-out and disabled configurations never start payment', () async {
    final h = _Harness()..session = null;
    await h.start();
    expect(h.model.loggedIn, isFalse);
    expect(h.model.configured, isFalse);
    await h.model.buy(_monthly);
    expect(h.store.buyCalls, 0);
    h.session = _sessionA;
    h.backend.config = const AppleBillingConfig(enabled: false);
    await h.model.reload();
    expect(h.model.configured, isFalse);
    expect(h.model.canRestore, isFalse);
    await h.model.buy(_monthly);
    await h.model.restore();
    expect(h.store.buyCalls, 0);
    expect(h.store.restoreCalls, 0);
    expect(h.model.message, contains('결제되지 않습니다'));
  });

  test('unavailable store and malformed active config fail closed', () async {
    final h = _Harness()..store.available = false;
    await h.start();
    expect(h.model.configured, isFalse);
    expect(h.backend.loadCalls, 0);
    h.store.available = true;
    h.backend.config = const AppleBillingConfig(enabled: true);
    await h.model.reload();
    expect(h.model.configured, isFalse);
    expect(h.model.products, isEmpty);
    expect(h.model.error, isNotNull);
    await h.model.buy(_monthly);
    expect(h.store.buyCalls, 0);
  });

  test('not-found and period mismatch cannot appear as purchasable products',
      () async {
    final h = _Harness();
    h.store.query = const AppleProductQuery(products: [], notFoundIds: {
      'test.month',
      'test.year',
    });
    await h.start();
    expect(h.model.products, isEmpty);
    expect(h.model.canBuy(_monthly), isFalse);
    h.store.query = const AppleProductQuery(
      products: [
        AppleStoreProduct(
          id: 'test.month',
          title: 'Wrong period',
          description: '',
          price: '₩1,000',
          currencyCode: 'KRW',
          subscriptionPeriod: 'year',
        ),
        _yearly,
      ],
      notFoundIds: {},
    );
    await h.model.reload();
    expect(h.model.products.map((item) => item.id), ['test.year']);
    expect(h.model.canBuy(_monthly), isFalse);
    expect(h.model.canBuy(_yearly), isTrue);
    expect(h.model.message, contains('일부'));
  });

  test('backend readiness is rechecked immediately before payment', () async {
    final h = _Harness();
    await h.start();
    expect(h.model.canBuy(_monthly), isTrue);
    h.backend.config = const AppleBillingConfig(enabled: false);
    await h.model.buy(_monthly);
    expect(h.store.buyCalls, 0);
    expect(h.model.configured, isFalse);
  });

  test('buy uses StoreKit product and server-issued account token', () async {
    final h = _Harness();
    await h.start();
    await h.model.buy(_monthly);
    expect(h.store.buyCalls, 1);
    expect(h.store.buyToken, _tokenA);
    expect(h.model.busy, isTrue);
    h.store.emit([_purchase(status: AppleStorePurchaseStatus.pending)]);
    expect(h.model.busy, isFalse);
    expect(h.model.canBuy(_monthly), isFalse);
    expect(h.model.message, contains('승인'));
    expect(h.backend.verified, isEmpty);
    expect(h.store.completed, isEmpty);
    h.store.emit([_purchase(status: AppleStorePurchaseStatus.canceled)]);
    expect(h.model.canBuy(_monthly), isTrue);
    expect(h.model.message, contains('취소'));
  });

  test('platform errors and generic thrown errors never expose raw details',
      () async {
    final h = _Harness();
    await h.start();
    h.store.emit([
      _purchase(
        status: AppleStorePurchaseStatus.error,
        errorMessage: 'secret-token signed.transaction.info',
      )
    ]);
    expect(h.model.error, isNot(contains('secret-token')));
    expect(h.model.error, isNot(contains('signed.transaction.info')));
    expect(h.backend.verified, isEmpty);
    h.store.buyAction = () async => throw StateError('secret-token');
    await h.model.buy(_monthly);
    expect(h.model.error, isNot(contains('secret-token')));
    expect(h.model.busy, isFalse);
  });

  test('purchase observer failure disables new charges', () async {
    final h = _Harness();
    await h.start();
    h.store.events.addError(StateError('secret-token'));
    await Future<void>.delayed(Duration.zero);
    expect(h.model.configured, isFalse);
    expect(h.model.canBuy(_monthly), isFalse);
    expect(h.model.error, isNot(contains('secret-token')));
    await h.model.buy(_monthly);
    expect(h.store.buyCalls, 0);
  });

  test('transactions complete only after server acceptance and account refresh',
      () async {
    final h = _Harness();
    final verification = Completer<void>();
    h.backend.verifyAction = (_, __) => verification.future;
    await h.start();
    h.store.emit([_purchase()]);
    await _until(() => h.backend.verified.length == 1);
    expect(h.store.completed, isEmpty);
    expect(h.refreshCalls, 0);
    expect(h.model.verifying, isTrue);
    verification.complete();
    await _until(() => !h.model.busy);
    expect(h.store.completed, ['123']);
    expect(h.refreshCalls, 1);
    expect(h.model.hasUnverifiedPurchases, isFalse);
    expect(h.model.message, contains('새로 조회'));
  });

  test('new transaction arriving during verification is drained without retry',
      () async {
    final h = _Harness();
    final first = Completer<void>();
    h.backend.verifyAction = (_, transaction) =>
        transaction.transactionId == '123' ? first.future : Future.value();
    await h.start();
    h.store.emit([_purchase()]);
    await _until(() => h.backend.verified.length == 1);
    h.store.emit([_purchase(id: '456', product: 'test.year')]);
    first.complete();
    await _until(() => !h.model.busy);
    expect(
        h.backend.verified.map((item) => item.transactionId), ['123', '456']);
    expect(h.store.completed, ['123', '456']);
    expect(h.model.hasUnverifiedPurchases, isFalse);
  });

  test('one bad transaction is attempted once and does not block another',
      () async {
    final h = _Harness();
    h.backend.verifyAction = (_, transaction) async {
      if (transaction.transactionId == '123') {
        throw const AppleBillingException('구매 검증에 실패했습니다.', retryable: true);
      }
    };
    await h.start();
    h.store.emit([_purchase(), _purchase(id: '456')]);
    await _until(() => !h.model.busy);
    expect(
        h.backend.verified.map((item) => item.transactionId), ['123', '456']);
    expect(h.store.completed, ['456']);
    expect(h.model.hasUnverifiedPurchases, isTrue);
    // Remaining failure must not automatically spin after the drain completes.
    await Future<void>.delayed(Duration.zero);
    expect(h.backend.verified.length, 2);
  });

  test('server failure retains the transaction for explicit retry', () async {
    final h = _Harness();
    h.backend.verifyAction = (_, __) async {
      throw const AppleBillingException('구매 서버를 잠시 이용할 수 없습니다.',
          retryable: true);
    };
    await h.start();
    h.store.emit([_purchase()]);
    await _until(() => !h.model.busy);
    expect(h.store.completed, isEmpty);
    expect(h.refreshCalls, 0);
    expect(h.model.hasUnverifiedPurchases, isTrue);
    expect(h.model.canBuy(_monthly), isFalse);
    h.backend.verifyAction = null;
    await h.model.retryVerification();
    expect(h.backend.verified.length, 2);
    expect(h.store.completed, ['123']);
    expect(h.model.hasUnverifiedPurchases, isFalse);
  });

  test('wrong account, missing proof and unsupported product cannot complete',
      () async {
    final h = _Harness();
    await h.start();
    h.store.emit([
      _purchase(token: _tokenB),
      _purchase(id: '456', proof: ''),
      _purchase(id: '789', product: 'unknown'),
    ]);
    await _until(() => !h.model.busy);
    expect(h.backend.verified, isEmpty);
    expect(h.store.completed, isEmpty);
    expect(h.model.hasUnverifiedPurchases, isTrue);
  });

  test('duplicate events before and after completion are idempotent', () async {
    final h = _Harness();
    final verification = Completer<void>();
    h.backend.verifyAction = (_, __) => verification.future;
    await h.start();
    h.store.emit([_purchase()]);
    await _until(() => h.backend.verified.length == 1);
    h.store.emit([_purchase()]);
    verification.complete();
    await _until(() => !h.model.busy);
    h.store.emit([_purchase(status: AppleStorePurchaseStatus.restored)]);
    await _until(() => !h.model.busy);
    expect(h.backend.verified.length, 1);
    expect(h.store.completed, ['123']);
    expect(h.model.hasUnverifiedPurchases, isFalse);
  });

  test('changed transaction proof cannot reuse duplicate acceptance', () async {
    final h = _Harness();
    await h.start();
    h.store.emit([_purchase()]);
    await _until(() => !h.model.busy);
    h.store.emit([_purchase(proof: 'different.signed.proof')]);
    await _until(() => !h.model.busy);
    expect(h.backend.verified.length, 2);
  });

  test('failed completion is retried only after fresh server verification',
      () async {
    final h = _Harness();
    var calls = 0;
    h.store.completeAction = (_) async {
      if (++calls == 1) {
        throw const ApplePurchaseStoreException('거래 완료 처리에 실패했습니다.');
      }
    };
    await h.start();
    h.store.emit([_purchase()]);
    await _until(() => !h.model.busy);
    expect(h.model.hasUnverifiedPurchases, isTrue);
    expect(h.refreshCalls, 0);
    await h.model.retryVerification();
    expect(h.backend.verified.length, 2);
    expect(calls, 2);
    expect(h.refreshCalls, 1);
    expect(h.model.hasUnverifiedPurchases, isFalse);
  });

  test('failed account refresh after completion never claims success',
      () async {
    final h = _Harness();
    h.refreshAction = () async => throw StateError('secret refresh response');
    await h.start();
    h.store.emit([_purchase()]);
    await _until(() => !h.model.busy);
    expect(h.store.completed, ['123']);
    expect(h.model.hasUnverifiedPurchases, isTrue);
    expect(h.model.message, isNull);
    expect(h.model.error, contains('새로 조회하지 못했습니다'));
    expect(h.model.error, isNot(contains('secret')));
    h.refreshAction = null;
    await h.model.retryVerification();
    expect(h.backend.verified.length, 2);
    expect(h.model.hasUnverifiedPurchases, isFalse);
  });

  for (final fail in [false, true]) {
    test('account switch suppresses stale verification result: failure=$fail',
        () async {
      final h = _Harness();
      final verification = Completer<void>();
      h.backend.verifyAction = (_, __) => verification.future;
      h.backend.loadAction = (session) async =>
          _config(token: session.userId == 'account-a' ? _tokenA : _tokenB);
      await h.start();
      h.store.emit([_purchase()]);
      await _until(() => h.backend.verified.length == 1);
      h.session = _sessionB;
      h.model.accountChanged();
      await _until(() => !h.model.loading);
      if (fail) {
        verification
            .completeError(const AppleBillingException('old account error'));
      } else {
        verification.complete();
      }
      await _until(() => !h.model.busy);
      expect(h.store.completed, isEmpty);
      expect(h.refreshCalls, 0);
      expect(h.model.error, isNot('old account error'));
      expect(h.model.message, isNot(contains('새로 조회')));
      expect(h.backend.verified.length, 1);
    });
  }

  test('stale reload failure cannot replace new account configuration',
      () async {
    final h = _Harness();
    final oldConfig = Completer<AppleBillingConfig>();
    h.backend.loadAction = (session) => session.userId == 'account-a'
        ? oldConfig.future
        : Future.value(_config(token: _tokenB));
    h.model.start();
    await _until(() => h.backend.loadCalls == 1);
    h.session = _sessionB;
    h.model.accountChanged();
    await _until(() => !h.model.loading);
    oldConfig.completeError(const AppleBillingException('old load error'));
    await Future<void>.delayed(Duration.zero);
    expect(h.model.error, isNull);
    expect(h.model.loggedIn, isTrue);
    expect(h.model.configured, isTrue);
    expect(h.model.products.length, 2);
  });

  test('token rotation keeps the current account eligible for completion',
      () async {
    final h = _Harness();
    final verification = Completer<void>();
    h.backend.verifyAction = (_, __) => verification.future;
    await h.start();
    h.store.emit([_purchase()]);
    await _until(() => h.backend.verified.length == 1);
    h.session = const BillingSession(
      origin: 'https://admin.787.kr/',
      userId: 'account-a',
      generation: 1,
      accessToken: 'rotated-token',
    );
    verification.complete();
    await _until(() => !h.model.busy);
    expect(h.store.completed, ['123']);
    expect(h.refreshCalls, 1);
  });

  test('account switch during refresh does not publish old-account success',
      () async {
    final h = _Harness();
    final refresh = Completer<void>();
    h.refreshAction = () => refresh.future;
    h.backend.loadAction = (session) async =>
        _config(token: session.userId == 'account-a' ? _tokenA : _tokenB);
    await h.start();
    h.store.emit([_purchase()]);
    await _until(() => h.refreshCalls == 1);
    expect(h.store.completed, ['123']);
    h.session = _sessionB;
    h.model.accountChanged();
    await _until(() => !h.model.loading);
    refresh.complete();
    await _until(() => !h.model.busy);
    expect(h.model.message, isNot(contains('새로 조회')));
    expect(h.model.hasUnverifiedPurchases, isTrue);
    expect(h.backend.verified.length, 1);
  });

  test('session read failure after acceptance never finishes the transaction',
      () async {
    final h = _Harness();
    final verification = Completer<void>();
    h.backend.verifyAction = (_, __) => verification.future;
    await h.start();
    h.store.emit([_purchase()]);
    await _until(() => h.backend.verified.length == 1);
    h.sessionFailure = StateError('private authentication details');
    verification.complete();
    await _until(() => !h.model.busy);
    expect(h.store.completed, isEmpty);
    expect(h.refreshCalls, 0);
    expect(h.model.hasUnverifiedPurchases, isTrue);
    expect(h.model.error, isNot(contains('private')));
    h.sessionFailure = null;
    await h.model.retryVerification();
    expect(h.backend.verified.length, 2);
    expect(h.store.completed, ['123']);
  });

  test('already-finished restored transaction is still verified server-side',
      () async {
    final h = _Harness();
    await h.start();
    h.store.emit([
      _purchase(
        status: AppleStorePurchaseStatus.restored,
        pendingComplete: false,
      )
    ]);
    await _until(() => !h.model.busy);
    expect(h.backend.verified.length, 1);
    expect(h.store.completed, isEmpty);
    expect(h.refreshCalls, 1);
    expect(h.model.hasUnverifiedPurchases, isFalse);
  });

  test('session provider exceptions are safe during reload and verification',
      () async {
    final h = _Harness();
    await h.start();
    h.sessionFailure = StateError('secret session token');
    h.store.emit([_purchase()]);
    await _until(() => !h.model.busy);
    expect(h.backend.verified, isEmpty);
    expect(h.store.completed, isEmpty);
    expect(h.model.error, isNot(contains('secret')));
    await h.model.reload();
    expect(h.model.configured, isFalse);
    expect(h.model.error, isNot(contains('secret')));
    expect(h.model.busy, isFalse);
  });

  test('restoration uses account token and does not grant local entitlements',
      () async {
    final h = _Harness();
    await h.start();
    await h.model.restore();
    expect(h.store.restoreCalls, 1);
    expect(h.store.restoreToken, _tokenA);
    expect(h.store.restoreModes, [false]);
    expect(h.refreshCalls, 0);
    expect(h.store.completed, isEmpty);
    h.store.emit([_purchase(status: AppleStorePurchaseStatus.restored)]);
    await _until(() => !h.model.busy);
    expect(h.backend.verified.length, 1);
    expect(h.store.completed, ['123']);
    expect(h.refreshCalls, 1);
  });

  test('forced synchronization is separate from regular purchase restoration',
      () async {
    final h = _Harness();
    await h.start();
    expect(h.store.restoreModes, isEmpty);
    await h.model.restore(synchronize: true);
    await h.model.restore();
    expect(h.store.restoreModes, [true, false]);
    expect(h.store.buyCalls, 0);
    expect(h.backend.verified, isEmpty);
    expect(h.refreshCalls, 0);
    expect(h.model.message, isNot(contains('새로 조회했습니다')));
  });

  test('explicit restore re-verifies a purchase accepted in the same session',
      () async {
    final h = _Harness();
    await h.start();
    h.store.emit([_purchase()]);
    await _until(() => !h.model.busy);
    expect(h.backend.verified.length, 1);
    expect(h.refreshCalls, 1);

    h.store.restoreAction = () async {
      h.store.emit([
        _purchase(
            status: AppleStorePurchaseStatus.restored, pendingComplete: false)
      ]);
    };
    await h.model.restore();
    await _until(() => !h.model.busy);
    expect(h.backend.verified.length, 2);
    expect(h.refreshCalls, 2);
    expect(h.store.completed, ['123']);
    expect(h.store.buyCalls, 0);
    expect(h.model.error, isNull);
    expect(h.model.message, contains('새로 조회'));

    h.store.emit([
      _purchase(
          status: AppleStorePurchaseStatus.restored, pendingComplete: false)
    ]);
    await _until(() => !h.model.busy);
    expect(h.backend.verified.length, 2);
  });

  test('restore query without transactions never claims account refresh',
      () async {
    final h = _Harness();
    await h.start();
    await h.model.restore();
    expect(h.model.message, contains('복원 조회를 완료'));
    expect(h.model.message, isNot(contains('새로 조회했습니다')));
    expect(h.refreshCalls, 0);
    expect(h.backend.verified, isEmpty);
  });

  test('a partial transaction success cannot erase a native restore failure',
      () async {
    final h = _Harness();
    final verified = Completer<void>();
    h.backend.verifyAction = (_, __) => verified.future;
    h.store.restoreAction = () async {
      h.store.emit([
        _purchase(
            status: AppleStorePurchaseStatus.restored, pendingComplete: false)
      ]);
      throw const ApplePurchaseStoreException('복원 검증 실패 [IAP-RESTORE-VERIFY]');
    };
    await h.start();
    await h.model.restore();
    await _until(() => h.backend.verified.length == 1);
    expect(h.model.error, contains('IAP-RESTORE-VERIFY'));
    verified.complete();
    await _until(() => !h.model.busy);
    expect(h.refreshCalls, 1);
    expect(h.model.error, contains('IAP-RESTORE-VERIFY'));
    expect(h.model.message, contains('일부 구매 내역'));
    expect(h.model.message, isNot(contains('새로 조회했습니다')));

    h.store.restoreAction = null;
    await h.model.restore();
    expect(h.model.error, isNull);
    expect(h.model.message, contains('복원 조회를 완료'));
  });

  test('safe restoration failure is visible and never starts a new purchase',
      () async {
    final h = _Harness();
    h.store.restoreAction = () async {
      throw const ApplePurchaseStoreException('동기화 실패 [IAP-SYNC-STORE]');
    };
    await h.start();
    await h.model.restore();
    expect(h.model.error, contains('IAP-SYNC-STORE'));
    expect(h.model.message, isNull);
    expect(h.backend.verified, isEmpty);
    expect(h.store.buyCalls, 0);
    expect(h.refreshCalls, 0);
    expect(h.model.busy, isFalse);
  });

  test('dispose during verification never completes or reports success',
      () async {
    final h = _Harness();
    final verification = Completer<void>();
    h.backend.verifyAction = (_, __) => verification.future;
    await h.start();
    h.store.emit([_purchase()]);
    await _until(() => h.backend.verified.length == 1);
    h.disposeModel();
    verification.complete();
    await Future<void>.delayed(Duration.zero);
    expect(h.store.completed, isEmpty);
    expect(h.refreshCalls, 0);
  });
}

class _Harness {
  final store = _FakeStore();
  final backend = _FakeBackend();
  BillingSession? session = _sessionA;
  Object? sessionFailure;
  Future<void> Function()? refreshAction;
  int refreshCalls = 0;
  bool disposed = false;
  late final AppleBillingModel model;

  _Harness() {
    model = AppleBillingModel(
      store: store,
      backend: backend,
      currentSession: () async {
        final failure = sessionFailure;
        if (failure != null) throw failure;
        return session;
      },
      refreshAccount: () async {
        refreshCalls++;
        await refreshAction?.call();
      },
    );
    addTearDown(() async {
      disposeModel();
      await store.events.close();
    });
  }

  Future<void> start() async {
    model.start();
    await _until(() => !model.busy);
  }

  void disposeModel() {
    if (disposed) return;
    disposed = true;
    model.dispose();
  }
}

class _FakeBackend implements AppleBillingBackend {
  AppleBillingConfig config = _config();
  int loadCalls = 0;
  final List<AppleBillingTransaction> verified = [];
  Future<AppleBillingConfig> Function(BillingSession)? loadAction;
  Future<void> Function(BillingSession, AppleBillingTransaction)? verifyAction;

  @override
  Future<AppleBillingConfig> loadConfig(BillingSession session) async {
    loadCalls++;
    return loadAction == null ? config : await loadAction!(session);
  }

  @override
  Future<void> verifyTransaction(
      BillingSession session, AppleBillingTransaction transaction) async {
    verified.add(transaction);
    await verifyAction?.call(session, transaction);
  }
}

class _FakeStore implements ApplePurchaseStore {
  final events =
      StreamController<List<AppleStorePurchase>>.broadcast(sync: true);
  bool available = true;
  AppleProductQuery query =
      const AppleProductQuery(products: [_monthly, _yearly], notFoundIds: {});
  int buyCalls = 0;
  int restoreCalls = 0;
  String? buyToken;
  String? restoreToken;
  final List<bool> restoreModes = [];
  final List<String?> completed = [];
  Future<bool> Function()? buyAction;
  Future<void> Function()? restoreAction;
  Future<void> Function(AppleStorePurchase)? completeAction;

  void emit(List<AppleStorePurchase> purchases) => events.add(purchases);

  @override
  Stream<List<AppleStorePurchase>> get purchases => events.stream;

  @override
  Future<bool> isAvailable() async => available;

  @override
  Future<AppleProductQuery> queryProducts(Set<String> ids) async => query;

  @override
  Future<bool> buy(AppleStoreProduct product, String appAccountToken) async {
    buyCalls++;
    buyToken = appAccountToken;
    return buyAction == null ? true : await buyAction!();
  }

  @override
  Future<void> restore(String appAccountToken,
      {bool synchronize = false}) async {
    restoreCalls++;
    restoreToken = appAccountToken;
    restoreModes.add(synchronize);
    await restoreAction?.call();
  }

  @override
  Future<void> complete(AppleStorePurchase purchase) async {
    await completeAction?.call(purchase);
    completed.add(purchase.transactionId);
  }
}
