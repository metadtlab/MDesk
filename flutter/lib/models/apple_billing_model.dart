import 'dart:async';

import 'package:flutter/foundation.dart';

import '../utils/apple_billing_backend.dart';
import '../utils/apple_purchase_store.dart';
import 'apple_billing_types.dart';

typedef BillingSessionProvider = Future<BillingSession?> Function();

/// StoreKit never grants an MDesk entitlement locally. The API is authoritative.
class AppleBillingModel extends ChangeNotifier {
  AppleBillingModel({
    required ApplePurchaseStore store,
    required AppleBillingBackend backend,
    required BillingSessionProvider currentSession,
    required Future<void> Function() refreshAccount,
  })  : _store = store,
        _backend = backend,
        _currentSession = currentSession,
        _refreshAccount = refreshAccount;

  final ApplePurchaseStore _store;
  final AppleBillingBackend _backend;
  final BillingSessionProvider _currentSession;
  final Future<void> Function() _refreshAccount;
  StreamSubscription<List<AppleStorePurchase>>? _subscription;
  BillingSession? _session;
  AppleBillingConfig? _config;
  List<AppleStoreProduct> _products = const [];
  final Map<String, AppleStorePurchase> _queued = {};
  final Map<String, _CompletedBillingPurchase> _completed = {};
  final Set<String> _pendingProducts = {};
  Future<void>? _verification;
  int _loadEpoch = 0;
  int _accountEpoch = 0;
  bool _disposed = false;
  bool _purchaseInFlight = false;
  bool _purchaseStreamFailed = false;
  String? _restoreFailure;
  bool loading = false;
  bool restoring = false;
  bool storeAvailable = false;
  String? error;
  String? message;

  List<AppleStoreProduct> get products => List.unmodifiable(_products);
  bool get loggedIn => _session != null;
  bool get verifying => _verification != null;
  bool get busy => loading || restoring || verifying || _purchaseInFlight;
  bool get configured =>
      storeAvailable && !_purchaseStreamFailed && _config?.enabled == true;
  bool get canRestore => configured && loggedIn && !busy;
  bool get hasUnverifiedPurchases => _queued.isNotEmpty;

  String? periodFor(String productId) {
    for (final product in _config?.products ?? <AppleBillingProductConfig>[]) {
      if (product.id == productId) return product.period;
    }
    return null;
  }

  bool canBuy(AppleStoreProduct product) =>
      configured &&
      loggedIn &&
      !busy &&
      !hasUnverifiedPurchases &&
      !_pendingProducts.contains(product.id) &&
      _products.any((item) => item.id == product.id);

  /// Call at app startup, not just when the purchase screen is opened.
  void start() {
    if (_subscription != null || _disposed) return;
    _purchaseStreamFailed = false;
    try {
      _subscription =
          _store.purchases.listen(_onPurchases, onError: (Object _) {
        if (_disposed) return;
        _purchaseStreamFailed = true;
        _purchaseInFlight = false;
        error = 'App Store 구매 내역을 받지 못했습니다. 잠시 후 다시 시도하세요.';
        _notify();
      });
    } catch (_) {
      _purchaseStreamFailed = true;
      error = 'App Store 구매 내역을 받지 못했습니다. 잠시 후 다시 시도하세요.';
      _notify();
    }
    unawaited(reload());
  }

  Future<bool> _isCurrent(BillingSession session, {int? accountEpoch}) async {
    if (_disposed || (accountEpoch != null && accountEpoch != _accountEpoch)) {
      return false;
    }
    try {
      final current = await _currentSession();
      return !_disposed &&
          (accountEpoch == null || accountEpoch == _accountEpoch) &&
          current != null &&
          session.sameIdentityAs(current);
    } catch (_) {
      // A session-provider failure must never permit a charge or completion.
      return false;
    }
  }

  /// Invalidate immediately on logout/account/server changes, even mid-request.
  void accountChanged() {
    if (_disposed) return;
    _loadEpoch++;
    _accountEpoch++;
    _session = null;
    _config = null;
    _products = const [];
    _pendingProducts.clear();
    _completed.clear();
    _purchaseInFlight = false;
    restoring = false;
    _restoreFailure = null;
    message = null;
    error = null;
    _notify();
    unawaited(reload());
  }

