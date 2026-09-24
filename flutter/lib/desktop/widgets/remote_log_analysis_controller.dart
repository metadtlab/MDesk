import 'dart:async';
import 'dart:convert';
import 'package:http/http.dart' as http;

/// Lives in the remote session's isolate. The viewer only receives UI state;
/// credentials and collection grants never cross the window boundary.
class RemoteLogAnalysisController {
  final String peerId;
  final Future<String> Function() apiServer;
  final String Function() accessToken;
  final void Function() checkConnection;
  final void Function()? checkEventConnection;
  final void Function(String) collect;
  final http.Client _client;
  final Duration pollInterval;
  bool _disposed = false,
      _loaded = false,
      _loading = true,
      _running = false,
      _finished = false;
  Future<void>? _loadFuture;
  String _base = '', _token = '', _message = '분석 항목을 불러오는 중…';
  String _provider = 'openai';
  List<Map<String, dynamic>> _profiles = [];
  List<Map<String, dynamic>> _history = [];
  String _historyError = '';
  Future<void>? _historyFuture;
  Map<String, dynamic>? _result;
  List<dynamic> _warnings = [];
  int _warningsOmitted = 0;

  RemoteLogAnalysisController(
      {required this.peerId,
      required this.apiServer,
      required this.accessToken,
      required this.checkConnection,
      this.checkEventConnection,
      required this.collect,
      http.Client? client,
      this.pollInterval = const Duration(seconds: 2)})
      : _client = client ?? http.Client();

  Map<String, dynamic> get snapshot => {
        'loading': _loading,
        'running': _running,
        'finished': _finished,
        'message': _message,
        'profiles': _profiles,
        'aiProvider': _provider,
        'history': _history,
        'historyError': _historyError,
        'historyLoading': _historyFuture != null,
        'collectionWarnings': _warnings,
        'warningsOmitted': _warningsOmitted,
        if (_result != null) 'result': _result
      };

  void dispose() {
    _disposed = true;
    _client.close();
  }

  void _check() {
    if (_disposed) throw Exception('원격 연결이 종료되었습니다.');
    checkConnection();
  }

  Future<Map<String, dynamic>> _request(String path,
      {Map<String, dynamic>? body, Map<String, String>? query}) async {
    if (_disposed) throw Exception('원격 연결이 종료되었습니다.');
    final uri = Uri.parse('$_base/api/log-analysis/$path')
        .replace(queryParameters: query);
    final headers = {
      'Authorization': 'Bearer $_token',
      'Content-Type': 'application/json'
    };
    final response = await (body == null
            ? _client.get(uri, headers: headers)
            : _client.post(uri, headers: headers, body: jsonEncode(body)))
        .timeout(const Duration(seconds: 15));
    if (_disposed) throw Exception('원격 연결이 종료되었습니다.');
    final data = jsonDecode(utf8.decode(response.bodyBytes));
    if (response.statusCode != 200 ||
        data is! Map<String, dynamic> ||
        data['code'] != 1) {
      throw Exception(data is Map
          ? data['msg'] ?? '분석 요청을 처리할 수 없습니다. (${response.statusCode})'
          : 'API 응답을 확인해주세요.');
    }
    return data;
  }

  Future<void> load({bool retry = false}) {
    if (_loadFuture != null) return _loadFuture!;
    if (_disposed || _running || _loaded && !retry) return Future.value();
    _loadFuture = _load().whenComplete(() => _loadFuture = null);
    return _loadFuture!;
  }

