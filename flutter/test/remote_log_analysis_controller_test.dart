import 'dart:async';
import 'dart:convert';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:flutter_hbb/desktop/widgets/remote_log_analysis_controller.dart';

void main() {
  for (final provider in ['openai', 'glm']) {
    test('$provider progress and errors never display vendor names', () async {
      final finished = Completer<http.Response>();
      var polls = 0;
      final controller = RemoteLogAnalysisController(
          peerId: '123',
          apiServer: () async => 'https://example.invalid',
          accessToken: () => 'token',
          checkConnection: () {},
          collect: (_) {},
          pollInterval: Duration.zero,
          client: MockClient((request) async {
            if (request.url.path.endsWith('history')) {
              return http.Response(jsonEncode({'code': 1, 'data': []}), 200);
            }
            if (request.url.path.endsWith('profiles')) {
              return http.Response(
                  jsonEncode({
                    'code': 1,
                    'aiProvider': provider,
                    'data': [
                      {'id': 7, 'name': 'Windows'}
                    ]
                  }),
                  200);
            }
            if (request.method == 'POST') {
              expect(jsonDecode(request.body)['provider'], provider);
              return http.Response(
                  jsonEncode(
                      {'code': 1, 'jobId': 'job', 'collectionToken': 'grant'}),
                  200);
            }
            if (polls++ == 0) {
              return http.Response(
                  jsonEncode({'code': 1, 'phase': 'ANALYZING'}), 200);
            }
            return finished.future;
          }));
      addTearDown(controller.dispose);
      await controller.load();
      controller.start(7);
      await Future<void>.delayed(Duration.zero);
      expect(controller.snapshot['message'], 'API 서버에서 분석하고 있습니다…');
      finished.complete(http.Response(
          jsonEncode({
            'code': 1,
            'phase': 'FAILED',
            'result': {
              'message': provider == 'glm'
                  ? 'GLM Z.ai GLM_API_KEY 설정 필요'
                  : 'OpenAI OPENAI_API_KEY 설정 필요'
            }
          }),
          200,
          headers: {'content-type': 'application/json; charset=utf-8'}));
      for (var i = 0; i < 20 && controller.snapshot['finished'] != true; i++) {
        await Future<void>.delayed(Duration.zero);
      }
      expect(controller.snapshot['finished'], true);
      expect(controller.snapshot['message'],
          'API 서버에서 분석하지 못했습니다. 관리자에게 서버 설정과 이용 한도를 확인해주세요.');
    });
  }
  for (final changed in [false, true]) {
    test('GLM consent is pinned in job request; changed=$changed', () async {
      var collected = false;
      var jobs = 0;
      final controller = RemoteLogAnalysisController(
          peerId: '123',
          apiServer: () async => 'https://example.invalid',
          accessToken: () => 'token',
          checkConnection: () {},
          collect: (_) => collected = true,
          client: MockClient((request) async {
            if (request.url.path.endsWith('history')) {
              return http.Response(jsonEncode({'code': 1, 'data': []}), 200);
            }
            if (request.url.path.endsWith('profiles')) {
              return http.Response(
                  jsonEncode({
                    'code': 1,
                    'aiProvider': 'glm',
                    'data': [
                      {'id': 7, 'name': 'Windows'}
                    ]
                  }),
                  200);
            }
            if (request.method == 'POST') {
              jobs++;
              expect(jsonDecode(request.body)['provider'], 'glm');
              if (changed)
                return http.Response(
                    jsonEncode(
                        {'code': 0, 'msg': 'AI provider changed; reload'}),
                    409);
              return http.Response(
                  jsonEncode({
                    'code': 1,
                    'jobId': 'job',
                    'collectionToken': 'grant',
                    'provider': 'glm'
                  }),
                  200);
            }
            return http.Response(
                jsonEncode({
                  'code': 1,
                  'phase': 'DONE',
                  'result': {'summary': '## GLM', 'provider': 'glm'}
                }),
                200);
          }));
      addTearDown(controller.dispose);
      await controller.load();
      expect(controller.snapshot['aiProvider'], 'glm');
      controller.start(7);
      await Future<void>.delayed(Duration.zero);
      expect(jobs, 1);
      expect(collected, !changed);
      expect(controller.snapshot['finished'], true);
      if (changed) {
        expect(controller.snapshot['message'], contains('provider changed'));
      } else {
        expect(controller.snapshot['result']['provider'], 'glm');
      }
    });
  }
  test(
      'history works without collector capability; event start is blocked before creating a job',
      () async {
    var jobs = 0;
    final controller = RemoteLogAnalysisController(
        peerId: '123',
        apiServer: () async => 'https://example.invalid',
        accessToken: () => 'token',
        checkConnection: () {},
        checkEventConnection: () => throw Exception('update required'),
        collect: (_) => fail('must not collect'),
        client: MockClient((request) async {
          if (request.method == 'POST') jobs++;
          return http.Response(
              jsonEncode({
                'code': 1,
                'data': request.url.path.endsWith('history')
                    ? [
                        {
                          'id': 'saved',
                          'result': {'summary': '## Stored'}
                        }
                      ]
                    : [
                        {'id': 7, 'name': 'Windows', 'windowsEvents': true}
                      ]
              }),
              200);
        }));
    addTearDown(controller.dispose);
    await controller.load();
    expect(controller.snapshot['history'][0]['id'], 'saved');
    controller.start(7);
    await Future<void>.delayed(Duration.zero);
    expect(jobs, 0);
    expect(controller.snapshot['message'], contains('update required'));
    expect(controller.snapshot['history'][0]['id'], 'saved');
  });
  test(
      'one job per start; snapshots never expose credentials; load preserves result',
      () async {
    final complete = Completer<void>();
    var jobs = 0;
    String? envelope;
    final client = MockClient((request) async {
      expect(request.headers['Authorization'], 'Bearer private-access-token');
      if (request.url.path.endsWith('history')) {
        expect(request.url.queryParameters['peerId'], '123');
        return http.Response(jsonEncode({'code': 1, 'data': []}), 200);
      }
      if (request.url.path.endsWith('profiles')) {
        return http.Response(
            jsonEncode({
              'code': 1,
              'data': [
                {'id': 7, 'name': 'DB'}
              ]
            }),
            200);
      }
      if (request.method == 'POST') {
        expect(jsonDecode(request.body)['provider'], 'openai');
        jobs++;
        return http.Response(
            jsonEncode({
              'code': 1,
              'jobId': 'job',
              'collectionToken': 'private-grant'
            }),
            200);
      }
      await complete.future;
      return http.Response(
          jsonEncode({
            'code': 1,
            'phase': 'DONE',
            'result': {'summary': '## Done', 'format': 'markdown'}
          }),
          200);
    });
    final controller = RemoteLogAnalysisController(
        peerId: '123',
        apiServer: () async => 'https://example.invalid',
        accessToken: () => 'private-access-token',
        checkConnection: () {},
        collect: (value) => envelope = value,
        client: client);
    addTearDown(controller.dispose);
    await controller.load();
    controller.start(999);
    expect(jobs, 0);
    controller.start(7);
    controller.start(7);
    await Future<void>.delayed(Duration.zero);
    expect(jobs, 1);
    expect(envelope, contains('private-grant'));
    expect(controller.snapshot['running'], true);
    expect(jsonEncode(controller.snapshot), isNot(contains('private-')));
    complete.complete();
    await Future<void>.delayed(Duration.zero);
    expect(controller.snapshot['finished'], true);
    expect(controller.snapshot['result']['summary'], '## Done');
    await controller.load();
    expect(controller.snapshot['result']['summary'], '## Done');
    expect(jobs, 1);
  });

  test(
      'closing remote session while job creation is in flight never sends collection command',
      () async {
    final grant = Completer<http.Response>();
    var collected = false;
    final client = MockClient((request) async => request.method == 'POST'
        ? await grant.future
        : http.Response(
            jsonEncode({
              'code': 1,
              'data': [
                {'id': 7, 'name': 'DB'}
              ]
            }),
            200));
    final controller = RemoteLogAnalysisController(
        peerId: '123',
        apiServer: () async => 'https://example.invalid',
        accessToken: () => 'token',
        checkConnection: () {},
        collect: (_) => collected = true,
        client: client);
    await controller.load();
    controller.start(7);
    controller.dispose();
    grant.complete(http.Response(
        jsonEncode({'code': 1, 'jobId': 'job', 'collectionToken': 'grant'}),
        200));
    await Future<void>.delayed(Duration.zero);
    expect(collected, false);
    expect(controller.snapshot['running'], false);
  });
}
