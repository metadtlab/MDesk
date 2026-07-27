import 'dart:async';
import 'dart:convert';
import 'dart:io' show Platform;
import 'package:flutter/material.dart';
import 'package:flutter_hbb/common/formatter/id_formatter.dart';
import 'package:flutter_hbb/common/widgets/root_overlay_control.dart';
import 'package:get/get.dart';
import 'package:http/http.dart' as http;
import '../../common.dart';
import '../../models/model.dart';
import '../../models/platform_model.dart';
import '../../models/state_model.dart';
import 'login.dart';
import '../../utils/device_register_service.dart';

/// 상담사 추가 버튼·관련 안내 표시. 추후 사용 시 true로 변경.
const bool _kShowAddCounselorButton = false;
const String _kLastCertCodeOptionPrefix = 'custom-remote-last-cert-code';
const String _kLastCertStoredAtOptionPrefix =
    'custom-remote-last-cert-stored-at';
const String _kLastRemoteIdOptionPrefix = 'custom-remote-last-peer-id';
const Duration _kCertDisplayLifetime = Duration(minutes: 5);
const String _kMdeskMiniAutoConnectPasswordPreset =
    '__MDESKMINI_AUTO_CONNECT_V1__';

class CustomRemoteView extends StatefulWidget {
  final EdgeInsets? menuPadding;
  final bool useNumberManagementDesign;

  const CustomRemoteView({
    Key? key,
    this.menuPadding,
    this.useNumberManagementDesign = true,
  }) : super(key: key);

  @override
  State<CustomRemoteView> createState() => _CustomRemoteViewState();
}

