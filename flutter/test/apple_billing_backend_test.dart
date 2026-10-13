import 'dart:async';
import 'dart:convert';

import 'package:flutter_hbb/models/apple_billing_types.dart';
import 'package:flutter_hbb/utils/apple_billing_backend.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

const _accountToken = 'c197b0ec-0b8d-4a1c-8fc2-989bfdc86eaf';
const _session = BillingSession(
  origin: 'https://admin.787.kr',
  userId: 'user-123',
  generation: 1,
  accessToken: 'test-access-token',
);
const _transaction = AppleBillingTransaction(
  transactionId: '123456789',
  productId: 'test.monthly',
  signedTransactionInfo: 'signed.transaction.proof',
  appAccountToken: _accountToken,
);

Map<String, dynamic> _config({Map<String, dynamic>? overrides}) => {
      'enabled': true,
      'app_account_token': _accountToken,
      'products': [
        {'id': 'test.monthly', 'period': 'month'},
        {'id': 'test.yearly', 'period': 'year'},
      ],
      ...?overrides,
    };

http.Response _response(Object? data, {int status = 200, Object code = 1}) =>
    http.Response(jsonEncode({'code': code, 'data': data}), status);

void main() {
  test('loads authenticated config from the normalized first-party endpoint',
      () async {
    final backend = HttpAppleBillingBackend(client: MockClient((request) async {
      expect(request.method, 'GET');
      expect(
          request.url.toString(), 'https://admin.787.kr/api/iap/apple/config');
      expect(request.headers['Authorization'], 'Bearer test-access-token');
      expect(request.followRedirects, isFalse);
      return _response(_config());
    }));
    final result = await backend.loadConfig(const BillingSession(
      origin: 'https://ADMIN.787.KR:443/',
      userId: 'user-123',
      generation: 1,
      accessToken: 'test-access-token',
    ));
    expect(result.enabled, isTrue);
    expect(result.appAccountToken, _accountToken);
    expect(result.products.map((product) => product.id),
        ['test.monthly', 'test.yearly']);
    expect(result.products.map((product) => product.period), ['month', 'year']);
  });

  test(
      'token rotation preserves identity, account and generation changes do not',
      () {
    expect(
        _session.sameIdentityAs(const BillingSession(
          origin: 'https://ADMIN.787.KR:443/',
          userId: 'user-123',
          generation: 1,
          accessToken: 'rotated-token',
        )),
        isTrue);
    expect(
        _session.sameIdentityAs(const BillingSession(
          origin: 'https://admin.787.kr',
          userId: 'another-user',
          generation: 1,
          accessToken: 'test-access-token',
        )),
        isFalse);
    expect(
        _session.sameIdentityAs(const BillingSession(
          origin: 'https://admin.787.kr',
          userId: 'user-123',
          generation: 2,
          accessToken: 'test-access-token',
        )),
        isFalse);
  });

  test('disabled billing needs neither products nor account token', () async {
    final backend = HttpAppleBillingBackend(
        client: MockClient((_) async => _response({'enabled': false})));
    final result = await backend.loadConfig(_session);
    expect(result.enabled, isFalse);
    expect(result.appAccountToken, isNull);
    expect(result.products, isEmpty);
  });

  for (final data in [
    <String, dynamic>{},
    _config(overrides: {'enabled': 'true'}),
    _config(overrides: {'app_account_token': null}),
    _config(overrides: {'app_account_token': 'user-123'}),
    _config(overrides: {'products': []}),
    _config(overrides: {'products': 'test.monthly'}),
    _config(overrides: {
      'products': [
        {'id': '', 'period': 'month'}
      ]
    }),
    _config(overrides: {
      'products': [
        {'id': ' test.monthly ', 'period': 'month'}
      ]
    }),
    _config(overrides: {
      'products': [
        {'id': 'test.weekly', 'period': 'week'}
      ]
    }),
    _config(overrides: {
      'products': [
        {'id': 'test.monthly', 'period': 'month'},
        {'id': 'test.monthly', 'period': 'year'},
      ]
    }),
    _config(overrides: {
      'products': [null]
    }),
  ]) {
    test('malformed config fails closed: ${jsonEncode(data)}', () async {
      final backend = HttpAppleBillingBackend(
          client: MockClient((_) async => _response(data)));
      await expectLater(
          backend.loadConfig(_session), throwsA(isA<AppleBillingException>()));
    });
  }

  for (final origin in [
    '',
    'http://admin.787.kr',
    'https://custom.example',
    'https://admin.787.kr.evil.example',
    'https://admin.787.kr:444',
    'https://user@admin.787.kr',
    'https://@admin.787.kr',
    'https://admin.787.kr/path',
    'https://admin.787.kr/.',
    'https://admin.787.kr//',
    'https://admin.787.kr?',
    'https://admin.787.kr#',
  ]) {
    test('rejects untrusted origin before making a request: $origin', () async {
      var called = false;
      final backend = HttpAppleBillingBackend(client: MockClient((_) async {
        called = true;
        return _response(_config());
      }));
      await expectLater(
          backend.loadConfig(BillingSession(
            origin: origin,
            userId: _session.userId,
            generation: _session.generation,
            accessToken: _session.accessToken,
          )),
          throwsA(isA<AppleBillingException>()));
      expect(called, isFalse);
    });
  }

  for (final status in [301, 401, 403, 404, 429, 500, 501]) {
    test('HTTP $status cannot enable billing and never exposes raw response',
        () async {
      final backend = HttpAppleBillingBackend(
          client: MockClient((_) async => http.Response(
              'secret-response test-access-token signed.transaction.proof',
              status)));
      try {
        await backend.loadConfig(_session);
        fail('Expected safe billing error');
      } on AppleBillingException catch (error) {
        expect(error.message, isNot(contains('secret-response')));
        expect(error.message, isNot(contains('test-access-token')));
        expect(error.message, isNot(contains('signed.transaction.proof')));
        expect(error.retryable, status == 429 || status == 500);
      }
    });
  }

  for (final response in [
    http.Response('not-json signed.transaction.proof', 200),
    _response(_config(), code: 0),
    _response(_config(), code: '1'),
    _response(null),
    _response([]),
  ]) {
    test('invalid response envelope fails closed: ${response.body}', () async {
      final backend =
          HttpAppleBillingBackend(client: MockClient((_) async => response));
      await expectLater(
          backend.loadConfig(_session), throwsA(isA<AppleBillingException>()));
    });
  }

  test('only explicit accepted true acknowledges verified transaction',
      () async {
    final backend = HttpAppleBillingBackend(client: MockClient((request) async {
      expect(request.method, 'POST');
      expect(request.url.toString(),
          'https://admin.787.kr/api/iap/apple/transactions');
      expect(request.headers['Authorization'], 'Bearer test-access-token');
      expect(request.headers['Content-Type'], startsWith('application/json'));
      expect(request.followRedirects, isFalse);
      expect(jsonDecode(request.body), {
        'transaction_id': '123456789',
        'product_id': 'test.monthly',
        'signed_transaction_info': 'signed.transaction.proof',
      });
      return _response({'accepted': true});
    }));
    await backend.verifyTransaction(_session, _transaction);
  });

  for (final data in [
    {'accepted': false},
    {'accepted': 'true'},
    {'accepted': 1},
    {'membership_level': 'paid'},
    <String, dynamic>{},
  ]) {
    test('unaccepted transaction fails closed: ${jsonEncode(data)}', () async {
      final backend = HttpAppleBillingBackend(
          client: MockClient((_) async => _response(data)));
      await expectLater(backend.verifyTransaction(_session, _transaction),
          throwsA(isA<AppleBillingException>()));
    });
  }

  test('empty transaction proof is rejected without a network request',
      () async {
    var called = false;
    final backend = HttpAppleBillingBackend(client: MockClient((_) async {
      called = true;
      return _response({'accepted': true});
    }));
    await expectLater(
        backend.verifyTransaction(
            _session,
            const AppleBillingTransaction(
              transactionId: '123',
              productId: 'test.monthly',
              signedTransactionInfo: '',
            )),
        throwsA(isA<AppleBillingException>()));
    expect(called, isFalse);
  });

  test('timeout returns a safe retryable error', () async {
    final completion = Completer<http.Response>();
    final backend = HttpAppleBillingBackend(
      client: MockClient((_) => completion.future),
      timeout: const Duration(milliseconds: 1),
    );
    await expectLater(
        backend.loadConfig(_session),
        throwsA(isA<AppleBillingException>()
            .having((error) => error.retryable, 'retryable', isTrue)));
    completion.complete(_response({'enabled': false}));
  });

  test('closing backend does not close an injected client', () async {
    final client = _TrackingClient();
    final backend = HttpAppleBillingBackend(client: client);
    backend.close();
    backend.dispose();
    expect(client.closed, isFalse);
    await expectLater(
        backend.loadConfig(_session), throwsA(isA<AppleBillingException>()));
  });
}

class _TrackingClient extends http.BaseClient {
  bool closed = false;

  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) async =>
      http.StreamedResponse(Stream.value(utf8.encode('{}')), 200);

  @override
  void close() {
    closed = true;
  }
}
