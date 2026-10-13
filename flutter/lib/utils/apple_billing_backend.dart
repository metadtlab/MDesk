import 'dart:async';
import 'dart:convert';

import 'package:http/http.dart' as http;

import '../models/apple_billing_types.dart';

abstract class AppleBillingBackend {
  Future<AppleBillingConfig> loadConfig(BillingSession session);

  Future<void> verifyTransaction(
      BillingSession session, AppleBillingTransaction transaction);
}

/// An authenticated contract with the account server, not a local receipt
/// verifier. Missing server support never unlocks a purchase or an entitlement.
class HttpAppleBillingBackend implements AppleBillingBackend {
  final http.Client _client;
  final bool _ownsClient;
  final Duration timeout;
  bool _closed = false;

  HttpAppleBillingBackend({
    http.Client? client,
    this.timeout = const Duration(seconds: 20),
  })  : _client = client ?? http.Client(),
        _ownsClient = client == null;

  @override
  Future<AppleBillingConfig> loadConfig(BillingSession session) async {
    final data = await _request(session, 'GET', '/api/iap/apple/config');
    return AppleBillingConfig.fromJson(data);
  }

  @override
  Future<void> verifyTransaction(
      BillingSession session, AppleBillingTransaction transaction) async {
    if (transaction.transactionId.trim().isEmpty ||
        transaction.productId.trim().isEmpty ||
        transaction.signedTransactionInfo.trim().isEmpty) {
      throw const AppleBillingException('확인할 구매 정보가 없습니다.');
    }
    final data = await _request(
      session,
      'POST',
      '/api/iap/apple/transactions',
      body: {
        'transaction_id': transaction.transactionId,
        'product_id': transaction.productId,
        'signed_transaction_info': transaction.signedTransactionInfo,
      },
    );
    // Neither an HTTP 200 nor a generic success code confirms durable delivery
    // of the service. The server must explicitly acknowledge verification.
    if (data['accepted'] != true) {
      throw const AppleBillingException(
        '서버에서 구매를 확인하지 못했습니다. 구매 복원을 다시 시도해 주세요.',
        retryable: true,
      );
    }
  }

  Future<Map<String, dynamic>> _request(
    BillingSession session,
    String method,
    String path, {
    Map<String, String>? body,
  }) async {
    final origin = session.normalizedOrigin;
    if (session.userId.trim().isEmpty ||
        session.accessToken.trim().isEmpty ||
        session.accessToken.contains(RegExp(r'[\r\n]'))) {
      throw const AppleBillingException('MDesk 계정에 로그인한 뒤 다시 시도해 주세요.');
    }
    if (_closed) {
      throw const AppleBillingException('인앱결제를 다시 열어 주세요.');
    }
    final request = http.Request(method, Uri.parse('$origin$path'))
      // Do not forward either the bearer token or purchase proof to redirects.
      ..followRedirects = false
      ..headers.addAll({
        'Accept': 'application/json',
        'Content-Type': 'application/json',
        'Authorization': 'Bearer ${session.accessToken}',
      });
    if (body != null) request.body = jsonEncode(body);

    final http.Response response;
    try {
      response = await (() async {
        final stream = await _client.send(request);
        return http.Response.fromStream(stream);
      })()
          .timeout(timeout);
    } on TimeoutException {
      throw const AppleBillingException(
        '구매 서버의 응답이 늦어지고 있습니다. 잠시 후 다시 시도해 주세요.',
        retryable: true,
      );
    } catch (_) {
      // Never expose HTTP exceptions, which may include headers or receipts.
      throw const AppleBillingException(
        '구매 서버에 연결하지 못했습니다. 잠시 후 다시 시도해 주세요.',
        retryable: true,
      );
    }

    if (response.statusCode == 401) {
      throw const AppleBillingException('로그인이 만료되었습니다. 다시 로그인해 주세요.',
          statusCode: 401);
    }
    if (response.statusCode == 403) {
      throw const AppleBillingException('현재 계정으로 구매 정보를 확인할 수 없습니다.');
    }
    if (response.statusCode == 404 || response.statusCode == 501) {
      throw const AppleBillingException('인앱결제가 아직 준비되지 않았습니다.');
    }
    if (response.statusCode == 429 || response.statusCode >= 500) {
      throw const AppleBillingException(
        '구매 서버를 잠시 이용할 수 없습니다. 잠시 후 다시 시도해 주세요.',
        retryable: true,
      );
    }
    if (response.statusCode < 200 || response.statusCode >= 300) {
      throw const AppleBillingException('구매 정보를 확인하지 못했습니다.');
    }
    try {
      final decoded = jsonDecode(response.body);
      if (decoded is! Map<String, dynamic> ||
          decoded['code'] != 1 ||
          decoded['data'] is! Map<String, dynamic>) {
        throw const FormatException();
      }
      return decoded['data'] as Map<String, dynamic>;
    } catch (_) {
      throw const AppleBillingException('구매 서버의 응답을 확인할 수 없습니다.');
    }
  }

  void close() {
    if (_closed) return;
    _closed = true;
    if (_ownsClient) _client.close();
  }

  void dispose() => close();
}