  Future<void> _load() async {
    _loading = true;
    _finished = false;
    _result = null;
    _profiles = [];
    _warnings = [];
    _warningsOmitted = 0;
    _message = '분석 항목을 불러오는 중…';
    try {
      _base = (await apiServer()).replaceAll(RegExp(r'/+$'), '');
      _token = accessToken();
      if (_token.isEmpty) throw Exception('MDesk 계정으로 로그인해주세요.');
      final origin = Uri.tryParse(_base);
      if (origin == null ||
          !(origin.scheme == 'https' ||
              origin.scheme == 'http' &&
                  ['localhost', '127.0.0.1', '::1', 'admin.localhost']
                      .contains(origin.host))) {
        throw Exception('로그 분석을 사용할 HTTPS API 서버 주소를 설정해주세요.');
      }
      await refreshHistory();
      final response = await _request('profiles', query: {'peerId': peerId});
      _provider = response['aiProvider'] as String? ?? 'openai';
      if (!['openai', 'glm'].contains(_provider)) {
        throw Exception('지원하지 않는 AI 공급자입니다.');
      }
      _profiles = (response['data'] as List)
          .map((row) => Map<String, dynamic>.from(row))
          .toList();
      _loaded = true;
      _message = _profiles.isEmpty
          ? '이 기업에서 사용 중인 분석 항목이 없습니다. API 웹사이트의 로그 분석 설정을 확인해주세요.'
          : '분석할 항목을 선택해주세요.';
    } catch (e) {
      _message = _error(e);
    } finally {
      _loading = false;
    }
  }

  void start(int profileId) {
    if (_disposed ||
        _loading ||
        _running ||
        _finished ||
        !_profiles.any((p) => p['id'] == profileId)) {
      return;
    }
    _running = true;
    _message = '수집 요청을 준비하고 있습니다…';
    unawaited(_start(profileId));
  }

  Future<void> refreshHistory() {
    if (_disposed || _base.isEmpty || _token.isEmpty) return Future.value();
    return _historyFuture ??=
        _refreshHistory().whenComplete(() => _historyFuture = null);
  }

  Future<void> _refreshHistory() async {
    _historyError = '';
    try {
      final response = await _request('history', query: {'peerId': peerId});
      _history = (response['data'] as List)
          .take(5)
          .map((row) => Map<String, dynamic>.from(row))
          .toList();
    } catch (e) {
      _history = [];
      _historyError = '최근 결과를 불러오지 못했습니다. ${_error(e)}';
    }
  }

  Future<void> _start(int profileId) async {
    try {
      _check();
      if (_profiles
          .any((p) => p['id'] == profileId && p['windowsEvents'] == true)) {
        if (checkEventConnection == null) {
          throw Exception('Windows 이벤트 로그 수집 지원 여부를 확인할 수 없습니다.');
        }
        checkEventConnection!();
      }
      final created = await _request('jobs', body: {
        'peerId': peerId,
        'profileId': profileId,
        'provider': _provider
      });
      _check();
      collect('##MDESK_LOG_ANALYSIS_V1##${jsonEncode({
            'jobId': created['jobId'],
            'collectionToken': created['collectionToken']
          })}');
      final deadline = DateTime.now().add(const Duration(minutes: 2));
      while (!_disposed && DateTime.now().isBefore(deadline)) {
        final status = await _request('jobs/${created['jobId']}');
        if (status['phase'] == 'DONE') {
          _result = Map<String, dynamic>.from(status['result']);
          _message = '로그 분석이 완료되었습니다.';
          await refreshHistory();
          return;
        }
        if (status['phase'] == 'FAILED') {
          _warnings = status['result']['collectionWarnings'] as List? ?? [];
          _warningsOmitted = status['result']['warningsOmitted'] as int? ?? 0;
          throw Exception(status['result']['message'] ?? '로그 분석에 실패했습니다.');
        }
        _message = status['phase'] == 'ANALYZING'
            ? 'API 서버에서 분석하고 있습니다…'
            : '피원격 PC에서 로그를 수집하고 있습니다…';
        await Future<void>.delayed(pollInterval);
      }
      throw Exception('분석 대기 시간이 초과되었습니다. 원격 연결과 API 서버를 확인해주세요.');
    } catch (e) {
      _message = _error(e);
    } finally {
      _running = false;
      _finished = true;
    }
  }

  String _error(Object error) {
    if (error is TimeoutException) return '서버 응답 시간이 초과되었습니다.';
    if (error is FormatException) return 'API 서버 응답 형식이 올바르지 않습니다.';
    final message = error.toString().replaceFirst('Exception: ', '');
    // Provider details remain available to administrators on the API server.
    if (RegExp(r'openai|glm|z\.ai', caseSensitive: false).hasMatch(message)) {
      return 'API 서버에서 분석하지 못했습니다. 관리자에게 서버 설정과 이용 한도를 확인해주세요.';
    }
    return message;
  }
}
