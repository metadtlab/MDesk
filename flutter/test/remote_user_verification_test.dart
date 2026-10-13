import 'dart:convert';

import 'package:flutter_hbb/utils/remote_user_verification.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;

void main() {
  test(
      'registration verifies credentials without calling login or passing session identity',
      () async {
    final verifier = RemoteUserVerificationClient(
      apiServer: 'https://admin.787.kr/',
      post: (url, {headers, body}) async {
        expect(url.toString(), 'https://admin.787.kr/api/verify_remote_user');
        expect(url.query, isEmpty);
        expect(headers, {'Content-Type': 'application/json'});
        expect(jsonDecode(body as String), {
          'username': 'alice',
          'password': 'pw',
          'remote_id': 'host-b',
          'remote_hostname': 'Host B',
          'memo': 'Remote user registration',
        });
        return http.Response(
            jsonEncode({
              'code': 1,
              'verification_only': true,
              'data': {'name': 'Alice'},
            }),
            200);
      },
    );
    expect(
        await verifier.verify(
            username: 'alice',
            password: 'pw',
            remoteId: 'host-b',
            hostname: 'Host B'),
        {'success': true, 'name': 'Alice'});
  });

  test('second factor uses only the registration verification endpoint',
      () async {
    final paths = <String>[];
    final verifier = RemoteUserVerificationClient(
      apiServer: 'https://admin.787.kr',
      post: (url, {headers, body}) async {
        paths.add(url.path);
        if (paths.length == 1) {
          return http.Response(
              jsonEncode({
                'verification_only': true,
                'tfa_required': true,
                'tfa_key': 'remote-key',
                'tfa_methods': [
                  {'type': 'email', 'target': '***'}
                ],
              }),
              200);
        }
        expect(jsonDecode(body as String),
            {'tfa_key': 'remote-key', 'tfa_code': '123456'});
        return http.Response(
            '{"code":1,"verification_only":true,"data":{"name":"Alice"}}', 200);
      },
    );
    final challenge = await verifier.verify(
        username: 'alice',
        password: 'pw',
        remoteId: 'host-b',
        hostname: 'Host B');
    expect(challenge['success'], isFalse);
    expect(challenge['tfa_required'], isTrue);
    expect(
        await verifier.verifySecondFactor(
            key: challenge['tfa_key'], code: '123456', username: 'alice'),
        {'success': true, 'name': 'Alice'});
    expect(paths, ['/api/verify_remote_user', '/api/verify_remote_user/2fa']);
  });

  for (final response in [
    http.Response('{"code":0,"message":"wrong password"}', 200),
    http.Response('{"access_token":"app-token","type":"access_token"}', 200),
    http.Response('{"code":1,"data":{"name":"Alice"}}', 200),
    http.Response(
        '{"verification_only":true,"code":1,"access_token":"unexpected"}', 200),
    http.Response('{"verification_only":true,"tfa_required":true}', 200),
    http.Response('null', 200),
    http.Response('invalid json', 200),
    http.Response('not found', 404),
    http.Response('<html>Bad Gateway</html>', 502),
  ]) {
    test(
        'unsupported or failed verification stays closed: ${response.statusCode} ${response.body}',
        () async {
      final verifier = RemoteUserVerificationClient(
        apiServer: 'https://admin.787.kr',
        post: (url, {headers, body}) async => response,
      );
      expect(
          (await verifier.verify(
              username: 'alice',
              password: 'pw',
              remoteId: 'host-b',
              hostname: 'Host B'))['success'],
          isFalse);
      expect(
          (await verifier.verifySecondFactor(
              key: 'key', code: 'code', username: 'alice'))['success'],
          isFalse);
    });
  }

  test('network failure never substitutes a login call or grants registration',
      () async {
    var calls = 0;
    final verifier = RemoteUserVerificationClient(
      apiServer: 'https://admin.787.kr',
      post: (url, {headers, body}) async {
        calls++;
        expect(url.path, '/api/verify_remote_user');
        throw Exception('offline');
      },
    );
    expect(
        (await verifier.verify(
            username: 'alice',
            password: 'pw',
            remoteId: 'host-b',
            hostname: 'Host B'))['success'],
        isFalse);
    expect(calls, 1);
  });
}