  Future<void> reload() async {
    if (_disposed) return;
    final epoch = ++_loadEpoch;
    loading = true;
    error = null;
    message = null;
    _restoreFailure = null;
    _config = null;
    _products = const [];
    _notify();
    try {
      final session = await _currentSession();
      if (_disposed || epoch != _loadEpoch) return;
      _session = session;
      if (session == null) {
        message = '구매하거나 복원하려면 먼저 MDesk 계정으로 로그인하세요.';
        return;
      }
      final available = await _store.isAvailable();
      if (!await _isCurrent(session) || _disposed || epoch != _loadEpoch) {
        return;
      }
      storeAvailable = available;
      if (!storeAvailable) {
        error = '이 기기에서 App Store 결제를 사용할 수 없습니다.';
        return;
      }
      final config = await _backend.loadConfig(session);
      if (!await _isCurrent(session) || _disposed || epoch != _loadEpoch) {
        return;
      }
      if (!config.enabled) {
        _config = config;
        message = 'App Store 구독을 준비 중입니다. 현재는 결제되지 않습니다.';
        return;
      }
      // The backend interface may be implemented by another adapter. Validate
      // its configuration before making purchasing available, not only in HTTP.
      final token = config.appAccountToken;
      final ids = config.products.map((item) => item.id).toSet();
      if (token == null ||
          !isAppleBillingAccountToken(token) ||
          config.products.isEmpty ||
          ids.length != config.products.length ||
          config.products.any((item) =>
              item.id.trim().isEmpty ||
              item.id != item.id.trim() ||
              (item.period != 'month' && item.period != 'year'))) {
        throw const AppleBillingException('인앱결제가 아직 준비되지 않았습니다.');
      }
      _config = config;
      final query = await _store
          .queryProducts(config.products.map((product) => product.id).toSet());
      if (!await _isCurrent(session) || _disposed || epoch != _loadEpoch) {
        return;
      }
      // Both server configuration and StoreKit must describe the same renewal.
      _products = query.products.where((product) {
        return config.products.any((configured) =>
            configured.id == product.id &&
            configured.period == product.subscriptionPeriod);
      }).toList(growable: false);
      if (_products.isEmpty) {
        error = '판매 가능한 구독 상품을 불러오지 못했습니다. 결제는 진행되지 않습니다.';
      } else if (query.notFoundIds.isNotEmpty ||
          _products.length != config.products.length) {
        message = '일부 구독 상품을 불러오지 못했습니다. 표시된 상품만 구매할 수 있습니다.';
      } else {
        message = null;
      }
    } on AppleBillingException catch (exception) {
      if (!_disposed && epoch == _loadEpoch) error = exception.message;
    } on ApplePurchaseStoreException catch (exception) {
      if (!_disposed && epoch == _loadEpoch) error = exception.message;
    } catch (_) {
      if (!_disposed && epoch == _loadEpoch) {
        error = '구독 정보를 확인하지 못했습니다. 잠시 후 다시 시도하세요.';
      }
    } finally {
      if (!_disposed && epoch == _loadEpoch) {
        loading = false;
        _notify();
        if (configured && _queued.isNotEmpty) unawaited(_processQueued());
      }
    }
  }

  Future<void> buy(AppleStoreProduct selected) async {
    if (!canBuy(selected)) return;
    // Recheck backend readiness/ownership immediately before presenting payment.
    await reload();
    final session = _session;
    final accountEpoch = _accountEpoch;
    if (session == null ||
        !await _isCurrent(session, accountEpoch: accountEpoch)) {
      return;
    }
    final matching = _products.where((item) => item.id == selected.id);
    if (matching.isEmpty || !canBuy(matching.first)) return;
    _purchaseInFlight = true;
    error = null;
    message = 'App Store에서 구매를 확인해 주세요.';
    _notify();
    try {
      final opened =
          await _store.buy(matching.first, _config!.appAccountToken!);
      if (!opened && await _isCurrent(session, accountEpoch: accountEpoch)) {
        _purchaseInFlight = false;
        message = '구매가 시작되지 않았습니다. 결제되지 않았습니다.';
      }
    } on ApplePurchaseStoreException catch (exception) {
      if (await _isCurrent(session, accountEpoch: accountEpoch)) {
        _purchaseInFlight = false;
        error = exception.message;
      }
    } catch (_) {
      if (await _isCurrent(session, accountEpoch: accountEpoch)) {
        _purchaseInFlight = false;
        error = '구매를 시작하지 못했습니다. 잠시 후 다시 시도하세요.';
      }
    } finally {
      _notify();
    }
  }

