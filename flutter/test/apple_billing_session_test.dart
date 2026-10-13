import 'package:flutter_hbb/models/apple_billing_types.dart';
import 'package:flutter_hbb/utils/apple_billing_backend.dart';
import 'package:flutter_hbb/utils/apple_billing_session.dart';
import 'package:flutter_test/flutter_test.dart';

const _old = BillingSession(
  origin: 'https://admin.787.kr',
  userId: 'account-a',
  generation: 1,
  accessToken: 'old-test-token',
);
const _rotated = BillingSession(
  origin: 'https://admin.787.kr',
  userId: 'account-a',
  generation: 1,
  accessToken: 'new-test-token',
);
const _other = BillingSession(
  origin: 'https://admin.787.kr',
  userId: 'account-b',
  generation: 2,
  accessToken: 'other-test-token',
);
const _transaction = AppleBillingTransaction(
  transactionId: '1234',
  productId: 'test.monthly',
  signedTransactionInfo: 'fake.test.proof',
);

class _Backend implements AppleBillingBackend {
  final List<BillingSession> requested = [];
  Future<void> Function(BillingSession)? onRequest;

  @override
  Future<AppleBillingConfig> loadConfig(BillingSession session) async {
    requested.add(session);
    await onRequest?.call(session);
    return const AppleBillingConfig(enabled: false);
  }

  @override
  Future<void> verifyTransaction(
      BillingSession session, AppleBillingTransaction transaction) async {
    requested.add(session);
    await onRequest?.call(session);
  }
}

void main() {
  late _Backend backend;
  late BillingSession? current;
  late int recoveries;
  late Future<bool> Function(BillingSession) recover;
  late SessionRefreshingAppleBillingBackend wrapper;

  setUp(() {
    backend = _Backend();
    current = _old;
    recoveries = 0;
    recover = (_) async {
      current = _rotated;
      return true;
    };
    wrapper = SessionRefreshingAppleBillingBackend(
      backend: backend,
      currentSession: () async => current,
      recoverSession: (session) async {
        recoveries++;
        return recover(session);
      },
    );
  });

  test('uses the latest token for the same purchasing account', () async {
    current = _rotated;
    await wrapper.loadConfig(_old);
    expect(backend.requested.single.accessToken, _rotated.accessToken);
    expect(recoveries, 0);
  });

  test('401 refreshes once and retries the same transaction', () async {
    backend.onRequest = (session) async {
      if (session.accessToken == _old.accessToken) {
        throw const AppleBillingException('Expired', statusCode: 401);
      }
    };
    await wrapper.verifyTransaction(_old, _transaction);
    expect(backend.requested.map((item) => item.accessToken),
        [_old.accessToken, _rotated.accessToken]);
    expect(recoveries, 1);
  });

  test('a second 401 never starts an authentication loop', () async {
    backend.onRequest = (_) async {
      throw const AppleBillingException('Expired', statusCode: 401);
    };
    await expectLater(
        wrapper.loadConfig(_old), throwsA(isA<AppleBillingException>()));
    expect(backend.requested, hasLength(2));
    expect(recoveries, 1);
  });

  test('a server outage is not treated as expired authentication', () async {
    backend.onRequest = (_) async {
      throw const AppleBillingException('Unavailable', retryable: true);
    };
    await expectLater(
        wrapper.loadConfig(_old), throwsA(isA<AppleBillingException>()));
    expect(backend.requested, hasLength(1));
    expect(recoveries, 0);
  });

  test('a changed account never receives the old purchase request', () async {
    current = _other;
    await expectLater(wrapper.verifyTransaction(_old, _transaction),
        throwsA(isA<AppleBillingException>()));
    expect(backend.requested, isEmpty);
    expect(recoveries, 0);
  });

  test('a logout during the 401 request does not refresh another login',
      () async {
    backend.onRequest = (_) async {
      current = null;
      throw const AppleBillingException('Expired', statusCode: 401);
    };
    await expectLater(
        wrapper.loadConfig(_old), throwsA(isA<AppleBillingException>()));
    expect(backend.requested, hasLength(1));
    expect(recoveries, 0);
  });

  test('an account change during token refresh prevents retry', () async {
    backend.onRequest = (_) async {
      throw const AppleBillingException('Expired', statusCode: 401);
    };
    recover = (_) async {
      current = _other;
      return true;
    };
    await expectLater(wrapper.verifyTransaction(_old, _transaction),
        throwsA(isA<AppleBillingException>()));
    expect(backend.requested, hasLength(1));
  });

  test('a changed account cannot accept a successful old response', () async {
    backend.onRequest = (_) async => current = _other;
    await expectLater(
        wrapper.loadConfig(_old), throwsA(isA<AppleBillingException>()));
    expect(backend.requested, hasLength(1));
  });

  test('failed recovery propagates the original error without retry', () async {
    backend.onRequest = (_) async {
      throw const AppleBillingException('Expired', statusCode: 401);
    };
    recover = (_) async => false;
    await expectLater(
        wrapper.loadConfig(_old), throwsA(isA<AppleBillingException>()));
    expect(backend.requested, hasLength(1));
    expect(recoveries, 1);
  });
}
