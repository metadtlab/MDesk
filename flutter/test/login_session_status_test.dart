import 'dart:async';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_hbb/models/login_session_status.dart';

void main() {
  test('new login writes wait for an in-flight old refresh to finish',
      () async {
    final writes = LoginSessionWrites();
    final oldRefreshPaused = Completer<void>();
    final oldRefreshStarted = Completer<void>();
    var access = 'old-access';
    var refresh = 'old-refresh';
    final older = writes.run(() async {
      access = 'rotated-old-access';
      oldRefreshStarted.complete();
      await oldRefreshPaused.future;
      refresh = 'rotated-old-refresh';
    });
    await oldRefreshStarted.future;
    final newer = writes.run(() async {
      access = 'new-access';
      refresh = 'new-refresh';
    });
    oldRefreshPaused.complete();
    await Future.wait([older, newer]);
    expect((access, refresh), ('new-access', 'new-refresh'));
  });

  test('a failed credential write does not block subsequent login', () async {
    final writes = LoginSessionWrites();
    await expectLater(writes.run(() async {
      throw StateError('failed write');
    }), throwsStateError);
    var recovered = false;
    await writes.run(() async {
      recovered = true;
    });
    expect(recovered, isTrue);
  });

  test('distinguishes replacement, revocation and refreshable expiry', () {
    expect(parseLoginSessionStatus(200, '{"active":true}'),
        LoginSessionStatus.active);
    expect(parseLoginSessionStatus(401, '{"error_code":"session_replaced"}'),
        LoginSessionStatus.replaced);
    expect(parseLoginSessionStatus(401, '{"error_code":"session_revoked"}'),
        LoginSessionStatus.revoked);
    expect(parseLoginSessionStatus(401, '{"error_code":"session_expired"}'),
        LoginSessionStatus.expired);
  });

  test('network, malformed and old-server responses do not force logout', () {
    for (final response in [
      (404, 'not found'),
      (502, '<html>'),
      (200, '{}'),
      (401, '{}'),
      (401, '[]')
    ]) {
      expect(parseLoginSessionStatus(response.$1, response.$2),
          LoginSessionStatus.unavailable);
    }
    expect(parseLoginSessionStatus(503, '{"error_code":"session_replaced"}'),
        LoginSessionStatus.unavailable);
  });

  test(
      'a delayed revoked response cannot clear a newer login or refreshed token',
      () async {
    const old = LoginSessionSnapshot(1, 'old-access');
    final response = Completer<LoginSessionStatus>();
    var signedOut = false;
    final pending = response.future.then((status) {
      if (old.matches(2, 'new-access') &&
          status == LoginSessionStatus.replaced) {
        signedOut = true;
      }
    });
    response.complete(LoginSessionStatus.replaced);
    await pending;
    expect(signedOut, isFalse);
    expect(old.matches(1, 'rotated-access'), isFalse);
    expect(old.matches(2, 'old-access'), isFalse);
    expect(old.matches(1, 'old-access'), isTrue);
  });
}
