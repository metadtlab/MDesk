import 'dart:async';
import 'dart:io';

import 'package:flutter_hbb/models/model.dart';
import 'package:flutter_hbb/models/user_model.dart';
import 'package:flutter_test/flutter_test.dart';

class _UnusedFfi implements FFI {
  @override
  dynamic noSuchMethod(Invocation invocation) =>
      throw StateError('Windows account retention should not need FFI');
}

class _AccountModel extends UserModel {
  _AccountModel(FFI owner) : super(WeakReference(owner));

  TokenRefreshResult refreshResult = TokenRefreshResult.rejected;
  int refreshCalls = 0;
  int resetCalls = 0;

  @override
  Future<TokenRefreshResult> refreshAccessToken({
    bool force = false,
    String? expectedOrigin,
    int? expectedGeneration,
  }) async {
    refreshCalls++;
    return refreshResult;
  }

  @override
  Future<void> reset({bool resetOther = false}) async {
    resetCalls++;
    userName.value = '';
  }
}

void main() {
  group('Windows account retention', () {
    final timers = <Timer>[];
    late FFI owner;

    setUp(() {
      owner = _UnusedFfi();
    });

    tearDown(() {
      for (final timer in timers) {
        timer.cancel();
      }
      timers.clear();
    });

    _AccountModel account() => runZoned(
          () => _AccountModel(owner)..userName.value = 'alice',
          zoneSpecification: ZoneSpecification(
            createPeriodicTimer: (self, parent, zone, duration, callback) {
              final timer =
                  parent.createPeriodicTimer(zone, duration, callback);
              timers.add(timer);
              return timer;
            },
          ),
        );

    test('connection checks retain login without calling the server', () async {
      final model = account();
      expect(await model.checkLoginSession(), isTrue);
      expect(model.userName.value, 'alice');
      expect(model.refreshCalls, 0);
      expect(model.resetCalls, 0);
    });

    for (final result in TokenRefreshResult.values) {
      test('unauthorized recovery retains login after ${result.name}',
          () async {
        final model = account()..refreshResult = result;
        expect(await model.recoverUnauthorized(), isTrue);
        expect(model.refreshCalls, 1);
        expect(model.resetCalls, 0);
        expect(model.userName.value, 'alice');
        if (result == TokenRefreshResult.rejected ||
            result == TokenRefreshResult.notConfigured) {
          expect(model.networkError.value, isNotEmpty);
        }
      });
    }

    test('an explicit account reset still signs out', () async {
      final model = account();
      await model.recoverUnauthorized();
      await model.reset(resetOther: true);
      expect(model.resetCalls, 1);
      expect(model.isLogin, isFalse);
    });
  }, skip: !Platform.isWindows);
}
