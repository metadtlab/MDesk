import 'dart:convert';

/// Explicit revocation must bypass token refresh and the login grace period.
enum LoginSessionStatus { active, replaced, revoked, expired, unavailable }

LoginSessionStatus parseLoginSessionStatus(int statusCode, String body) {
  try {
    final data = jsonDecode(body);
    if (data is! Map) return LoginSessionStatus.unavailable;
    if (statusCode == 200 && data['active'] == true) {
      return LoginSessionStatus.active;
    }
    if (statusCode == 401) {
      switch (data['error_code']) {
        case 'session_replaced':
          return LoginSessionStatus.replaced;
        case 'session_revoked':
          return LoginSessionStatus.revoked;
        case 'session_expired':
          return LoginSessionStatus.expired;
      }
    }
  } catch (_) {}
  // Old servers, proxies and network errors cannot prove revocation.
  return LoginSessionStatus.unavailable;
}

class LoginSessionSnapshot {
  final int generation;
  final String accessToken;

  const LoginSessionSnapshot(this.generation, this.accessToken);

  bool matches(int currentGeneration, String currentToken) =>
      generation == currentGeneration && accessToken == currentToken;
}

/// Keeps logout/login/refresh credential writes from interleaving across awaits.
class LoginSessionWrites {
  Future<void> _tail = Future<void>.value();

  Future<T> run<T>(Future<T> Function() mutation) {
    final next = _tail.then((_) => mutation());
    _tail = next.then<void>((_) {}).catchError((Object _) {});
    return next;
  }
}
