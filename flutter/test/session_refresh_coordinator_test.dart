import 'dart:async';

import 'package:flutter_hbb/utils/session_refresh_coordinator.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('same generation and server share one request and result', () async {
    final coordinator = SessionRefreshCoordinator<String>();
    final response = Completer<String>();
    var calls = 0;
    Future<String> request() {
      calls++;
      return response.future;
    }

    final first = coordinator.run(
        generation: 1, server: 'https://account.example', request: request);
    final second = coordinator.run(
        generation: 1, server: 'https://account.example', request: request);
    expect(calls, 1);
    response.complete('refreshed');
    expect(await first, 'refreshed');
    expect(await second, 'refreshed');
  });

  test('different login generations do not inherit a stale refresh result',
      () async {
    final coordinator = SessionRefreshCoordinator<String>();
    final oldResponse = Completer<String>();
    final newResponse = Completer<String>();
    var calls = 0;
    final old = coordinator.run(
      generation: 1,
      server: 'https://account.example',
      request: () {
        calls++;
        return oldResponse.future;
      },
    );
    final fresh = coordinator.run(
      generation: 2,
      server: 'https://account.example',
      request: () {
        calls++;
        return newResponse.future;
      },
    );
    expect(calls, 2);
    oldResponse.complete('old-rejected');
    newResponse.complete('new-success');
    expect(await old, 'old-rejected');
    expect(await fresh, 'new-success');
  });

  test('different servers never share refresh credentials or results',
      () async {
    final coordinator = SessionRefreshCoordinator<int>();
    final firstResponse = Completer<int>();
    final otherResponse = Completer<int>();
    var calls = 0;
    final first = coordinator.run(
      generation: 1,
      server: 'https://account.example',
      request: () {
        calls++;
        return firstResponse.future;
      },
    );
    final other = coordinator.run(
      generation: 1,
      server: 'https://other.example',
      request: () {
        calls++;
        return otherResponse.future;
      },
    );
    expect(calls, 2);
    firstResponse.complete(1);
    otherResponse.complete(2);
    expect(await first, 1);
    expect(await other, 2);
  });

  test('old completion cannot clear the newer in-flight generation', () async {
    final coordinator = SessionRefreshCoordinator<String>();
    final oldResponse = Completer<String>();
    final newResponse = Completer<String>();
    var newCalls = 0;
    final old = coordinator.run(
      generation: 1,
      server: 'https://account.example',
      request: () => oldResponse.future,
    );
    Future<String> newRequest() {
      newCalls++;
      return newResponse.future;
    }

    final fresh = coordinator.run(
        generation: 2, server: 'https://account.example', request: newRequest);
    oldResponse.complete('old');
    expect(await old, 'old');
    final joined = coordinator.run(
        generation: 2, server: 'https://account.example', request: newRequest);
    expect(newCalls, 1);
    newResponse.complete('new');
    expect(await fresh, 'new');
    expect(await joined, 'new');
  });

  test('interleaved servers still join their own in-flight refresh', () async {
    final coordinator = SessionRefreshCoordinator<int>();
    final firstResponse = Completer<int>();
    final otherResponse = Completer<int>();
    var firstCalls = 0;
    Future<int> firstRequest() {
      firstCalls++;
      return firstResponse.future;
    }

    final first =
        coordinator.run(generation: 1, server: 'first', request: firstRequest);
    final other = coordinator.run(
        generation: 1, server: 'other', request: () => otherResponse.future);
    final firstAgain =
        coordinator.run(generation: 1, server: 'first', request: firstRequest);
    expect(firstCalls, 1);
    firstResponse.complete(1);
    otherResponse.complete(2);
    expect(await first, 1);
    expect(await firstAgain, 1);
    expect(await other, 2);
  });

  test('a completed refresh does not cache results for subsequent calls',
      () async {
    final coordinator = SessionRefreshCoordinator<int>();
    var calls = 0;
    Future<int> request() async => ++calls;
    expect(
        await coordinator.run(
            generation: 1, server: 'server', request: request),
        1);
    expect(
        await coordinator.run(
            generation: 1, server: 'server', request: request),
        2);
  });

  test('synchronous request failure is a Future error and permits retry',
      () async {
    final coordinator = SessionRefreshCoordinator<int>();
    final failure = StateError('test failure');
    late Future<int> attempt;
    expect(
      () => attempt = coordinator.run(
        generation: 1,
        server: 'server',
        request: () => throw failure,
      ),
      returnsNormally,
    );
    await expectLater(attempt, throwsA(same(failure)));
    expect(
        await coordinator.run(
            generation: 1, server: 'server', request: () async => 7),
        7);
  });

  test('asynchronous failure propagates to joined callers and clears its entry',
      () async {
    final coordinator = SessionRefreshCoordinator<int>();
    final response = Completer<int>();
    final failure = StateError('test async failure');
    final first = coordinator.run(
        generation: 1, server: 'server', request: () => response.future);
    final joined = coordinator.run(
        generation: 1, server: 'server', request: () => response.future);
    final firstCheck = expectLater(first, throwsA(same(failure)));
    final joinedCheck = expectLater(joined, throwsA(same(failure)));
    response.completeError(failure);
    await Future.wait([firstCheck, joinedCheck]);
    expect(
        await coordinator.run(
            generation: 1, server: 'server', request: () async => 9),
        9);
  });

  test('old failure leaves a newer refresh pooled', () async {
    final coordinator = SessionRefreshCoordinator<int>();
    final oldResponse = Completer<int>();
    final newResponse = Completer<int>();
    final old = coordinator.run(
        generation: 1, server: 'server', request: () => oldResponse.future);
    final fresh = coordinator.run(
        generation: 2, server: 'server', request: () => newResponse.future);
    final oldCheck = expectLater(old, throwsStateError);
    oldResponse.completeError(StateError('old failure'));
    await oldCheck;
    var extraRequests = 0;
    final joined = coordinator.run(
      generation: 2,
      server: 'server',
      request: () async {
        extraRequests++;
        return 99;
      },
    );
    expect(extraRequests, 0);
    newResponse.complete(2);
    expect(await fresh, 2);
    expect(await joined, 2);
  });

  test('server keys are exact and are not normalized by the coordinator',
      () async {
    final coordinator = SessionRefreshCoordinator<int>();
    final firstResponse = Completer<int>();
    final otherResponse = Completer<int>();
    var calls = 0;
    final first = coordinator.run(
      generation: 1,
      server: 'https://account.example',
      request: () {
        calls++;
        return firstResponse.future;
      },
    );
    final other = coordinator.run(
      generation: 1,
      server: 'https://account.example/',
      request: () {
        calls++;
        return otherResponse.future;
      },
    );
    expect(calls, 2);
    firstResponse.complete(1);
    otherResponse.complete(2);
    expect(await first, 1);
    expect(await other, 2);
  });
}
