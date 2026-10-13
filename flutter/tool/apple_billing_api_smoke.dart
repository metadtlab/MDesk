// Read-only live API smoke check. Never purchases or submits a transaction.
// Credentials are read from stdin and are neither saved nor printed.
import 'dart:convert';
import 'dart:io';

import 'package:flutter_hbb/models/apple_billing_types.dart';
import 'package:flutter_hbb/utils/apple_billing_backend.dart';
import 'package:http/http.dart' as http;

const _origin = 'https://admin.787.kr';

Future<void> main(List<String> arguments) async {
  final client = http.Client();
  final backend = HttpAppleBillingBackend(client: client);
  try {
    stdout.writeln('Enter test credentials as one JSON line (input hidden).');
    final canHide = stdin.hasTerminal;
    final wasEchoing = canHide ? stdin.echoMode : false;
    String? line;
    try {
      if (canHide) stdin.echoMode = false;
      line = stdin.readLineSync();
    } finally {
      if (canHide) stdin.echoMode = wasEchoing;
    }
    final credentials = jsonDecode(line ?? '') as Map<String, dynamic>;
    final username = credentials['username'];
    final password = credentials['password'];
    if (username is! String ||
        username.isEmpty ||
        password is! String ||
        password.isEmpty) {
      throw const FormatException();
    }
    final login = await _request(client, 'POST', '/api/login', body: {
      'username': username,
      'password': password,
      'type': 'account',
      'autoLogin': false,
      'deviceInfo': <String, dynamic>{},
    });
    final loginBody = _object(login.body);
    final loginData = loginBody['data'] is Map<String, dynamic>
        ? loginBody['data'] as Map<String, dynamic>
        : loginBody;
    final token = loginData['access_token'];
    _result('login', {
      'http_status': login.statusCode,
      'access_token_present': token is String && token.isNotEmpty,
      'requires_two_factor': loginData['tfa_required'] == true,
    });
    if (login.statusCode != 200 || token is! String || token.isEmpty) {
      exitCode = 2;
      return;
    }

    final info = await _request(client, 'GET', '/api/userInfo', token: token);
    final infoBody = _object(info.body);
    final user = infoBody['data'];
    final id = user is Map<String, dynamic> ? user['user_pkid'] : null;
    final expectedIdArguments = arguments
        .where((value) => value.startsWith('--expected-user-id='))
        .toList();
    final expectedId = expectedIdArguments.isEmpty
        ? null
        : expectedIdArguments.single.substring('--expected-user-id='.length);
    _result('user_info', {
      'http_status': info.statusCode,
      'envelope_valid': infoBody['code'] == 1 && user is Map<String, dynamic>,
      'account_id_present': id != null && id.toString().isNotEmpty,
      'account_id_matches_expected':
          expectedId == null ? null : id?.toString() == expectedId,
      'membership_level_present':
          user is Map<String, dynamic> && user['membership_level'] is String,
      'membership_level': user is Map<String, dynamic>
          ? _allowedValue(
              user['membership_level'], {'free', 'basic', 'premium'})
          : null,
      'registered_device_limit': user is Map<String, dynamic> &&
              user['registered_device_limit'] is int &&
              (user['registered_device_limit'] as int) >= 0 &&
              (user['registered_device_limit'] as int) <= 100000
          ? user['registered_device_limit']
          : null,
    });
    if (info.statusCode != 200 ||
        infoBody['code'] != 1 ||
        id == null ||
        id.toString().isEmpty ||
        (expectedId != null && id.toString() != expectedId)) {
      exitCode = 2;
      return;
    }

    final session = BillingSession(
      origin: _origin,
      userId: id.toString(),
      generation: 0,
      accessToken: token,
    );
    // A disabled config is intentionally stripped of products by the app.
    // Inspect optional metadata separately so products:[] below is not
    // mistaken for evidence that the server has no configured products.
    final configResponse =
        await _request(client, 'GET', '/api/iap/apple/config', token: token);
    final configBody = _object(configResponse.body);
    final configData = configBody['data'];
    if (configData is Map<String, dynamic>) {
      final rawProducts = configData['products'];
      final products = rawProducts is List
          ? rawProducts.whereType<Map<String, dynamic>>().toList()
          : null;
      final rawUuid = configData['app_account_token'];
      _result('server_config_metadata', {
        'http_status': configResponse.statusCode,
        'envelope_valid': configBody['code'] == 1,
        'enabled': configData['enabled'] is bool ? configData['enabled'] : null,
        'optional_products_supplied': configData.containsKey('products'),
        'optional_uuid_supplied': configData.containsKey('app_account_token'),
        'uuid_format_valid':
            rawUuid is String ? isAppleBillingAccountToken(rawUuid) : null,
        'monthly_product_matches_requested': products?.any((product) =>
            product['id'] == 'com.metadtlab.mdesk.starter.monthly' &&
            product['period'] == 'month'),
        'yearly_product_matches_requested': products?.any((product) =>
            product['id'] == 'com.metadtlab.mdesk.starter.yearly' &&
            product['period'] == 'year'),
        // Only explicitly supplied booleans are diagnostic evidence. A missing
        // field means unknown, never that Production is ready or disabled.
        'production_enabled': _optionalBool(configData, 'production_enabled'),
        'production_ready': _optionalBool(configData, 'production_ready'),
        'sandbox_enabled': _optionalBool(configData, 'sandbox_enabled'),
        'sandbox_only': _optionalBool(configData, 'sandbox_only'),
      });
    } else {
      _result('server_config_metadata', {
        'http_status': configResponse.statusCode,
        'envelope_valid': false,
      });
    }
    // Exercise the real app's parser and redirect/auth protections, not a mock.
    final first = await backend.loadConfig(session);
    final second = await backend.loadConfig(session);
    final stableToken = first.appAccountToken == second.appAccountToken;
    final stableProducts = jsonEncode(first.products
            .map((p) => {'id': p.id, 'period': p.period})
            .toList()) ==
        jsonEncode(second.products
            .map((p) => {'id': p.id, 'period': p.period})
            .toList());
    _result('billing_config', {
      'app_parser_accepted': true,
      'enabled': first.enabled,
      'enabled_stable': first.enabled == second.enabled,
      'account_uuid_valid': first.enabled
          ? first.appAccountToken != null &&
              isAppleBillingAccountToken(first.appAccountToken!)
          : null,
      'account_uuid_stable': first.enabled ? stableToken : null,
      'products_stable': stableProducts,
      'products':
          first.products.map((p) => {'id': p.id, 'period': p.period}).toList(),
      'apple_purchase_tested': false,
      'transaction_endpoint_tested_with_valid_proof': false,
    });
    if (!stableToken || !stableProducts || first.enabled != second.enabled) {
      exitCode = 2;
    }
    if (arguments.contains('--include-account-deletion')) {
      // Read only the signed-in account's request state. Never POST, confirm,
      // create a request, or disclose account/contact/receipt data.
      final deletionResponse = await _request(
          client, 'GET', '/api/web/account/deletion-request',
          token: token);
      Map<String, dynamic>? deletionBody;
      try {
        deletionBody = _object(deletionResponse.body);
      } catch (_) {
        // Authentication/error pages must not be printed as diagnostics.
      }
      final deletionData = deletionBody?['data'];
      final request = deletionData is Map<String, dynamic> &&
              deletionData['request'] is Map<String, dynamic>
          ? deletionData['request'] as Map<String, dynamic>
          : deletionData is Map<String, dynamic>
              ? deletionData
              : null;
      _result('account_deletion_read_only', {
        'http_status': deletionResponse.statusCode,
        'json_object_received': deletionBody != null,
        'existing_request_status': _allowedValue(
            request?['status'], {'PENDING', 'PROCESSING', 'COMPLETED'}),
        'request_submission_tested': false,
        'actual_account_deletion_tested': false,
      });
    }
  } on AppleBillingException catch (error) {
    // These messages are deliberately sanitized by the production client.
    _result('billing_error', {
      'message': error.message,
      'http_status': error.statusCode,
      'retryable': error.retryable,
    });
    exitCode = 2;
  } catch (_) {
    // Never print raw network/JSON errors or server bodies containing secrets.
    _result('check_error', {'message': 'API check could not complete safely.'});
    exitCode = 2;
  } finally {
    backend.close();
    client.close();
  }
}

Future<http.Response> _request(http.Client client, String method, String path,
    {String? token, Map<String, dynamic>? body}) async {
  final request = http.Request(method, Uri.parse('$_origin$path'))
    ..followRedirects = false
    ..headers.addAll({
      'Accept': 'application/json',
      'Content-Type': 'application/json',
      if (token != null) 'Authorization': 'Bearer $token',
    });
  if (body != null) request.body = jsonEncode(body);
  return (() async => http.Response.fromStream(await client.send(request)))()
      .timeout(const Duration(seconds: 20));
}

Map<String, dynamic> _object(String value) {
  final result = jsonDecode(value);
  if (result is! Map<String, dynamic>) throw const FormatException();
  return result;
}

bool? _optionalBool(Map<String, dynamic> data, String key) {
  final value = data[key];
  return value is bool ? value : null;
}

String? _allowedValue(Object? value, Set<String> allowed) {
  return value is String && allowed.contains(value) ? value : null;
}

void _result(String stage, Map<String, dynamic> result) {
  stdout.writeln(jsonEncode({'stage': stage, ...result}));
}
