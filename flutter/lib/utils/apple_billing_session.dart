import '../models/apple_billing_types.dart';
import 'apple_billing_backend.dart';

/// Retries authentication once without transferring a purchase to a new login.
class SessionRefreshingAppleBillingBackend implements AppleBillingBackend {
  const SessionRefreshingAppleBillingBackend({
    required AppleBillingBackend backend,
    required Future<BillingSession?> Function() currentSession,
    required Future<bool> Function(BillingSession) recoverSession,
  })  : _backend = backend,
        _currentSession = currentSession,
        _recoverSession = recoverSession;

  final AppleBillingBackend _backend;
  final Future<BillingSession?> Function() _currentSession;
  final Future<bool> Function(BillingSession) _recoverSession;

  @override
  Future<AppleBillingConfig> loadConfig(BillingSession session) =>
      _authenticated(session, _backend.loadConfig);

  @override
  Future<void> verifyTransaction(
          BillingSession session, AppleBillingTransaction transaction) =>
      _authenticated(session,
          (current) => _backend.verifyTransaction(current, transaction));

  Future<T> _authenticated<T>(BillingSession initial,
      Future<T> Function(BillingSession) request) async {
    var current = await _requireSameAccount(initial);
    try {
      final result = await request(current);
      await _requireSameAccount(initial);
      return result;
    } on AppleBillingException catch (exception) {
      if (exception.statusCode != 401) rethrow;
      await _requireSameAccount(initial);
      if (!await _recoverSession(current)) rethrow;
      current = await _requireSameAccount(initial);
      // The retry is intentionally outside the first catch: no refresh loop.
      final result = await request(current);
      await _requireSameAccount(initial);
      return result;
    }
  }

  Future<BillingSession> _requireSameAccount(BillingSession original) async {
    final current = await _currentSession();
    if (current == null || !original.sameIdentityAs(current)) {
      throw const AppleBillingException('로그인 계정이 변경되었습니다. 구매한 계정으로 다시 확인하세요.');
    }
    return current;
  }
}