class _CustomRemoteViewState extends State<CustomRemoteView>
    with SingleTickerProviderStateMixin, WidgetsBindingObserver {
  List<Map<String, dynamic>> _counselors = [];
  List<Map<String, dynamic>> _devices = []; // 디바이스 목록
  bool _isLoading = false;
  bool _isFetching = false;
  String _message = '';
  late AnimationController _blinkController;
  Timer? _autoRefreshTimer; // 자동 새로고침 타이머
  Timer? _certStatusRefreshTimer;
  Timer? _directAutoConnectTimer;
  Timer? _certDisplayExpiryTimer;
  Worker? _remoteConnectedWorker;
  String _scheduledDirectRemoteId = '';
  String _lastAutoConnectedRemoteId = '';
  String _lastPromptedDirectRemoteId = '';
  String _directRemotePromptId = '';
  String _lastDirectRemoteId = '';
  String _restoredSessionCacheScope = '';
  bool _showReconnectButton = false;
  bool _isAppFocused = true; // 앱 포커스 상태

  // 인증번호 관련 상태
  String _certCode = '';
  String _expiredCertCode = '';
  bool _isCertLoading = false;
  bool _isSearchingCertStatus = false;
  String _certReadinessStage = 'waiting';
  int _certReadinessProgress = 0;
  String _certReadinessMessage = '인증번호 생성을 기다리는 중입니다.';
  String _certReadinessRemoteId = '';

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this); // 앱 상태 감시 등록

    // 깜빡임 애니메이션 컨트롤러 설정
    _blinkController = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 800),
    )..repeat(reverse: true);
    _remoteConnectedWorker = ever<String>(
      stateGlobal.remoteConnectedPeerId,
      _handleRemoteConnectionCompleted,
    );

    // 초기 로딩 시 상담사 목록 및 디바이스 목록 조회
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _initializeLoggedInData();
    });
  }

  void _initializeLoggedInData() {
    if (!mounted || !gFFI.userModel.isLogin || _autoRefreshTimer != null) {
      return;
    }
    _restoreRemoteSessionCache();
    _fetchCounselors(showLoading: !widget.useNumberManagementDesign);
    if (!widget.useNumberManagementDesign) {
      _fetchDevices();
    }
    _searchCertNo();
    _startAutoRefresh();
  }

  String get _remoteSessionCacheScope {
    final userPkid = gFFI.userModel.userPkid.value.trim();
    final username = gFFI.userModel.userName.value.trim();
    final rawScope = userPkid.isNotEmpty ? userPkid : username;
    return rawScope.replaceAll(RegExp(r'[^a-zA-Z0-9_-]'), '_');
  }

  String _scopedLocalOptionKey(String prefix) {
    final scope = _remoteSessionCacheScope;
    return scope.isEmpty ? prefix : '$prefix-$scope';
  }

  void _restoreRemoteSessionCache() {
    final scope = _remoteSessionCacheScope;
    if (scope.isEmpty || scope == _restoredSessionCacheScope) return;

    final cachedCertCode = bind
        .mainGetLocalOption(
          key: _scopedLocalOptionKey(_kLastCertCodeOptionPrefix),
        )
        .trim();
    final cachedStoredAtRaw = bind
        .mainGetLocalOption(
          key: _scopedLocalOptionKey(_kLastCertStoredAtOptionPrefix),
        )
        .trim();
    final cachedStoredAt = DateTime.tryParse(cachedStoredAtRaw)?.toUtc();
    final cacheAge = cachedStoredAt == null
        ? null
        : DateTime.now().toUtc().difference(cachedStoredAt);
    final cacheIsFresh = cachedCertCode.isNotEmpty &&
        cachedStoredAt != null &&
        cacheAge != null &&
        !cacheAge.isNegative &&
        cacheAge < _kCertDisplayLifetime;
    final cachedRemoteId = bind
        .mainGetLocalOption(
          key: _scopedLocalOptionKey(_kLastRemoteIdOptionPrefix),
        )
        .replaceAll(' ', '');
    _restoredSessionCacheScope = scope;
    setState(() {
      _certCode = cacheIsFresh ? cachedCertCode : '';
      _expiredCertCode = '';
      _certReadinessStage = cacheIsFresh ? 'issued' : 'waiting';
      _certReadinessProgress = 0;
      _certReadinessMessage =
          cacheIsFresh ? '피원격자의 프로그램 실행을 기다리는 중입니다.' : '인증번호 생성을 기다리는 중입니다.';
      _certReadinessRemoteId = '';
      _lastDirectRemoteId = cachedRemoteId;
      _showReconnectButton = false;
    });
    if (cacheIsFresh) {
      _scheduleCertDisplayExpiry(cachedStoredAt);
      _startCertStatusRefresh();
      unawaited(_refreshReconnectTargetFromLastRemoteId());
    } else if (cachedCertCode.isNotEmpty || cachedStoredAtRaw.isNotEmpty) {
      _persistLastCertCode('');
    }
  }

  void _persistLastCertCode(String certCode, {DateTime? storedAt}) {
    unawaited(bind.mainSetLocalOption(
      key: _scopedLocalOptionKey(_kLastCertCodeOptionPrefix),
      value: certCode,
    ));
    unawaited(bind.mainSetLocalOption(
      key: _scopedLocalOptionKey(_kLastCertStoredAtOptionPrefix),
      value: certCode.isEmpty
          ? ''
          : (storedAt ?? DateTime.now().toUtc()).toIso8601String(),
    ));
  }

  void _scheduleCertDisplayExpiry(DateTime storedAt) {
    _certDisplayExpiryTimer?.cancel();
    final elapsed = DateTime.now().toUtc().difference(storedAt.toUtc());
    final remainingMilliseconds =
        _kCertDisplayLifetime.inMilliseconds - elapsed.inMilliseconds;
    if (remainingMilliseconds <= 0) {
      _clearDisplayedCertCode(markExpired: true);
      return;
    }
    _certDisplayExpiryTimer = Timer(
      Duration(milliseconds: remainingMilliseconds),
      () => _clearDisplayedCertCode(markExpired: true),
    );
  }

  bool get _needsFastCertStatusRefresh =>
      _certCode.isNotEmpty &&
      _certReadinessStage != 'ready' &&
      _certReadinessStage != 'connecting';

  void _startCertStatusRefresh() {
    if (!_needsFastCertStatusRefresh || _certStatusRefreshTimer != null) {
      return;
    }
    _certStatusRefreshTimer = Timer.periodic(const Duration(seconds: 1), (_) {
      if (!mounted || !_needsFastCertStatusRefresh) {
        _stopCertStatusRefresh();
        return;
      }
      unawaited(_searchCertNo());
    });
  }

  void _stopCertStatusRefresh() {
    _certStatusRefreshTimer?.cancel();
    _certStatusRefreshTimer = null;
  }

  void _resetCertReadinessState() {
    _certReadinessStage = 'waiting';
    _certReadinessProgress = 0;
    _certReadinessMessage = '인증번호 생성을 기다리는 중입니다.';
    _certReadinessRemoteId = '';
  }

  void _handleRemoteConnectionCompleted(String peerId) {
    final connectedPeerId = peerId.replaceAll(' ', '').trim();
    final expectedPeerId = _certReadinessRemoteId.replaceAll(' ', '').trim();
    if (!mounted ||
        _certReadinessStage != 'connecting' ||
        connectedPeerId.isEmpty ||
        connectedPeerId != expectedPeerId) {
      return;
    }

    setState(() {
      _certReadinessStage = 'connected';
      _certReadinessProgress = 100;
      _certReadinessMessage = '원격 연결에 성공했습니다.';
    });
  }

  void _clearDisplayedCertCode({bool markExpired = false}) {
    _stopCertStatusRefresh();
    _certDisplayExpiryTimer?.cancel();
    _certDisplayExpiryTimer = null;
    _expiredCertCode = markExpired ? _certCode : '';
    if (mounted) {
      setState(() {
        _certCode = '';
        _resetCertReadinessState();
      });
    } else {
      _certCode = '';
      _resetCertReadinessState();
    }
    _persistLastCertCode('');
  }

  void _rememberDirectRemoteId(String remoteId) {
    final cleanId = remoteId.replaceAll(' ', '');
    if (cleanId.isEmpty || cleanId == _lastDirectRemoteId) return;

    if (mounted) {
      setState(() {
        _lastDirectRemoteId = cleanId;
      });
    } else {
      _lastDirectRemoteId = cleanId;
    }
    unawaited(bind.mainSetLocalOption(
      key: _scopedLocalOptionKey(_kLastRemoteIdOptionPrefix),
      value: cleanId,
    ));
  }

  Future<void> _refreshReconnectTargetFromLastRemoteId({
    bool force = false,
  }) async {
    if (!mounted || _lastDirectRemoteId.isNotEmpty) return;
    if (!force && _certCode.isEmpty) return;

    try {
      final lastRemoteId =
          (await bind.mainGetLastRemoteId()).replaceAll(' ', '');
      if (!mounted || lastRemoteId.isEmpty) return;
      final localId = gFFI.serverModel.serverId.text.replaceAll(' ', '');
      if (lastRemoteId == localId) return;
      _rememberDirectRemoteId(lastRemoteId);
    } catch (e) {
      debugPrint('Direct Remote: Failed to read last remote ID: $e');
    }
  }

  Future<void> _reconnectLastRemote() async {
    if (_lastDirectRemoteId.isEmpty) {
      await _refreshReconnectTargetFromLastRemoteId(force: true);
    }
    if (!mounted) return;
    if (_lastDirectRemoteId.isEmpty) {
      showToast('재연결할 원격 ID를 찾을 수 없습니다');
      return;
    }
    _connectToDirectRemote(_lastDirectRemoteId, automatically: false);
  }

  // 자동 새로고침 시작 (5초마다, 창 포커스와 무관하게 실행)
  void _startAutoRefresh() {
    _autoRefreshTimer?.cancel();
    _autoRefreshTimer = Timer.periodic(const Duration(seconds: 5), (_) {
      if (mounted && gFFI.userModel.isLogin) {
        _fetchCounselors();
        if (!widget.useNumberManagementDesign) {
          _fetchDevices();
        }
        _searchCertNo(); // 인증번호 조회
        _refreshReconnectTargetFromLastRemoteId();
      }
    });
  }

  // 앱 상태 변경 감지
  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    final wasFocused = _isAppFocused;
    _isAppFocused = state == AppLifecycleState.resumed;

    // 포커스 복귀 시 즉시 새로고침
    if (!wasFocused && _isAppFocused && mounted && gFFI.userModel.isLogin) {
      _fetchCounselors();
      if (!widget.useNumberManagementDesign) {
        _fetchDevices();
      }
      _searchCertNo(); // 인증번호 조회
    }
  }

  // 401 응답 처리 (토큰 무효화 - 비밀번호 변경 등)
  Future<void> _handleUnauthorized() async {
    debugPrint('CustomRemote: 401 Unauthorized - Token invalidated');

    // 자동 새로고침 중지
    _autoRefreshTimer?.cancel();
    _autoRefreshTimer = null;
    _stopCertStatusRefresh();
    _directAutoConnectTimer?.cancel();
    _directAutoConnectTimer = null;
    _certDisplayExpiryTimer?.cancel();
    _certDisplayExpiryTimer = null;

    // 사용자 로그아웃 처리
    await gFFI.userModel.reset(resetOther: true);

    // 사용자에게 알림
    if (mounted) {
      showToast('비밀번호가 변경되어 다시 로그인해주세요');

      // 로그인 다이얼로그 표시
      Future.delayed(const Duration(milliseconds: 500), () {
        if (mounted) {
          loginDialog();
        }
      });
    }
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this); // 앱 상태 감시 해제
    _autoRefreshTimer?.cancel();
    _certStatusRefreshTimer?.cancel();
    _directAutoConnectTimer?.cancel();
    _certDisplayExpiryTimer?.cancel();
    _remoteConnectedWorker?.dispose();
    _blinkController.dispose();
    super.dispose();
  }

  // 상담사 목록 조회
  Future<void> _fetchCounselors({bool showLoading = false}) async {
    if (_isFetching) return;

    // 초기 로딩 시에만 로딩 인디케이터 표시 (새로고침 시 깜빡임 방지)
    if (showLoading || _counselors.isEmpty) {
      setState(() {
        _isFetching = true;
      });
    }

    try {
      final username = gFFI.userModel.userName.value;
      final token = bind.mainGetLocalOption(key: 'access_token');
      final url = 'https://787.kr/api/$username/agents';

      debugPrint('Fetch Agents URL: $url');

      final response = await http.get(
        Uri.parse(url),
        headers: {
          'Content-Type': 'application/json',
          'Authorization': 'Bearer $token',
        },
      ).timeout(const Duration(seconds: 10));

      debugPrint(
          'Fetch Agents Response: ${response.statusCode} - ${response.body}');

      // 401 응답 처리 (토큰 무효화)
      if (response.statusCode == 401) {
        await _handleUnauthorized();
        return;
      }

      if (response.statusCode == 200) {
        final responseData = jsonDecode(response.body);
        if (responseData is Map && responseData['code'] == 1) {
          // 'agents' 또는 'data' 필드 지원
          final List<dynamic> agentList =
              responseData['agents'] ?? responseData['data'] ?? [];
          final newCounselors = agentList
              .map((e) =>
                  e is Map<String, dynamic> ? e : {'agent_name': e.toString()})
              .toList();

          // 이전 목록과 비교하여 새로 온라인이 된 상담사 찾기
          for (var newAgent in newCounselors) {
            final String name = _getCounselorName(newAgent);
            final String mdeskId = _getMdeskId(newAgent);

            if (mdeskId.isNotEmpty) {
              // 이전 목록에 없었거나, mdesk_id가 비어있었다면 새로 접속한 것
              bool wasOnline = _counselors.any((oldAgent) =>
                  _getAgentNum(oldAgent) == _getAgentNum(newAgent) &&
                  _getMdeskId(oldAgent).isNotEmpty);

              if (!wasOnline && _counselors.isNotEmpty) {
                // 접속 알림 표시 (짙은 녹색)
                showToast('$name님이 접속하셨습니다!');
              }
            }
          }

          final readyDirectRemoteId = _findReadyDirectRemoteId(newCounselors);
          setState(() {
            _counselors = newCounselors;
            if (_certCode.isNotEmpty && readyDirectRemoteId.isNotEmpty) {
              _certReadinessStage = 'ready';
              _certReadinessProgress = 85;
              _certReadinessMessage = '원격 연결 준비가 완료되었습니다.';
              _certReadinessRemoteId = readyDirectRemoteId;
            }
          });
          if (readyDirectRemoteId.isNotEmpty) {
            _rememberDirectRemoteId(readyDirectRemoteId);
            _stopCertStatusRefresh();
          }
          _scheduleDirectRemoteAutoConnect(newCounselors);
        }
      }
    } catch (e) {
      debugPrint('Fetch Agents Error: $e');
    } finally {
      if (_isFetching) {
        setState(() {
          _isFetching = false;
        });
      }
    }
  }

  // 디바이스 목록 조회
  Future<void> _fetchDevices() async {
    try {
      final userPkid = gFFI.userModel.userPkid.value;
      final token = bind.mainGetLocalOption(key: 'access_token');

      if (userPkid.isEmpty) {
        debugPrint('Fetch Devices: userPkid is empty, skipping');
        return;
      }

      final apiServer = await bind.mainGetApiServer();
      final url = '$apiServer/api/device/list?user_pkid=$userPkid';

      debugPrint('Fetch Devices URL: $url');

      final response = await http.get(
        Uri.parse(url),
        headers: {
          'Content-Type': 'application/json',
          'Authorization': 'Bearer $token',
        },
      ).timeout(const Duration(seconds: 10));

      debugPrint(
          'Fetch Devices Response: ${response.statusCode} - ${response.body}');

      // 401 응답 처리 (토큰 무효화)
      if (response.statusCode == 401) {
        await _handleUnauthorized();
        return;
      }

      if (response.statusCode == 200) {
        final responseData = jsonDecode(response.body);
        if (responseData is Map && responseData['code'] == 1) {
          final List<dynamic> deviceList = responseData['data'] ?? [];
          setState(() {
            _devices = deviceList
                .map((e) => e is Map
                    ? Map<String, dynamic>.from(e)
                    : <String, dynamic>{})
                .toList();
          });
          debugPrint('Fetch Devices: ${_devices.length} devices loaded');
        }
      }
    } catch (e) {
      debugPrint('Fetch Devices Error: $e');
    }
  }

  // 특정 agent_id의 디바이스 목록 가져오기
  List<Map<String, dynamic>> _getDevicesForAgent(int agentNum) {
    return _devices.where((device) {
      final deviceAgentId = device['agent_id']?.toString() ?? '';
      return deviceAgentId == agentNum.toString();
    }).toList();
  }

  // 상담사 추가
  Future<void> _addCounselor() async {
    setState(() {
      _isLoading = true;
      _message = '';
    });

    try {
      final username = gFFI.userModel.userName.value;
      final token = bind.mainGetLocalOption(key: 'access_token');
      final url = 'https://787.kr/api/$username/addnum';

      debugPrint('AddNum Request URL: $url');

      final response = await http.get(
        Uri.parse(url),
        headers: {
          'Content-Type': 'application/json',
          'Authorization': 'Bearer $token',
        },
      ).timeout(const Duration(seconds: 10));

      debugPrint('AddNum Response: ${response.statusCode} - ${response.body}');

      // 401 응답 처리 (토큰 무효화)
      if (response.statusCode == 401) {
        await _handleUnauthorized();
        return;
      }

      if (response.statusCode == 200) {
        setState(() {
          _message = '상담사 추가 완료!';
        });
        // 추가 후 목록 새로고침
        await _fetchCounselors();
      } else {
        setState(() {
          _message = '오류: ${response.statusCode}';
        });
      }
    } catch (e) {
      debugPrint('AddNum Error: $e');
      setState(() {
        _message = '네트워크 오류';
      });
    } finally {
      setState(() {
        _isLoading = false;
      });
    }
  }

  // 인증번호 생성 API 호출
  Future<void> _generateCertNo() async {
    setState(() {
      _isCertLoading = true;
      _message = '';
    });

    try {
      final username = gFFI.userModel.userName.value;
      final userPkid = gFFI.userModel.userPkid.value; // user_pk_id 추가
      final mdeskId = gFFI.serverModel.serverId.text.replaceAll(' ', '');
      final token = bind.mainGetLocalOption(key: 'access_token');
      final url = 'https://admin.787.kr/api/certno/generate';

      final body = jsonEncode({
        'customer_id': username,
        'user_pk_id': userPkid, // user_pk_id 전달 (서버에서 인증번호 prefix로 사용)
        'mdesk_id': mdeskId,
      });

      debugPrint('CertNo Generate Request URL: $url');
      debugPrint('CertNo Generate Request Body: $body');

      final response = await http
          .post(
            Uri.parse(url),
            headers: {
              'Content-Type': 'application/json',
              if (token.isNotEmpty) 'Authorization': 'Bearer $token',
            },
            body: body,
          )
          .timeout(const Duration(seconds: 10));

      debugPrint(
          'CertNo Generate Response: ${response.statusCode} - ${response.body}');

      // 401 응답 처리 (토큰 무효화)
      if (response.statusCode == 401) {
        await _handleUnauthorized();
        return;
      }

      if (response.statusCode == 200) {
        final data = jsonDecode(response.body);
        if (data['success'] == true) {
          final generatedCertCode = data['cert_code']?.toString() ?? '';
          final storedAt = DateTime.now().toUtc();
          setState(() {
            _certCode = generatedCertCode;
            _expiredCertCode = '';
            _certReadinessStage = 'issued';
            _certReadinessProgress = 0;
            _certReadinessMessage = '피원격자의 프로그램 실행을 기다리는 중입니다.';
            _certReadinessRemoteId = '';
            _showReconnectButton = false;
            _message = '인증번호 생성 완료!';
          });
          _persistLastCertCode(generatedCertCode, storedAt: storedAt);
          if (generatedCertCode.isNotEmpty) {
            _scheduleCertDisplayExpiry(storedAt);
            _startCertStatusRefresh();
          }
          showToast('인증번호: ${_formatCertCode(_certCode)}');
        } else {
          setState(() {
            _message = data['message'] ?? '인증번호 생성 실패';
          });
        }
      } else {
        setState(() {
          _message = '오류: ${response.statusCode}';
        });
      }
    } catch (e) {
      debugPrint('CertNo Generate Error: $e');
      setState(() {
        _message = '네트워크 오류';
      });
    } finally {
      setState(() {
        _isCertLoading = false;
      });
    }
  }

  // 인증번호 취소 API 호출
  Future<void> _cancelCertNo() async {
    if (_certCode.isEmpty) return;

    final certCodeToCancel = _certCode;

    // 먼저 UI와 로컬 캐시에서 즉시 제거
    _clearDisplayedCertCode();

    try {
      final username = gFFI.userModel.userName.value;
      final userPkid = gFFI.userModel.userPkid.value;
      final mdeskId = gFFI.serverModel.serverId.text.replaceAll(' ', '');
      final token = bind.mainGetLocalOption(key: 'access_token');
      final url = 'https://admin.787.kr/api/certno/cancel';

      final body = jsonEncode({
        'customer_id': username,
        'user_pk_id': userPkid,
        'mdesk_id': mdeskId,
        'cert_code': certCodeToCancel,
      });

      debugPrint('CertNo Cancel Request URL: $url');
      debugPrint('CertNo Cancel Request Body: $body');

      final response = await http
          .post(
            Uri.parse(url),
            headers: {
              'Content-Type': 'application/json',
              if (token.isNotEmpty) 'Authorization': 'Bearer $token',
            },
            body: body,
          )
          .timeout(const Duration(seconds: 10));

      debugPrint(
          'CertNo Cancel Response: ${response.statusCode} - ${response.body}');

      final data = jsonDecode(response.body);

      switch (response.statusCode) {
        case 200:
          if (data['success'] == true) {
            showToast('인증번호가 취소되었습니다');
          }
          break;
        case 400:
          // MISSING_CUSTOMER_ID, MISSING_MDESK_ID, MISSING_CERT_CODE, CERT_MISMATCH
          final error = data['error'] ?? '';
          if (error == 'CERT_MISMATCH') {
            showToast('인증번호가 일치하지 않습니다');
          } else {
            debugPrint('CertNo Cancel: Missing parameter - $error');
          }
          break;
        case 404:
          // CERT_NOT_FOUND - 이미 취소됨/만료됨
          debugPrint('CertNo Cancel: 취소할 인증번호 없음 (이미 취소되었거나 만료됨)');
          break;
        case 405:
          debugPrint('CertNo Cancel: Method not allowed');
          break;
        default:
          debugPrint('CertNo Cancel: Unexpected status ${response.statusCode}');
      }
    } catch (e) {
      debugPrint('CertNo Cancel Error: $e');
    }
  }

  // 인증번호 조회 API 호출
  Future<void> _searchCertNo() async {
    if (_isSearchingCertStatus) return;
    _isSearchingCertStatus = true;
    try {
      final username = gFFI.userModel.userName.value;
      final mdeskId = gFFI.serverModel.serverId.text.replaceAll(' ', '');
      final token = bind.mainGetLocalOption(key: 'access_token');

      if (username.isEmpty || mdeskId.isEmpty || mdeskId.contains('...')) {
        return;
      }

      final url = 'https://admin.787.kr/api/certno/search';
      final body = jsonEncode({
        'customer_id': username,
        'mdesk_id': mdeskId,
      });

      debugPrint('CertNo Search Request URL: $url');
      debugPrint('CertNo Search Request Body: $body');

      final response = await http
          .post(
            Uri.parse(url),
            headers: {
              'Content-Type': 'application/json',
              if (token.isNotEmpty) 'Authorization': 'Bearer $token',
            },
            body: body,
          )
          .timeout(const Duration(seconds: 10));

      debugPrint(
          'CertNo Search Response: ${response.statusCode} - ${response.body}');

      // 401 응답 처리 (토큰 무효화)
      if (response.statusCode == 401) {
        await _handleUnauthorized();
        return;
      }

      if (response.statusCode == 200) {
        final data = jsonDecode(response.body);
        if (data['success'] == true) {
          if (data['exists'] == true) {
            final newCertCode = data['cert_code']?.toString() ?? '';
            final stage = data['stage']?.toString().trim() ?? '';
            final progress =
                int.tryParse(data['progress']?.toString() ?? '') ?? 0;
            final progressMessage =
                data['progress_message']?.toString().trim() ?? '';
            final remoteId =
                data['remote_mdesk_id']?.toString().replaceAll(' ', '') ?? '';
            final wasReady = _certReadinessStage == 'ready';
            if (newCertCode.isNotEmpty &&
                newCertCode != _certCode &&
                newCertCode != _expiredCertCode) {
              final storedAt = DateTime.now().toUtc();
              setState(() {
                _certCode = newCertCode;
              });
              _persistLastCertCode(newCertCode, storedAt: storedAt);
              _scheduleCertDisplayExpiry(storedAt);
            }
            if (mounted && stage.isNotEmpty) {
              setState(() {
                _certReadinessStage = stage;
                _certReadinessProgress = progress.clamp(0, 100).toInt();
                _certReadinessMessage = progressMessage.isNotEmpty
                    ? progressMessage
                    : _defaultCertReadinessMessage(stage);
                _certReadinessRemoteId = remoteId;
              });
              if (remoteId.isNotEmpty) {
                _rememberDirectRemoteId(remoteId);
              }
              if (stage == 'ready') {
                _stopCertStatusRefresh();
                if (!wasReady) {
                  unawaited(_fetchCounselors());
                }
              } else {
                _startCertStatusRefresh();
              }
            }
          } else {
            // 피원격자가 인증번호를 사용하면 서버에서는 즉시 사라질 수 있다.
            // 화면의 번호는 생성·표시 시점부터 5분 동안 유지하고 타이머가 지운다.
            if (_certCode.isEmpty && _expiredCertCode.isNotEmpty) {
              _expiredCertCode = '';
            }
          }
        }
      }
    } catch (e) {
      debugPrint('CertNo Search Error: $e');
    } finally {
      _isSearchingCertStatus = false;
    }
  }

  // 상담사 삭제
  String _defaultCertReadinessMessage(String stage) {
    switch (stage) {
      case 'issued':
        return '피원격자의 프로그램 실행을 기다리는 중입니다.';
      case 'verified':
        return '피원격자가 인증번호를 확인했습니다.';
      case 'preparing':
        return '원격 서비스를 준비하는 중입니다.';
      case 'service_ready':
        return '원격 제어 기능을 시작하는 중입니다.';
      case 'ready':
        return '원격 연결 준비가 완료되었습니다.';
      case 'connecting':
        return '릴레이 서버로 연결하는 중입니다.';
      case 'connected':
        return '원격 연결에 성공했습니다.';
      default:
        return '원격 연결 상태를 확인하는 중입니다.';
    }
  }

  Future<void> _deleteCounselor(int agentNum) async {
    setState(() {
      _isLoading = true;
      _message = '';
    });

    try {
      final username = gFFI.userModel.userName.value;
      final token = bind.mainGetLocalOption(key: 'access_token');
      final url = 'https://787.kr/api/$username/delnum/$agentNum';

      debugPrint('DeleteNum Request URL: $url');

      final response = await http.delete(
        Uri.parse(url),
        headers: {
          'Content-Type': 'application/json',
          'Authorization': 'Bearer $token',
        },
      ).timeout(const Duration(seconds: 10));

      debugPrint(
          'DeleteNum Response: ${response.statusCode} - ${response.body}');

      // 401 응답 처리 (토큰 무효화)
      if (response.statusCode == 401) {
        await _handleUnauthorized();
        return;
      }

      if (response.statusCode == 200 || response.statusCode == 404) {
        // 200: 삭제 성공, 404: 이미 삭제되었거나 존재하지 않음 (조용히 처리)
        if (response.statusCode == 200) {
          setState(() {
            _message = '상담사 삭제 완료!';
          });
        }
        // 삭제 후 목록 새로고침
        await _fetchCounselors();
      } else {
        setState(() {
          _message = '삭제 오류: ${response.statusCode}';
        });
      }
    } catch (e) {
      debugPrint('DeleteNum Error: $e');
      setState(() {
        _message = '네트워크 오류';
      });
    } finally {
      setState(() {
        _isLoading = false;
      });
    }
  }

  String _getCounselorName(Map<String, dynamic> agent) {
    // agent_name 필드 사용
    return agent['agent_name']?.toString() ?? '상담사';
  }

  int _getAgentNum(Map<String, dynamic> agent) {
    return int.tryParse(agent['agent_num']?.toString() ?? '') ?? 0;
  }

  String _getMdeskId(Map<String, dynamic> agent) {
    return agent['mdesk_id']?.toString() ?? '';
  }

  String _getOwnerMdeskId(Map<String, dynamic> agent) {
    return agent['owner_mdesk_id']?.toString() ?? '';
  }

  bool _isCurrentMdeskDirectRemote(Map<String, dynamic> agent) {
    if (_getAgentNum(agent) != 0) return false;

    final remoteId = _getMdeskId(agent).replaceAll(' ', '');
    if (remoteId.isEmpty) return false;

    final ownerMdeskId = _getOwnerMdeskId(agent).replaceAll(' ', '');
    // `/api/{username}/agents`는 이미 현재 로그인 사용자 범위다.
    // 구버전 API처럼 owner_mdesk_id가 누락된 응답도 직접 원격 준비로 인정한다.
    if (ownerMdeskId.isEmpty) return true;

    final localMdeskId = gFFI.serverModel.serverId.text.replaceAll(' ', '');
    return localMdeskId.isNotEmpty && ownerMdeskId == localMdeskId;
  }

  // 인증번호 표시용 포맷: 마지막 3자리 앞에 공백 추가 (예: 3439 → "3 439", 110123 → "110 123")
  String _formatCertCode(String code) {
    if (code.length <= 3) return code;
    final prefix = code.substring(0, code.length - 3);
    final lastThree = code.substring(code.length - 3);
    return '$prefix $lastThree';
  }

  // 기기 등록 다이얼로그 표시
  Future<void> _showRegisterDeviceDialog() async {
    final remoteIdController = TextEditingController();
    final aliasController = TextEditingController();

    // 별칭은 서버에서만 관리하므로 로컬 저장/불러오기 없음

    final result = await showDialog<bool>(
      context: context,
      builder: (BuildContext context) {
        return AlertDialog(
          title: Row(
            children: [
              Icon(Icons.devices, color: Theme.of(context).colorScheme.primary),
              const SizedBox(width: 8),
              const Text('기기 등록'),
            ],
          ),
          content: SizedBox(
            width: 320,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Text(
                  '원격 기기를 등록하면 관리 대시보드에서 확인할 수 있습니다.',
                  style: TextStyle(fontSize: 13, color: Colors.grey),
                ),
                const SizedBox(height: 16),
                TextField(
                  controller: remoteIdController,
                  decoration: const InputDecoration(
                    labelText: '원격 ID',
                    hintText: '예: 143165320',
                    prefixIcon: Icon(Icons.tag),
                    border: OutlineInputBorder(),
                  ),
                  keyboardType: TextInputType.number,
                ),
                const SizedBox(height: 12),
                TextField(
                  controller: aliasController,
                  decoration: const InputDecoration(
                    labelText: '별칭 (선택)',
                    hintText: '예: 사무실 개발PC',
                    prefixIcon: Icon(Icons.label),
                    border: OutlineInputBorder(),
                  ),
                ),
              ],
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(context).pop(false),
              child: const Text('취소'),
            ),
            ElevatedButton(
              onPressed: () {
                if (remoteIdController.text.trim().isEmpty) {
                  showToast('원격 ID를 입력해주세요');
                  return;
                }
                Navigator.of(context).pop(true);
              },
              child: const Text('등록'),
            ),
          ],
        );
      },
    );

    if (result == true && remoteIdController.text.trim().isNotEmpty) {
      await _registerDevice(
        remoteIdController.text.trim().replaceAll(' ', ''),
        aliasController.text.trim(),
      );
    }
  }

  // 기기 등록 처리
  Future<void> _registerDevice(String remoteId, String alias) async {
    setState(() {
      _isLoading = true;
      _message = '';
    });

    try {
      final username = gFFI.userModel.userName.value;
      final userPkid = gFFI.userModel.userPkid.value;
      final token = bind.mainGetLocalOption(key: 'access_token');

      // 시스템 정보 수집
      String hostname = '';
      String platform = '';
      String uuid = '';
      String version = '';

      try {
        if (!isWeb) {
          hostname = Platform.localHostname;
          if (Platform.isWindows) {
            platform = 'Windows';
          } else if (Platform.isMacOS) {
            platform = 'macOS';
          } else if (Platform.isLinux) {
            platform = 'Linux';
          } else if (Platform.isAndroid) {
            platform = 'Android';
          } else if (Platform.isIOS) {
            platform = 'iOS';
          }
        } else {
          platform = 'Web';
        }

        uuid = await bind.mainGetUuid();
        version = await bind.mainGetVersion();
      } catch (e) {
        debugPrint('Error getting system info: $e');
      }

      // agent_id 가져오기 (있는 경우)
      String? agentId;
      try {
        // agent_id는 사용자 설정이나 다른 곳에서 가져올 수 있음
        // 현재는 빈 값으로 처리
        agentId = null;
      } catch (e) {
        debugPrint('Error getting agent_id: $e');
      }

      debugPrint('Register Device - alias: $alias');

      final response = await deviceRegisterService.registerDevice(
        apiServer: 'https://admin.787.kr',
        accessToken: token,
        userId: username,
        userPkid: userPkid,
        remoteId: remoteId,
        alias: alias,
        hostname: hostname,
        platform: platform,
        uuid: uuid,
        version: version,
        agentId: agentId,
      );

      if (response.isUnauthorized) {
        await _handleUnauthorized();
        return;
      }

      if (response.success) {
        // 별칭은 서버에서만 관리 (로컬 저장하지 않음)
        setState(() {
          _message = translate('Device registered successfully');
        });
        showToast('기기가 등록되었습니다: $remoteId');
        // 등록 후 목록 새로고침 (서버에서 최신 별칭 가져옴)
        await _fetchDevices();
      } else {
        setState(() {
          _message = response.userMessage;
        });
        showToast(response.userMessage);
      }
    } catch (e) {
      debugPrint('Register Device Error: $e');
      setState(() {
        _message = '네트워크 오류';
      });
    } finally {
      setState(() {
        _isLoading = false;
      });
    }
  }

  // 기기 삭제
  Future<void> _deleteDevice(String remoteId) async {
    final confirm = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('기기 삭제'),
        content: Text('$remoteId 기기를 삭제하시겠습니까?'),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: const Text('취소'),
          ),
          ElevatedButton(
            style: ElevatedButton.styleFrom(backgroundColor: Colors.red),
            onPressed: () => Navigator.of(context).pop(true),
            child: const Text('삭제'),
          ),
        ],
      ),
    );

    if (confirm != true) return;

    setState(() {
      _isLoading = true;
      _message = '';
    });

    try {
      final userPkid = gFFI.userModel.userPkid.value;
      final token = bind.mainGetLocalOption(key: 'access_token');
      final url = 'https://admin.787.kr/api/device/unregister';

      final body = jsonEncode({
        'user_pkid': userPkid,
        'remote_id': remoteId,
      });

      debugPrint('Unregister Device URL: $url');

      final response = await http
          .post(
            Uri.parse(url),
            headers: {
              'Content-Type': 'application/json',
              'Authorization': 'Bearer $token',
            },
            body: body,
          )
          .timeout(const Duration(seconds: 10));

      debugPrint(
          'Unregister Device Response: ${response.statusCode} - ${response.body}');

      // 401 응답 처리 (토큰 무효화)
      if (response.statusCode == 401) {
        await _handleUnauthorized();
        return;
      }

      if (response.statusCode == 200) {
        setState(() {
          _message = '기기 삭제 완료';
        });
        showToast('기기가 삭제되었습니다');
        await _fetchDevices();
      } else {
        setState(() {
          _message = '삭제 오류: ${response.statusCode}';
        });
      }
    } catch (e) {
      debugPrint('Unregister Device Error: $e');
      setState(() {
        _message = '네트워크 오류';
      });
    } finally {
      setState(() {
        _isLoading = false;
      });
    }
  }

  String get _certReadinessTitle {
    switch (_certReadinessStage) {
      case 'issued':
        return '피원격자 실행 대기';
      case 'verified':
        return '인증번호 확인 완료';
      case 'preparing':
        return '원격 서비스 준비 중';
      case 'service_ready':
        return '원격 제어 시작 중';
      case 'ready':
        return '원격 준비 완료';
      case 'connecting':
        return '원격 연결 중';
      case 'connected':
        return '원격 연결 성공';
      default:
        return '원격 연결 준비';
    }
  }

  IconData get _certReadinessIcon {
    switch (_certReadinessStage) {
      case 'verified':
        return Icons.verified_user_outlined;
      case 'preparing':
        return Icons.settings_outlined;
      case 'service_ready':
        return Icons.desktop_windows_outlined;
      case 'ready':
        return Icons.check_circle_outline;
      case 'connecting':
        return Icons.sync;
      case 'connected':
        return Icons.check_circle;
      default:
        return Icons.hourglass_top_rounded;
    }
  }

  Color _certReadinessColor(BuildContext context) {
    switch (_certReadinessStage) {
      case 'verified':
        return const Color(0xFF7C3AED);
      case 'preparing':
        return const Color(0xFF2563EB);
      case 'service_ready':
        return const Color(0xFF0284C7);
      case 'ready':
        return const Color(0xFF16A34A);
      case 'connecting':
        return const Color(0xFF0D9488);
      case 'connected':
        return const Color(0xFF16A34A);
      default:
        return const Color(0xFFF97316);
    }
  }

  Widget _buildCertReadinessProgress(
    BuildContext context, {
    bool compact = false,
  }) {
    final color = _certReadinessColor(context);
    final progress = (_certReadinessProgress / 100).clamp(0.0, 1.0).toDouble();
    final remoteId = _certReadinessRemoteId;

    return Container(
      width: double.infinity,
      margin: compact ? const EdgeInsets.symmetric(horizontal: 18) : null,
      padding: EdgeInsets.symmetric(
        horizontal: compact ? 14 : 18,
        vertical: compact ? 12 : 15,
      ),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.08),
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: color.withValues(alpha: 0.25)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Container(
                width: compact ? 32 : 38,
                height: compact ? 32 : 38,
                decoration: BoxDecoration(
                  color: color.withValues(alpha: 0.14),
                  shape: BoxShape.circle,
                ),
                child: Icon(
                  _certReadinessIcon,
                  color: color,
                  size: compact ? 18 : 21,
                ),
              ),
              const SizedBox(width: 10),
              Expanded(
                child: Text(
                  _certReadinessTitle,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    fontSize: compact ? 13 : 15,
                    fontWeight: FontWeight.w700,
                    color: Theme.of(context).textTheme.titleMedium?.color,
                  ),
                ),
              ),
              Text(
                '$_certReadinessProgress%',
                style: TextStyle(
                  color: color,
                  fontSize: compact ? 12 : 14,
                  fontWeight: FontWeight.w800,
                ),
              ),
            ],
          ),
          SizedBox(height: compact ? 10 : 12),
          TweenAnimationBuilder<double>(
            tween: Tween<double>(begin: 0, end: progress),
            duration: const Duration(milliseconds: 420),
            curve: Curves.easeOutCubic,
            builder: (context, value, child) => ClipRRect(
              borderRadius: BorderRadius.circular(999),
              child: LinearProgressIndicator(
                value: value,
                minHeight: compact ? 7 : 9,
                color: color,
                backgroundColor: color.withValues(alpha: 0.14),
              ),
            ),
          ),
          SizedBox(height: compact ? 8 : 10),
          Text(
            _certReadinessMessage,
            maxLines: compact ? 1 : 2,
            overflow: TextOverflow.ellipsis,
            style: TextStyle(
              fontSize: compact ? 11 : 13,
              height: 1.35,
              color: Theme.of(context)
                  .textTheme
                  .bodyMedium
                  ?.color
                  ?.withValues(alpha: 0.72),
            ),
          ),
          if (remoteId.isNotEmpty &&
              (_certReadinessStage == 'ready' ||
                  _certReadinessStage == 'connecting' ||
                  _certReadinessStage == 'connected')) ...[
            const SizedBox(height: 5),
            Text(
              '원격 ID  ${formatID(remoteId)}',
              style: TextStyle(
                color: color,
                fontSize: compact ? 10 : 12,
                fontWeight: FontWeight.w700,
              ),
            ),
          ],
        ],
      ),
    );
  }

  Widget _buildAgentNumberManagement(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final displayNumber =
        _certCode.isEmpty ? '----' : _certCode.replaceAll(' ', '');
    final showReconnectButton = _showReconnectButton;
    final hasError = _message.isNotEmpty &&
        !_message.contains('완료') &&
        !_message.contains('성공');

    return LayoutBuilder(
      builder: (context, constraints) {
        final compactHeight = constraints.maxHeight < 500;
        final horizontalPadding = constraints.maxWidth < 520 ? 20.0 : 40.0;
        final cardWidth = (constraints.maxWidth - horizontalPadding * 2)
            .clamp(180.0, 292.0)
            .toDouble();

        return Padding(
          padding: EdgeInsets.fromLTRB(
              horizontalPadding, compactHeight ? 12 : 20, horizontalPadding, 0),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Text(
                '상담원 번호 관리',
                style: TextStyle(
                  fontSize: 28,
                  fontWeight: FontWeight.w700,
                ),
              ),
              const SizedBox(height: 6),
              Text(
                '상담원 번호로 간편하게 관리',
                style: TextStyle(
                  fontSize: 14,
                  color: Theme.of(context)
                      .textTheme
                      .bodyMedium
                      ?.color
                      ?.withValues(alpha: 0.62),
                ),
              ),
              const SizedBox(height: 12),
              Text.rich(
                TextSpan(
                  style: TextStyle(
                    fontSize: 14,
                    height: 1.45,
                    color: Theme.of(context)
                        .textTheme
                        .bodyMedium
                        ?.color
                        ?.withValues(alpha: 0.78),
                  ),
                  children: [
                    const TextSpan(text: '고객에게 '),
                    TextSpan(
                      text: '"787.kr"',
                      style: TextStyle(
                        color: Theme.of(context).colorScheme.primary,
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                    const TextSpan(
                      text: ' 사이트를 안내해 주신 후 인증번호를 불러주시면 됩니다.',
                    ),
                  ],
                ),
                softWrap: true,
              ),
              Expanded(
                child: Center(
                  child: SingleChildScrollView(
                    padding:
                        EdgeInsets.symmetric(vertical: compactHeight ? 16 : 24),
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Container(
                          width: cardWidth,
                          height: (compactHeight
                                  ? (showReconnectButton ? 264 : 205)
                                  : (showReconnectButton ? 304 : 244)) +
                              (_certCode.isNotEmpty
                                  ? (compactHeight ? 118 : 126)
                                  : 0),
                          decoration: BoxDecoration(
                            color: isDark
                                ? Theme.of(context).cardColor
                                : const Color(0xFFFFFFFF),
                            borderRadius: BorderRadius.circular(8),
                            border: Border.all(
                              color: isDark
                                  ? Colors.white.withValues(alpha: 0.08)
                                  : const Color(0xFFE9EDF5),
                            ),
                            boxShadow: [
                              BoxShadow(
                                color: Colors.black
                                    .withValues(alpha: isDark ? 0.22 : 0.09),
                                blurRadius: 18,
                                offset: const Offset(0, 8),
                              ),
                            ],
                          ),
                          child: Column(
                            mainAxisAlignment: MainAxisAlignment.center,
                            children: [
                              Container(
                                width: 48,
                                height: 48,
                                decoration: BoxDecoration(
                                  color: const Color(0xFF8B5CF6)
                                      .withValues(alpha: 0.11),
                                  shape: BoxShape.circle,
                                ),
                                child: const Icon(
                                  Icons.person_outline,
                                  size: 28,
                                  color: Color(0xFF8B5CF6),
                                ),
                              ),
                              const SizedBox(height: 18),
                              AnimatedSwitcher(
                                duration: const Duration(milliseconds: 180),
                                child: Text(
                                  displayNumber,
                                  key: ValueKey(displayNumber),
                                  maxLines: 1,
                                  style: TextStyle(
                                    fontSize: 48,
                                    fontWeight: FontWeight.w800,
                                    color: Theme.of(context)
                                        .textTheme
                                        .titleLarge
                                        ?.color,
                                  ),
                                ),
                              ),
                              if (_certCode.isNotEmpty) ...[
                                const SizedBox(height: 8),
                                Text(
                                  '사용 가능한 인증번호',
                                  style: TextStyle(
                                    color: const Color(0xFF16A34A),
                                    fontSize: 12,
                                    fontWeight: FontWeight.w600,
                                  ),
                                ),
                                const SizedBox(height: 14),
                                _buildCertReadinessProgress(
                                  context,
                                  compact: true,
                                ),
                              ],
                              if (showReconnectButton) ...[
                                const SizedBox(height: 20),
                                _buildAgentNumberReconnectButton(context),
                              ],
                            ],
                          ),
                        ),
                        SizedBox(height: compactHeight ? 26 : 52),
                        _buildAgentNumberGenerateButton(context),
                        if (hasError) ...[
                          const SizedBox(height: 12),
                          Text(
                            _message,
                            textAlign: TextAlign.center,
                            style: const TextStyle(
                              fontSize: 13,
                              color: Color(0xFFD14343),
                            ),
                          ),
                        ],
                      ],
                    ),
                  ),
                ),
              ),
            ],
          ),
        );
      },
    );
  }

  Widget _buildAgentNumberReconnectButton(BuildContext context) {
    return Container(
      width: double.infinity,
      height: 58,
      margin: const EdgeInsets.symmetric(horizontal: 18),
      decoration: BoxDecoration(
        gradient: const LinearGradient(
          colors: [Color(0xFF10B981), Color(0xFF0EA5E9)],
          begin: Alignment.centerLeft,
          end: Alignment.centerRight,
        ),
        borderRadius: BorderRadius.circular(14),
        boxShadow: [
          BoxShadow(
            color: const Color(0xFF0EA5E9).withValues(alpha: 0.32),
            blurRadius: 16,
            offset: const Offset(0, 7),
          ),
        ],
      ),
      child: Material(
        color: Colors.transparent,
        child: InkWell(
          onTap: _reconnectLastRemote,
          borderRadius: BorderRadius.circular(14),
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16),
            child: Row(
              children: [
                Container(
                  width: 36,
                  height: 36,
                  decoration: BoxDecoration(
                    color: Colors.white.withValues(alpha: 0.2),
                    shape: BoxShape.circle,
                  ),
                  child: const Icon(
                    Icons.refresh,
                    color: Colors.white,
                    size: 22,
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    mainAxisAlignment: MainAxisAlignment.center,
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      const Text(
                        '원격 재연결',
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                          color: Colors.white,
                          fontSize: 16,
                          fontWeight: FontWeight.w800,
                        ),
                      ),
                      Text(
                        _lastDirectRemoteId.isEmpty
                            ? '최근 연결 대상 확인'
                            : 'ID ${formatID(_lastDirectRemoteId)}',
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                          color: Colors.white.withValues(alpha: 0.84),
                          fontSize: 11,
                          fontWeight: FontWeight.w500,
                        ),
                      ),
                    ],
                  ),
                ),
                const Icon(
                  Icons.arrow_forward,
                  color: Colors.white,
                  size: 22,
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildAgentNumberGenerateButton(BuildContext context) {
    final disabled = _isCertLoading;
    return SizedBox(
      width: 204,
      height: 58,
      child: DecoratedBox(
        decoration: BoxDecoration(
          gradient: disabled
              ? const LinearGradient(
                  colors: [Color(0xFF9CA3AF), Color(0xFF9CA3AF)])
              : const LinearGradient(
                  colors: [Color(0xFF4F8BFF), Color(0xFF745CF6)]),
          borderRadius: BorderRadius.circular(8),
          boxShadow: disabled
              ? null
              : [
                  BoxShadow(
                    color: const Color(0xFF5B7CFA).withValues(alpha: 0.3),
                    blurRadius: 14,
                    offset: const Offset(0, 7),
                  ),
                ],
        ),
        child: Material(
          color: Colors.transparent,
          child: InkWell(
            onTap: disabled ? null : _generateCertNo,
            borderRadius: BorderRadius.circular(8),
            child: Center(
              child: disabled
                  ? const SizedBox(
                      width: 22,
                      height: 22,
                      child: CircularProgressIndicator(
                        strokeWidth: 2.4,
                        color: Colors.white,
                      ),
                    )
                  : const Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Icon(
                          Icons.add_circle,
                          size: 23,
                          color: Colors.white,
                        ),
                        SizedBox(width: 9),
                        Text(
                          '번호 생성',
                          style: TextStyle(
                            color: Colors.white,
                            fontSize: 16,
                            fontWeight: FontWeight.w600,
                          ),
                        ),
                      ],
                    ),
            ),
          ),
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Obx(() {
      // 로그인이 안 되어 있으면 로그인 버튼 표시
      if (!gFFI.userModel.isLogin) {
        return Center(
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Icon(
                Icons.settings_remote,
                size: 64,
                color: Theme.of(context).colorScheme.primary.withOpacity(0.3),
              ),
              const SizedBox(height: 16),
              Text(
                translate('Custom Remote'),
                style: TextStyle(
                  fontSize: 18,
                  fontWeight: FontWeight.bold,
                  color: Theme.of(context).textTheme.titleLarge?.color,
                ),
              ),
              const SizedBox(height: 8),
              Text(
                translate('Login to access custom remote connections'),
                style: TextStyle(
                  fontSize: 14,
                  color: Theme.of(context)
                      .textTheme
                      .bodyMedium
                      ?.color
                      ?.withOpacity(0.7),
                ),
              ),
              const SizedBox(height: 24),
              RootOverlayControl(
                size: const Size(80, 40),
                child: ElevatedButton(
                  onPressed: () async {
                    await loginDialog();
                  },
                  child: Text(translate("Login")),
                ),
              ),
            ],
          ),
        );
      }

      if (_autoRefreshTimer == null) {
        WidgetsBinding.instance.addPostFrameCallback((_) {
          _initializeLoggedInData();
        });
      }

      // 유료 사용자 체크
      if (gFFI.userModel.membershipLevel.value == 'free') {
        return Center(
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Icon(
                Icons.workspace_premium,
                size: 64,
                color: Colors.orange.withOpacity(0.5),
              ),
              const SizedBox(height: 16),
              Text(
                '유료 사용자만 사용이 가능합니다',
                style: TextStyle(
                  fontSize: 18,
                  fontWeight: FontWeight.bold,
                  color: Theme.of(context).textTheme.titleLarge?.color,
                ),
              ),
              const SizedBox(height: 8),
              Text(
                '상담사 관리 및 다이렉트 연결 기능을 사용하시려면\n멤버십을 업그레이드 해주세요.',
                textAlign: TextAlign.center,
                style: TextStyle(
                  fontSize: 14,
                  color: Theme.of(context)
                      .textTheme
                      .bodyMedium
                      ?.color
                      ?.withOpacity(0.7),
                ),
              ),
            ],
          ),
        );
      }

      if (widget.useNumberManagementDesign) {
        return _buildAgentNumberManagement(context);
      }

      // 로그인된 상태 - 상담사 관리 UI
      // agent_num == 0 인 상담사 찾기 (바로 원격 연결용)
      Map<String, dynamic>? directAgent;
      for (var agent in _counselors) {
        if (_isCurrentMdeskDirectRemote(agent) &&
            _getMdeskId(agent).isNotEmpty) {
          directAgent = agent;
          break;
        }
      }

      return Padding(
        padding: const EdgeInsets.all(16.0),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            // 인증번호 표시 (생성된 경우에만)
            if (_certCode.isNotEmpty) ...[
              Container(
                padding:
                    const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
                decoration: BoxDecoration(
                  gradient: LinearGradient(
                    colors: [
                      const Color(0xFFFF6B35),
                      const Color(0xFFFF8F65),
                    ],
                    begin: Alignment.topLeft,
                    end: Alignment.bottomRight,
                  ),
                  borderRadius: BorderRadius.circular(12),
                  boxShadow: [
                    BoxShadow(
                      color: const Color(0xFFFF6B35).withOpacity(0.3),
                      blurRadius: 8,
                      offset: const Offset(0, 4),
                    ),
                  ],
                ),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    const Icon(Icons.pin, color: Colors.white, size: 20),
                    const SizedBox(width: 8),
                    Text(
                      _formatCertCode(_certCode),
                      style: const TextStyle(
                        color: Colors.white,
                        fontSize: 24,
                        fontWeight: FontWeight.bold,
                        letterSpacing: 4,
                      ),
                    ),
                    const SizedBox(width: 12),
                    IconButton(
                      onPressed: _cancelCertNo,
                      icon: const Icon(Icons.close,
                          color: Colors.white, size: 18),
                      padding: EdgeInsets.zero,
                      constraints: const BoxConstraints(),
                      tooltip: '인증번호 취소',
                    ),
                  ],
                ),
              ),
              const SizedBox(height: 12),
              _buildCertReadinessProgress(context),
              const SizedBox(height: 12),
            ],
            // agent_num == 0인 상담사이 있으면 바로 원격 버튼 표시
            if (directAgent != null) ...[
              _buildDirectRemoteButton(directAgent),
              const SizedBox(height: 12),
            ],
            // 상담사 목록 (가로로 쌓임) - 상단
            Expanded(
              child: _isFetching
                  ? const Center(child: CircularProgressIndicator())
                  : _counselors.isEmpty
                      ? Center(
                          child: Column(
                            mainAxisAlignment: MainAxisAlignment.center,
                            children: [
                              TextButton.icon(
                                onPressed: _fetchCounselors,
                                icon: const Icon(Icons.refresh, size: 16),
                                label: const Text('새로고침'),
                              ),
                            ],
                          ),
                        )
                      : RefreshIndicator(
                          onRefresh: _fetchCounselors,
                          child: SingleChildScrollView(
                            physics: const AlwaysScrollableScrollPhysics(),
                            child: Wrap(
                              spacing: 8,
                              runSpacing: 8,
                              children: _counselors
                                  .where((agent) => _getAgentNum(agent) != 0)
                                  .map((agent) {
                                final num = _getAgentNum(agent);
                                final name = _getCounselorName(agent);
                                final mdeskId = _getMdeskId(agent);
                                final bool isOnline = mdeskId.isNotEmpty;

                                return InkWell(
                                  onTap: () {
                                    if (mdeskId.isNotEmpty) {
                                      final mdeskIdClean =
                                          mdeskId.replaceAll(' ', '');
                                      try {
                                        // 1. IDTextEditingController 찾아서 업데이트
                                        if (Get.isRegistered<
                                            IDTextEditingController>()) {
                                          Get.find<IDTextEditingController>()
                                              .id = mdeskIdClean;
                                        }

                                        // 2. 일반 TextEditingController 찾아서 업데이트 (화면 표시용)
                                        // ConnectionPage에서 Get.put<TextEditingController>(_idEditingController)로 등록됨
                                        if (Get.isRegistered<
                                            TextEditingController>()) {
                                          final controller =
                                              Get.find<TextEditingController>();
                                          controller.text =
                                              formatID(mdeskIdClean);

                                          // 커서를 끝으로 이동
                                          controller.selection =
                                              TextSelection.fromPosition(
                                            TextPosition(
                                                offset: controller.text.length),
                                          );
                                        }

                                        showToast('ID가 입력되었습니다: $mdeskIdClean');

                                        // 3. 즉시 연결 실행
                                        debugPrint(
                                            'CustomRemote: Starting direct connection to $mdeskIdClean');
                                        connect(context, mdeskIdClean);
                                      } catch (e) {
                                        debugPrint('Error filling ID: $e');
                                      }
                                    } else {
                                      showToast('해당 상담사은 오프라인입니다.');
                                    }
                                  },
                                  borderRadius: BorderRadius.circular(16),
                                  child: Chip(
                                    avatar: Stack(
                                      children: [
                                        CircleAvatar(
                                          backgroundColor: Theme.of(context)
                                              .colorScheme
                                              .primary,
                                          child: Text(
                                            '$num',
                                            style: const TextStyle(
                                                color: Colors.white,
                                                fontSize: 12),
                                          ),
                                        ),
                                        if (isOnline)
                                          Positioned(
                                            right: -2,
                                            bottom: -2,
                                            child: FadeTransition(
                                              opacity: _blinkController,
                                              child: Container(
                                                width: 14,
                                                height: 14,
                                                decoration: BoxDecoration(
                                                  color:
                                                      const Color(0xFF00E676),
                                                  shape: BoxShape.circle,
                                                  border: Border.all(
                                                      color: Colors.white,
                                                      width: 2),
                                                  boxShadow: [
                                                    BoxShadow(
                                                      color: const Color(
                                                              0xFF00E676)
                                                          .withOpacity(0.9),
                                                      blurRadius: 12,
                                                      spreadRadius: 3,
                                                    )
                                                  ],
                                                ),
                                              ),
                                            ),
                                          ),
                                      ],
                                    ),
                                    label: Text(name),
                                    deleteIcon:
                                        const Icon(Icons.close, size: 16),
                                    onDeleted: _isLoading
                                        ? null
                                        : () => _deleteCounselor(num),
                                  ),
                                );
                              }).toList(),
                            ),
                          ),
                        ),
            ),

            const Divider(),

            // 디바이스 목록 (agent_id별로 그룹화하여 표시)
            if (_devices.isNotEmpty) ...[
              const SizedBox(height: 8),
              SizedBox(
                height: 60,
                child: ListView(
                  scrollDirection: Axis.horizontal,
                  children: _devices.where((device) {
                    final agentId = device['agent_id']?.toString() ?? '';
                    return agentId.isNotEmpty && agentId != '0';
                  }).map((device) {
                    final remoteId = device['remote_id']?.toString() ?? '';
                    final agentId = device['agent_id']?.toString() ?? '';
                    final hostname = device['hostname']?.toString() ?? '';
                    final isActive = device['is_active'] == true;

                    final deviceAlias = device['alias']?.toString() ?? '';

                    return Container(
                      margin: const EdgeInsets.only(right: 8),
                      padding: const EdgeInsets.symmetric(
                          horizontal: 10, vertical: 6),
                      decoration: BoxDecoration(
                        color: isActive
                            ? const Color(0xFF1B5E20).withOpacity(0.15)
                            : Theme.of(context).cardColor,
                        borderRadius: BorderRadius.circular(8),
                        border: Border.all(
                          color: isActive
                              ? const Color(0xFF4CAF50)
                              : Theme.of(context).dividerColor,
                        ),
                      ),
                      child: InkWell(
                        onTap: () {
                          if (remoteId.isNotEmpty) {
                            connect(context, remoteId.replaceAll(' ', ''));
                          }
                        },
                        onLongPress: () => _deleteDevice(remoteId),
                        child: Column(
                          mainAxisSize: MainAxisSize.min,
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Row(
                              mainAxisSize: MainAxisSize.min,
                              children: [
                                Container(
                                  padding: const EdgeInsets.symmetric(
                                      horizontal: 4, vertical: 1),
                                  decoration: BoxDecoration(
                                    color:
                                        Theme.of(context).colorScheme.primary,
                                    borderRadius: BorderRadius.circular(4),
                                  ),
                                  child: Text(
                                    deviceAlias.isNotEmpty
                                        ? deviceAlias
                                        : (agentId.isNotEmpty
                                            ? '상담사$agentId'
                                            : '-'),
                                    style: const TextStyle(
                                      color: Colors.white,
                                      fontSize: 9,
                                      fontWeight: FontWeight.bold,
                                    ),
                                  ),
                                ),
                                const SizedBox(width: 6),
                                if (isActive)
                                  Container(
                                    width: 6,
                                    height: 6,
                                    decoration: const BoxDecoration(
                                      color: Color(0xFF4CAF50),
                                      shape: BoxShape.circle,
                                    ),
                                  ),
                              ],
                            ),
                            const SizedBox(height: 4),
                            Text(
                              remoteId,
                              style: TextStyle(
                                fontSize: 12,
                                fontWeight: FontWeight.w600,
                                color: Theme.of(context)
                                    .textTheme
                                    .bodyLarge
                                    ?.color,
                              ),
                            ),
                            if (hostname.isNotEmpty)
                              Text(
                                hostname,
                                style: TextStyle(
                                  fontSize: 9,
                                  color: Theme.of(context)
                                      .textTheme
                                      .bodySmall
                                      ?.color,
                                ),
                                overflow: TextOverflow.ellipsis,
                              ),
                          ],
                        ),
                      ),
                    );
                  }).toList(),
                ),
              ),
              const SizedBox(height: 8),
            ],

            // 하단: (옵션) 상담사 추가 + 인증번호원격 + 새로고침 + 메시지
            Row(
              children: [
                if (_kShowAddCounselorButton) ...[
                  Expanded(
                    flex: 1,
                    child: ElevatedButton.icon(
                      onPressed: _isLoading ? null : _addCounselor,
                      icon: _isLoading
                          ? const SizedBox(
                              width: 14,
                              height: 14,
                              child: CircularProgressIndicator(strokeWidth: 2),
                            )
                          : const Icon(Icons.person_add, size: 18),
                      label: Text(
                        _isLoading ? '추가 중...' : '상담사 추가',
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(fontSize: 12),
                      ),
                      style: ElevatedButton.styleFrom(
                        padding: const EdgeInsets.symmetric(
                            horizontal: 6, vertical: 8),
                      ),
                    ),
                  ),
                  const SizedBox(width: 6),
                ],
                Expanded(
                  flex: 1,
                  child: ElevatedButton.icon(
                    onPressed: _isCertLoading ? null : _generateCertNo,
                    icon: _isCertLoading
                        ? const SizedBox(
                            width: 14,
                            height: 14,
                            child: CircularProgressIndicator(strokeWidth: 2),
                          )
                        : const Icon(Icons.pin, size: 18),
                    label: Text(
                      _isCertLoading ? '생성 중...' : '인증번호원격',
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(fontSize: 12),
                    ),
                    style: ElevatedButton.styleFrom(
                      backgroundColor: const Color(0xFFFF6B35),
                      foregroundColor: Colors.white,
                      padding: const EdgeInsets.symmetric(
                          horizontal: 6, vertical: 8),
                    ),
                  ),
                ),
                const SizedBox(width: 4),
                IconButton(
                  onPressed: _isFetching
                      ? null
                      : () async {
                          await _fetchCounselors();
                          await _fetchDevices();
                          await _searchCertNo(); // 인증번호 조회
                        },
                  icon: const Icon(Icons.refresh),
                  tooltip: '새로고침',
                ),
                if (_message.isNotEmpty) ...[
                  const SizedBox(width: 8),
                  Flexible(
                    child: Text(
                      _message,
                      style: TextStyle(
                        color:
                            _message.contains('완료') || _message.contains('성공')
                                ? Colors.green
                                : Colors.red,
                        fontWeight: FontWeight.w500,
                      ),
                      overflow: TextOverflow.ellipsis,
                    ),
                  ),
                ],
              ],
            ),
          ],
        ),
      );
    });
  }

  String _findReadyDirectRemoteId(List<Map<String, dynamic>> counselors) {
    for (final agent in counselors) {
      if (_isCurrentMdeskDirectRemote(agent)) {
        final id = _getMdeskId(agent).replaceAll(' ', '');
        if (id.isNotEmpty) return id;
      }
    }
    return '';
  }

  void _scheduleDirectRemoteAutoConnect(List<Map<String, dynamic>> counselors) {
    final remoteId = _findReadyDirectRemoteId(counselors);
    if (remoteId.isEmpty) {
      _directAutoConnectTimer?.cancel();
      _directAutoConnectTimer = null;
      _scheduledDirectRemoteId = '';
      _lastAutoConnectedRemoteId = '';
      _lastPromptedDirectRemoteId = '';
      return;
    }
    _rememberDirectRemoteId(remoteId);
    if (remoteId == _lastAutoConnectedRemoteId ||
        remoteId == _scheduledDirectRemoteId ||
        remoteId == _lastPromptedDirectRemoteId ||
        remoteId == _directRemotePromptId) {
      return;
    }

    _directAutoConnectTimer?.cancel();
    _scheduledDirectRemoteId = remoteId;
    _directAutoConnectTimer = Timer(const Duration(seconds: 1), () {
      _directAutoConnectTimer = null;
      final scheduledId = _scheduledDirectRemoteId;
      _scheduledDirectRemoteId = '';
      if (!mounted || scheduledId.isEmpty) return;
      if (_findReadyDirectRemoteId(_counselors) != scheduledId) return;
      _showDirectRemoteReadyDialog(scheduledId);
    });
  }

  Future<void> _showDirectRemoteReadyDialog(String remoteId) async {
    final cleanId = remoteId.replaceAll(' ', '');
    if (cleanId.isEmpty ||
        !mounted ||
        _directRemotePromptId.isNotEmpty ||
        cleanId == _lastPromptedDirectRemoteId) {
      return;
    }

    _directRemotePromptId = cleanId;
    _lastPromptedDirectRemoteId = cleanId;
    debugPrint('Direct Remote: Showing ready prompt for $cleanId');

    try {
      await windowOnTop(null);
    } catch (e) {
      debugPrint('Direct Remote: Failed to bring main window forward: $e');
    }
    if (!mounted || _directRemotePromptId != cleanId) return;

    if (!_showReconnectButton) {
      setState(() {
        _showReconnectButton = true;
      });
    }

    final shouldConnect = await showGeneralDialog<bool>(
      context: context,
      barrierDismissible: false,
      barrierLabel: '원격 연결 확인',
      barrierColor: Colors.black.withValues(alpha: 0.6),
      transitionDuration: Duration.zero,
      pageBuilder: (context, animation, secondaryAnimation) =>
          _DirectRemoteReadyDialog(remoteId: cleanId),
    );

    if (_directRemotePromptId == cleanId) {
      _directRemotePromptId = '';
    }
    if (!mounted || shouldConnect != true) {
      debugPrint('Direct Remote: Ready prompt dismissed for $cleanId');
      return;
    }
    if (_findReadyDirectRemoteId(_counselors) != cleanId) {
      _lastPromptedDirectRemoteId = '';
      showToast('피원격자의 원격 준비가 해제되었습니다');
      return;
    }

    _connectToDirectRemote(cleanId, automatically: true);
  }

  void _connectToDirectRemote(String remoteId, {required bool automatically}) {
    final cleanId = remoteId.replaceAll(' ', '');
    if (cleanId.isEmpty || !mounted) return;

    _rememberDirectRemoteId(cleanId);
    _directAutoConnectTimer?.cancel();
    _directAutoConnectTimer = null;
    _scheduledDirectRemoteId = '';
    _lastAutoConnectedRemoteId = cleanId;
    _stopCertStatusRefresh();
    setState(() {
      _certReadinessStage = 'connecting';
      _certReadinessProgress = 95;
      _certReadinessMessage = '릴레이 서버로 연결하는 중입니다.';
      _certReadinessRemoteId = cleanId;
    });
    debugPrint(
        'Direct Remote: ${automatically ? 'Connecting after ready confirmation' : 'Connecting'} to $cleanId via relay');
    connect(
      context,
      cleanId,
      forceRelay: true,
      password: _kMdeskMiniAutoConnectPasswordPreset,
    );
  }

  // agent_num == 0인 상담사를 위한 바로 원격 버튼
  Widget _buildDirectRemoteButton(Map<String, dynamic> agent) {
    final mdeskId = _getMdeskId(agent);
    final mdeskIdClean = mdeskId.replaceAll(' ', '');

    return AnimatedBuilder(
      animation: _blinkController,
      builder: (context, child) {
        // 애니메이션 값으로 테두리 색상 및 glow 효과 조절 (0.0 ~ 1.0 범위 유지)
        final glowOpacity =
            (0.3 + (_blinkController.value * 0.4)).clamp(0.0, 1.0);
        final borderOpacity =
            (0.5 + (_blinkController.value * 0.3)).clamp(0.0, 1.0);
        final borderWidth = 2.0 + (_blinkController.value * 2.0);

        return Container(
          width: double.infinity,
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(18),
            border: Border.all(
              color: Color.fromRGBO(76, 175, 80, borderOpacity),
              width: borderWidth,
            ),
            boxShadow: [
              BoxShadow(
                color: Color.fromRGBO(76, 175, 80, glowOpacity),
                blurRadius: 12 + (_blinkController.value * 8),
                spreadRadius: _blinkController.value * 2,
              ),
            ],
          ),
          child: Container(
            padding: const EdgeInsets.all(16),
            decoration: BoxDecoration(
              gradient: LinearGradient(
                colors: [
                  const Color(0xFF1976D2),
                  const Color(0xFF42A5F5),
                ],
                begin: Alignment.topLeft,
                end: Alignment.bottomRight,
              ),
              borderRadius: BorderRadius.circular(16),
            ),
            child: InkWell(
              onTap: () =>
                  _connectToDirectRemote(mdeskIdClean, automatically: false),
              borderRadius: BorderRadius.circular(16),
              child: Row(
                children: [
                  // 아이콘
                  Container(
                    padding: const EdgeInsets.all(12),
                    decoration: BoxDecoration(
                      color: Colors.white.withOpacity(0.2),
                      borderRadius: BorderRadius.circular(12),
                    ),
                    child: const Icon(
                      Icons.connected_tv,
                      color: Colors.white,
                      size: 32,
                    ),
                  ),
                  const SizedBox(width: 16),
                  // 텍스트
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        const Text(
                          '바로 원격 연결',
                          style: TextStyle(
                            color: Colors.white,
                            fontSize: 18,
                            fontWeight: FontWeight.bold,
                          ),
                        ),
                        const SizedBox(height: 4),
                        Text(
                          'ID: ${formatID(mdeskIdClean)}',
                          style: TextStyle(
                            color: Colors.white.withOpacity(0.9),
                            fontSize: 14,
                          ),
                        ),
                      ],
                    ),
                  ),
                  // 연결 버튼 화살표
                  Container(
                    padding: const EdgeInsets.all(8),
                    decoration: BoxDecoration(
                      color: Colors.white.withOpacity(0.2),
                      shape: BoxShape.circle,
                    ),
                    child: const Icon(
                      Icons.arrow_forward,
                      color: Colors.white,
                      size: 24,
                    ),
                  ),
                ],
              ),
            ),
          ),
        );
      },
    );
  }
}

