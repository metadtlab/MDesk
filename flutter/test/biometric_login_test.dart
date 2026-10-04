import 'dart:convert';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_hbb/models/biometric_login.dart';
import 'package:flutter_hbb/models/login_session_status.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const channel = MethodChannel('mdesk/biometric_login');
  const login = BiometricLogin();
  final now = DateTime.utc(2026, 10, 4);
  final session = BiometricSession(
    refreshToken: 'test-refresh',
    expiresAt: now.add(const Duration(days: 30)).millisecondsSinceEpoch,
    apiServer: 'https://account.example',
    user: {'name': 'test-user', 'membership_level': 'pro'},
  );

  tearDown(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, null);
  });

  test('saved session contains no password or access credential', () {
    final stored = jsonDecode(session.encode()) as Map<String, dynamic>;
    expect(
        stored.keys,
        unorderedEquals(
            ['version', 'refresh_token', 'expires_at', 'api_server', 'user']));
    final restored = BiometricSession.decode(session.encode());
    expect(restored.refreshToken, session.refreshToken);
    expect(restored.user['name'], 'test-user');
  });

  test('expiry and account server changes require normal login', () {
    expect(session.canRestore(session.apiServer, now), isTrue);
    expect(session.canRestore('https://other.example', now), isFalse);
    expect(
        session.canRestore(session.apiServer,
            DateTime.fromMillisecondsSinceEpoch(session.expiresAt)),
        isFalse);
  });

  test('malformed or unsupported saved credentials are rejected', () {
    for (final payload in [
      'null',
      '[]',
      '{}',
      '{',
      jsonEncode({...jsonDecode(session.encode()), 'version': 2}),
      jsonEncode({...jsonDecode(session.encode()), 'refresh_token': ''}),
      jsonEncode({...jsonDecode(session.encode()), 'expires_at': 'tomorrow'}),
      jsonEncode({
        ...jsonDecode(session.encode()),
        'user': {'name': ''}
      }),
    ]) {
      expect(() => BiometricSession.decode(payload), throwsFormatException);
    }
  });

  test('vault status does not authenticate and cancellation does not restore',
      () async {
    final calls = <String>[];
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (call) async {
      calls.add(call.method);
      switch (call.method) {
        case 'has_session':
          return true;
        case 'is_available':
          return false;
        default:
          return null;
      }
    });
    expect(await login.hasSession(), isTrue);
    expect(await login.isAvailable(), isFalse);
    expect(calls, ['has_session', 'is_available']);
    expect(await login.unlock(), isNull);
    expect(await login.enroll(session), isFalse);
  });

  test('refresh rotation sends only the protected session to native storage',
      () async {
    final calls = <MethodCall>[];
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (call) async {
      calls.add(call);
      if (call.method == 'unlock') return session.encode();
      if (call.method == 'enroll') return true;
      return null;
    });
    expect(await login.enroll(session), isTrue);
    expect((await login.unlock())?.refreshToken, session.refreshToken);
    await login.update(session);
    await login.clear();
    expect(calls.map((call) => call.method),
        ['enroll', 'unlock', 'update', 'clear']);
    expect(BiometricSession.decode(calls[2].arguments).refreshToken,
        session.refreshToken);
  });

  test('invalidated biometrics propagate without a password fallback',
      () async {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (call) async {
      throw PlatformException(code: 'invalidated');
    });
    await expectLater(login.unlock(), throwsA(isA<PlatformException>()));
    expect(BiometricLogin.errorMessage(PlatformException(code: 'invalidated')),
        contains('비밀번호로 로그인'));
  });

  test('enrollment result is serialized with refresh and logout writes',
      () async {
    final writes = LoginSessionWrites();
    final first = writes.run(() async => true);
    final second = writes.run(() async => 'logout');
    expect(await first, isTrue);
    expect(await second, 'logout');
  });
}