  Future<void> restore({bool synchronize = false}) async {
    if (busy) return;
    await reload();
    final session = _session;
    final accountEpoch = _accountEpoch;
    if (!canRestore ||
        session == null ||
        !await _isCurrent(session, accountEpoch: accountEpoch)) {
      return;
    }
    restoring = true;
    error = null;
    _restoreFailure = null;
    // An explicit restore must re-verify even a transaction accepted earlier in
    // this session. The API remains authoritative and handles repeat delivery.
    _completed
        .removeWhere((_, purchase) => purchase.session.sameIdentityAs(session));
    final requestedMessage = synchronize
        ? 'App Store에 누락된 구매 내역의 동기화를 요청합니다. Apple 인증이 필요할 수 있습니다.'
        : 'App Store에 구매 복원을 요청합니다. 구매한 MDesk 계정이어야 합니다.';
    message = requestedMessage;
    _notify();
    try {
      await _store.restore(_config!.appAccountToken!, synchronize: synchronize);
      if (await _isCurrent(session, accountEpoch: accountEpoch) &&
          error == null &&
          message == requestedMessage) {
        // Native completion may arrive before the purchase stream. This is not
        // a claim of server acceptance, restored entitlement, or an empty list.
        message =
            'App Store 복원 조회를 완료했습니다. 복원 가능한 구매가 있으면 서버 확인 후 이용 권한이 갱신됩니다.';
      }
    } on ApplePurchaseStoreException catch (exception) {
      if (await _isCurrent(session, accountEpoch: accountEpoch)) {
        _restoreFailure = exception.message;
        error = _restoreFailure;
        message = null;
      }
    } catch (_) {
      if (await _isCurrent(session, accountEpoch: accountEpoch)) {
        _restoreFailure = '구매 복원을 요청하지 못했습니다. 잠시 후 다시 시도하세요.';
        error = _restoreFailure;
        message = null;
      }
    } finally {
      if (accountEpoch == _accountEpoch) restoring = false;
      _notify();
    }
  }

  Future<void> retryVerification() async {
    if (busy) return;
    await reload();
    await _processQueued();
  }

  void _onPurchases(List<AppleStorePurchase> purchases) {
    if (_disposed) return;
    for (final purchase in purchases) {
      switch (purchase.status) {
        case AppleStorePurchaseStatus.pending:
          _pendingProducts.add(purchase.productId);
          _purchaseInFlight = false;
          message = '구매 승인을 기다리고 있습니다. 승인 후 자동으로 확인합니다.';
          break;
        case AppleStorePurchaseStatus.canceled:
          _pendingProducts.remove(purchase.productId);
          _purchaseInFlight = false;
          message = '구매가 취소되었습니다.';
          break;
        case AppleStorePurchaseStatus.error:
          _pendingProducts.remove(purchase.productId);
          _purchaseInFlight = false;
          // A platform error can contain a receipt, account or transaction.
          error = 'App Store에서 구매를 완료하지 못했습니다. 잠시 후 다시 시도하세요.';
          message = null;
          break;
        case AppleStorePurchaseStatus.purchased:
        case AppleStorePurchaseStatus.restored:
          _pendingProducts.remove(purchase.productId);
          _purchaseInFlight = false;
          final id = purchase.transactionId;
          if (id == null ||
              id.isEmpty ||
              purchase.signedTransactionInfo.isEmpty) {
            error = '검증할 구매 내역을 받지 못했습니다. 구매 복원을 시도하세요.';
          } else {
            final completed = _completed[id];
            if (_session == null ||
                completed == null ||
                !completed.session.sameIdentityAs(_session!) ||
                !_sameTransaction(completed.purchase, purchase)) {
              _queued[id] = purchase;
            }
          }
          break;
      }
    }
    _notify();
    if (_queued.isNotEmpty) unawaited(_processQueued());
  }

  Future<void> _processQueued() {
    final existing = _verification;
    if (existing != null) return existing;
    if (_disposed || !configured || _session == null) return Future.value();
    final accountEpoch = _accountEpoch;
    final completer = Completer<void>();
    _verification = completer.future;
    _notify();
    unawaited(() async {
      try {
        // Drain new transaction IDs arriving during awaits. A failed ID is
        // attempted at most once per run, so one bad receipt cannot spin.
        final attempted = <String>{};
        while (!_disposed && accountEpoch == _accountEpoch) {
          final entries = _queued.entries
              .where((entry) => !attempted.contains(entry.key))
              .toList(growable: false);
          if (entries.isEmpty) break;
          final entry = entries.first;
          attempted.add(entry.key);
          await _verifyOne(entry.key, entry.value);
        }
      } catch (_) {
        if (!_disposed && accountEpoch == _accountEpoch) {
          error = '구매 확인을 완료하지 못했습니다. 새로 결제하지 말고 다시 시도하세요.';
        }
      } finally {
        _verification = null;
        if (!_disposed &&
            accountEpoch == _accountEpoch &&
            _queued.isNotEmpty &&
            error == null) {
          message = '일부 구매 내역의 확인이 끝나지 않았습니다. 새로 결제하지 말고 구매 확인을 다시 시도하세요.';
        }
        _notify();
        completer.complete();
        // A reload for a new account can finish while the old drain is still
        // running. Start its independent verification only after the old run.
        if (!_disposed &&
            accountEpoch != _accountEpoch &&
            configured &&
            _queued.isNotEmpty) {
          unawaited(_processQueued());
        }
      }
    }());
    return completer.future;
  }

