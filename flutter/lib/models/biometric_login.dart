import 'dart:convert';

import 'package:flutter/services.dart';

/// Only a refresh credential is saved; passwords and access tokens are excluded.
class BiometricSession {
  final String refreshToken;
  final int expiresAt;
  final String apiServer;
  final Map<String, dynamic> user;

  const BiometricSession(
      {required this.refreshToken,
      required this.expiresAt,
      required this.apiServer,
      required this.user});

  String encode() => jsonEncode({
        'version': 1,
        'refresh_token': refreshToken,
        'expires_at': expiresAt,
        'api_server': apiServer,
        'user': user,
      });

  factory BiometricSession.decode(String encoded) {
    final data = jsonDecode(encoded);
    if (data is! Map<String, dynamic> ||
        data['version'] != 1 ||
        data['refresh_token'] is! String ||
        (data['refresh_token'] as String).isEmpty ||
        data['expires_at'] is! int ||
        data['api_server'] is! String ||
        (data['api_server'] as String).isEmpty ||
        data['user'] is! Map<String, dynamic> ||
        data['user']['name'] is! String ||
        (data['user']['name'] as String).isEmpty) {
      throw const FormatException('Invalid biometric session');
    }
    return BiometricSession(
        refreshToken: data['refresh_token'],
        expiresAt: data['expires_at'],
        apiServer: data['api_server'],
        user: data['user']);
  }

  bool canRestore(String server, DateTime now) =>
      apiServer == server && now.millisecondsSinceEpoch < expiresAt;
}

/// Native code binds the encryption key to the current biometric enrollment.
/// Token rotation reuses an in-memory data key only after a successful unlock.
class BiometricLogin {
  final MethodChannel channel;
  const BiometricLogin(
      {this.channel = const MethodChannel('mdesk/biometric_login')});

  Future<bool> hasSession() async =>
      await channel.invokeMethod<bool>('has_session') ?? false;
  Future<bool> isAvailable() async =>
      await channel.invokeMethod<bool>('is_available') ?? false;
  Future<bool> enroll(BiometricSession session) async =>
      await channel.invokeMethod<bool>('enroll', session.encode()) ?? false;
  Future<BiometricSession?> unlock() async {
    final data = await channel.invokeMethod<String>('unlock');
    return data == null ? null : BiometricSession.decode(data);
  }

  Future<void> update(BiometricSession session) =>
      channel.invokeMethod<void>('update', session.encode());
  Future<void> clear() => channel.invokeMethod<void>('clear');
  Future<void> cancel() => channel.invokeMethod<void>('cancel');

  static String errorMessage(Object error) {
    if (error is PlatformException) {
      switch (error.code) {
        case 'unavailable':
          return '기기 설정에서 지문 또는 얼굴 인식을 등록해 주세요. 지원되는 생체인증이 필요합니다.';
        case 'invalidated':
          return '생체정보가 변경되었거나 저장된 인증 정보를 사용할 수 없습니다. 비밀번호로 로그인해 다시 설정해 주세요.';
        case 'expired':
          return '로그인 세션이 만료되었습니다. 비밀번호로 다시 로그인해 주세요.';
        case 'network':
          return '로그인 서버에 연결할 수 없습니다. 연결 상태를 확인하고 다시 시도해 주세요.';
        case 'not_configured':
          return '먼저 비밀번호로 로그인한 후 생체인증 로그인을 설정해 주세요.';
        case 'busy':
          return '진행 중인 생체인증을 완료해 주세요.';
      }
    }
    return '생체인증을 완료하지 못했습니다. 다시 시도하거나 비밀번호로 로그인해 주세요.';
  }
}