class _DirectRemoteReadyDialog extends StatelessWidget {
  const _DirectRemoteReadyDialog({required this.remoteId});

  final String remoteId;

  @override
  Widget build(BuildContext context) {
    return SafeArea(
      child: Center(
        child: Material(
          color: Colors.transparent,
          child: Container(
            width: 500,
            margin: const EdgeInsets.all(24),
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(22),
              border: Border.all(
                color: const Color(0xFF7182C6),
                width: 1.2,
              ),
              boxShadow: [
                BoxShadow(
                  color: Colors.black.withValues(alpha: 0.28),
                  blurRadius: 24,
                  offset: const Offset(0, 10),
                ),
              ],
              gradient: const LinearGradient(
                colors: [Color(0xFF172554), Color(0xFF312E81)],
                begin: Alignment.topLeft,
                end: Alignment.bottomRight,
              ),
            ),
            child: ClipRRect(
              borderRadius: BorderRadius.circular(21),
              child: Stack(
                children: [
                  SingleChildScrollView(
                    padding: const EdgeInsets.fromLTRB(30, 26, 30, 28),
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Container(
                          padding: const EdgeInsets.symmetric(
                            horizontal: 13,
                            vertical: 6,
                          ),
                          decoration: BoxDecoration(
                            color: Colors.white.withValues(alpha: 0.1),
                            borderRadius: BorderRadius.circular(999),
                            border: Border.all(
                              color: Colors.white.withValues(alpha: 0.16),
                            ),
                          ),
                          child: const Row(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              Icon(
                                Icons.check_circle_outline,
                                size: 16,
                                color: Color(0xFFBAE6FD),
                              ),
                              SizedBox(width: 7),
                              Text(
                                '원격 준비 완료',
                                style: TextStyle(
                                  color: Colors.white,
                                  fontSize: 14,
                                  fontWeight: FontWeight.w700,
                                ),
                              ),
                            ],
                          ),
                        ),
                        const SizedBox(height: 20),
                        Container(
                          width: 76,
                          height: 76,
                          decoration: BoxDecoration(
                            shape: BoxShape.circle,
                            color: const Color(0xFF3B82F6),
                            border: Border.all(
                              color: Colors.white.withValues(alpha: 0.5),
                              width: 2,
                            ),
                          ),
                          child: const Icon(
                            Icons.desktop_windows,
                            size: 38,
                            color: Colors.white,
                          ),
                        ),
                        const SizedBox(height: 20),
                        const Text(
                          '원격이 준비되었습니다!',
                          textAlign: TextAlign.center,
                          style: TextStyle(
                            color: Colors.white,
                            fontSize: 24,
                            fontWeight: FontWeight.w800,
                            height: 1.2,
                            letterSpacing: -0.4,
                          ),
                        ),
                        const SizedBox(height: 9),
                        Text(
                          '피원격자가 접속 가능한 상태입니다.\n지금 원격으로 접속할까요?',
                          textAlign: TextAlign.center,
                          style: TextStyle(
                            color: Colors.white.withValues(alpha: 0.78),
                            fontSize: 15,
                            height: 1.45,
                          ),
                        ),
                        const SizedBox(height: 16),
                        Container(
                          padding: const EdgeInsets.symmetric(
                            horizontal: 15,
                            vertical: 8,
                          ),
                          decoration: BoxDecoration(
                            color: Colors.black.withValues(alpha: 0.16),
                            borderRadius: BorderRadius.circular(11),
                            border: Border.all(
                              color: Colors.white.withValues(alpha: 0.12),
                            ),
                          ),
                          child: Text(
                            '원격 ID  ${formatID(remoteId)}',
                            style: const TextStyle(
                              color: Color(0xFFDDEAFE),
                              fontSize: 14,
                              fontWeight: FontWeight.w700,
                              letterSpacing: 0.3,
                            ),
                          ),
                        ),
                        const SizedBox(height: 24),
                        LayoutBuilder(
                          builder: (context, constraints) {
                            final compact = constraints.maxWidth < 430;
                            final cancelButton = _actionButton(
                              label: '나중에',
                              icon: Icons.schedule,
                              onPressed: () => Navigator.of(context).pop(false),
                              outlined: true,
                            );
                            final connectButton = _actionButton(
                              label: '지금 접속하기',
                              icon: Icons.arrow_forward,
                              onPressed: () => Navigator.of(context).pop(true),
                            );
                            if (compact) {
                              return Column(
                                children: [
                                  connectButton,
                                  const SizedBox(height: 10),
                                  cancelButton,
                                ],
                              );
                            }
                            return Row(
                              children: [
                                Expanded(child: cancelButton),
                                const SizedBox(width: 12),
                                Expanded(flex: 2, child: connectButton),
                              ],
                            );
                          },
                        ),
                      ],
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }

  Widget _actionButton({
    required String label,
    required IconData icon,
    required VoidCallback onPressed,
    bool outlined = false,
  }) {
    final content = Row(
      mainAxisAlignment: MainAxisAlignment.center,
      children: [
        Icon(icon, size: 18, color: Colors.white),
        const SizedBox(width: 7),
        Text(
          label,
          style: const TextStyle(
            color: Colors.white,
            fontSize: 14,
            fontWeight: FontWeight.w700,
          ),
        ),
      ],
    );

    if (outlined) {
      return SizedBox(
        height: 50,
        child: OutlinedButton(
          onPressed: onPressed,
          style: OutlinedButton.styleFrom(
            side: BorderSide(
              color: Colors.white.withValues(alpha: 0.32),
              width: 1.2,
            ),
            backgroundColor: Colors.white.withValues(alpha: 0.07),
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(12),
            ),
          ),
          child: content,
        ),
      );
    }

    return Container(
      height: 50,
      decoration: BoxDecoration(
        color: const Color(0xFF3B82F6),
        borderRadius: BorderRadius.circular(12),
      ),
      child: Material(
        color: Colors.transparent,
        child: InkWell(
          onTap: onPressed,
          borderRadius: BorderRadius.circular(12),
          child: content,
        ),
      ),
    );
  }
}