  Future<void> _verifyOne(String id, AppleStorePurchase purchase) async {
    final accountEpoch = _accountEpoch;
    BillingSession? session;
    var transactionCompleted = false;
    try {
      session = await _currentSession();
      final config = _config;
      if (_disposed ||
          accountEpoch != _accountEpoch ||
          session == null ||
          _session == null ||
          !session.sameIdentityAs(_session!) ||
          config?.enabled != true) {
        return;
      }
      if (purchase.appAccountToken?.toLowerCase() !=
          config!.appAccountToken?.toLowerCase()) {
        error = '이 구매는 현재 MDesk 계정에 연결되어 있지 않습니다. 구매한 계정으로 로그인하세요.';
        return;
      }
      if (!config.products.any((item) => item.id == purchase.productId)) {
        error = '이 구매 상품은 현재 지원되지 않습니다. 고객지원에 문의하세요.';
        return;
      }
      // Re-verify on every retry, including failed StoreKit completion. The
      // server must make transaction delivery idempotent; the client never
      // assumes a previous HTTP response still authorizes this account.
      await _backend.verifyTransaction(
        session,
        AppleBillingTransaction(
          transactionId: id,
          productId: purchase.productId,
          signedTransactionInfo: purchase.signedTransactionInfo,
          appAccountToken: purchase.appAccountToken,
        ),
      );
      if (!await _isCurrent(session, accountEpoch: accountEpoch)) return;
      // Accepted means verified AND durably stored server-side. Never before it.
      if (purchase.pendingComplete) await _store.complete(purchase);
      transactionCompleted = true;
      if (!await _isCurrent(session, accountEpoch: accountEpoch)) return;
      await _refreshAccount();
      if (!await _isCurrent(session, accountEpoch: accountEpoch)) return;
      final queued = _queued[id];
      if (queued != null && _sameTransaction(queued, purchase)) {
        _queued.remove(id);
      }
      _completed[id] = _CompletedBillingPurchase(session, purchase);
      // Bounded memory for deduplication; older events can be safely verified
      // again against the idempotent server if they are replayed later.
      if (_completed.length > 64) _completed.remove(_completed.keys.first);
      // StoreKit can emit verified transactions before failing restoration of
      // another transaction. A partial success must not erase that failure.
      error = _restoreFailure;
      message = _restoreFailure == null
          ? '구매 내역을 확인했습니다. 서버의 계정 이용 권한을 새로 조회했습니다.'
          : '일부 구매 내역은 확인했지만 App Store 복원 오류가 남아 있습니다. 새로 구매하지 말고 복원을 다시 시도하세요.';
    } on AppleBillingException catch (exception) {
      if (await _canReport(session, accountEpoch)) {
        error = exception.message;
        message = '구매 확인이 끝나지 않았습니다. 새로 결제하지 말고 구매 확인을 다시 시도하세요.';
      }
    } on ApplePurchaseStoreException catch (exception) {
      if (await _canReport(session, accountEpoch)) {
        error = exception.message;
        message = null;
      }
    } catch (_) {
      if (await _canReport(session, accountEpoch)) {
        error = transactionCompleted
            ? '구매 확인 후 계정 이용 권한을 새로 조회하지 못했습니다. 새로 결제하지 말고 구매 확인을 다시 시도하세요.'
            : '구매 확인을 완료하지 못했습니다. 새로 결제하지 말고 구매 확인 재시도를 눌러 주세요.';
        message = null;
      }
    }
  }

  Future<bool> _canReport(BillingSession? session, int accountEpoch) async {
    if (_disposed || accountEpoch != _accountEpoch) return false;
    // If the provider itself failed, only show a generic error for this epoch.
    if (session == null) return true;
    return _isCurrent(session, accountEpoch: accountEpoch);
  }

  bool _sameTransaction(AppleStorePurchase first, AppleStorePurchase second) =>
      first.transactionId == second.transactionId &&
      first.productId == second.productId &&
      first.signedTransactionInfo == second.signedTransactionInfo &&
      first.appAccountToken?.toLowerCase() ==
          second.appAccountToken?.toLowerCase();

  void _notify() {
    if (!_disposed) notifyListeners();
  }

  @override
  void dispose() {
    _disposed = true;
    _loadEpoch++;
    _accountEpoch++;
    unawaited(_subscription?.cancel());
    super.dispose();
  }
}

class _CompletedBillingPurchase {
  const _CompletedBillingPurchase(this.session, this.purchase);

  final BillingSession session;
  final AppleStorePurchase purchase;
}
