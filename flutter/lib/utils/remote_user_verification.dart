import 'dart:convert';

import 'package:http/http.dart' as http;

typedef RemoteUserVerificationPost = Future<http.Response> Function(
  Uri url, {
  Map<String, String>? headers,
  Object? body,
});

/// Credential checks for registration never call app login or issue sessions.
class RemoteUserVerificationClient {
  final String apiServer;
  final RemoteUserVerificationPost post;

  const RemoteUserVerificationClient({
    required this.apiServer,
    required this.post,
  });

  Future<Map<String, dynamic>> verify({
    required String username,
    required String password,
    required String remoteId,
    required String hostname,
  }) =>
      _send(
          '/api/verify_remote_user',
          {
            'username': username,
            'password': password,
            'remote_id': remoteId,
            'remote_hostname': hostname,
            'memo': 'Remote user registration',
          },
          username);

  Future<Map<String, dynamic>> verifySecondFactor({
    required String key,
    required String code,
    required String username,
  }) =>
      _send(
          '/api/verify_remote_user/2fa',
          {
            'tfa_key': key,
            'tfa_code': code,
          },
          username,
          allowChallenge: false);

  Future<Map<String, dynamic>> _send(
    String path,
    Map<String, dynamic> body,
    String username, {
    bool allowChallenge = true,
  }) async {
    try {
      final base = apiServer.replaceFirst(RegExp(r'/+$'), '');
      final response = await post(
        Uri.parse('$base$path'),
        headers: {'Content-Type': 'application/json'},
        body: jsonEncode(body),
      ).timeout(const Duration(seconds: 10));
      if (response.statusCode != 200) {
        return _failure('서버 오류: ${response.statusCode}');
      }
      final decoded = jsonDecode(response.body);
      if (decoded is! Map<String, dynamic>) {
        return _failure('서버 응답을 해석할 수 없습니다.');
      }
      if (decoded['error'] != null || decoded['code'] == 0) {
        return _failure(
            (decoded['error'] ?? decoded['message'] ?? '계정 확인에 실패했습니다.')
                .toString());
      }
      // Older password-only verification servers must be updated to preserve MFA.
      if (decoded['verification_only'] != true ||
          ['access_token', 'refresh_token', 'accessToken', 'refreshToken']
              .any(decoded.containsKey)) {
        return _failure('원격자 등록 확인을 위해 서버 업데이트가 필요합니다.');
      }
      if (allowChallenge && decoded['tfa_required'] == true) {
        final key = decoded['tfa_key'];
        if (key is! String || key.isEmpty) {
          return _failure('2차 인증 키가 없습니다.');
        }
        final methods = decoded['tfa_methods'];
        return {
          'success': false,
          'tfa_required': true,
          'tfa_key': key,
          'tfa_message': decoded['tfa_message']?.toString(),
          'tfa_methods': methods is List
              ? methods
                  .whereType<Map>()
                  .map((value) => Map<String, dynamic>.from(value))
                  .toList()
              : <Map<String, dynamic>>[],
        };
      }
      if (decoded['code'] == 1 && decoded['tfa_required'] != true) {
        final data = decoded['data'];
        return {
          'success': true,
          'name': data is Map
              ? data['name'] ?? data['username'] ?? username
              : username,
        };
      }
      return _failure('계정 확인에 실패했습니다.');
    } catch (_) {
      return _failure('원격자 계정 확인 중 오류가 발생했습니다. 다시 시도해 주세요.');
    }
  }

  Map<String, dynamic> _failure(String message) => {
        'success': false,
        'message': message,
      };
}
