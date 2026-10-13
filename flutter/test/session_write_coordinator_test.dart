import 'dart:async';

import 'package:flutter_hbb/utils/session_write_coordinator.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('successful operations execute FIFO and never overlap', () async {
    final coordinator = SessionWriteCoordinator();
    final steps = <String>[];
    final first = coordinator.run(() async {
      steps.add('first-start');
      await Future<void>.delayed(Duration.zero);
      steps.add('first-end');
    });
    final second = coordinator.run(() async {
      steps.add('second-start');
      await Future<void>.delayed(Duration.zero);
      steps.add('second-end');
    });
    final third = coordinator.run(() async => steps.add('third'));
    await Future.wait([first, second, third]);
    expect(steps,
        ['first-start', 'first-end', 'second-start', 'second-end', 'third']);
  });

  test('a blocked asynchronous write prevents the next operation from starting',
      () async {
    final coordinator = SessionWriteCoordinator();
    final release = Completer<void>();
    var firstStarted = false;
    var nextStarted = false;
    final first = coordinator.run(() async {
      firstStarted = true;
      await release.future;
    });
    final next = coordinator.run(() async => nextStarted = true);
    await Future<void>.delayed(Duration.zero);
    expect(firstStarted, isTrue);
    expect(nextStarted, isFalse);
    release.complete();
    await Future.wait([first, next]);
    expect(nextStarted, isTrue);
  });

  test(
      'synchronous failure propagates only to its caller and allows next write',
      () async {
    final coordinator = SessionWriteCoordinator();
    final failure = StateError('test sync failure');
    var nextCalled = false;
    final first = coordinator.run(() => throw failure);
    final firstCheck = expectLater(first, throwsA(same(failure)));
    final next = coordinator.run(() async => nextCalled = true);
    await Future.wait([firstCheck, next]);
    expect(nextCalled, isTrue);
  });

  test('asynchronous failure cannot poison subsequent queued writes', () async {
    final coordinator = SessionWriteCoordinator();
    final release = Completer<void>();
    final failure = StateError('test async failure');
    final steps = <String>[];
    final first = coordinator.run(() async {
      steps.add('first');
      await release.future;
      throw failure;
    });
    final firstCheck = expectLater(first, throwsA(same(failure)));
    final second = coordinator.run(() async => steps.add('second'));
    final third = coordinator.run(() async => steps.add('third'));
    await Future<void>.delayed(Duration.zero);
    expect(steps, ['first']);
    release.complete();
    await Future.wait([firstCheck, second, third]);
    expect(steps, ['first', 'second', 'third']);
  });

  test('each failing caller receives its own error while the queue continues',
      () async {
    final coordinator = SessionWriteCoordinator();
    final firstError = StateError('first failure');
    final secondError = ArgumentError('second failure');
    final first = coordinator.run(() => throw firstError);
    final firstCheck = expectLater(first, throwsA(same(firstError)));
    final second = coordinator.run(() async => throw secondError);
    final secondCheck = expectLater(second, throwsA(same(secondError)));
    var success = false;
    final third = coordinator.run(() async => success = true);
    await Future.wait([firstCheck, secondCheck, third]);
    expect(success, isTrue);
  });

  test('operations queued during an active write preserve invocation order',
      () async {
    final coordinator = SessionWriteCoordinator();
    final release = Completer<void>();
    final steps = <int>[];
    final first = coordinator.run(() async {
      steps.add(1);
      await release.future;
    });
    await Future<void>.delayed(Duration.zero);
    final second = coordinator.run(() async => steps.add(2));
    final third = coordinator.run(() async => steps.add(3));
    release.complete();
    await Future.wait([first, second, third]);
    final fourth = coordinator.run(() async => steps.add(4));
    await fourth;
    expect(steps, [1, 2, 3, 4]);
  });
}
