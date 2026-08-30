import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:bot_toast/bot_toast.dart';
import 'package:flutter/material.dart';
import 'package:flutter_hbb/common/hbbs/hbbs.dart';
import 'package:flutter_hbb/models/ab_model.dart';
import 'package:flutter_hbb/utils/device_register_service.dart';
import 'package:get/get.dart';
import 'package:http/http.dart' as flutter_http;

import '../common.dart';
import '../utils/http_service.dart' as http;
import 'model.dart';
import 'platform_model.dart';

bool refreshingUser = false;

enum TokenRefreshResult { success, rejected, unavailable, notConfigured }

class UserModel {
  final RxString userName = ''.obs;
  final RxBool isAdmin = false.obs;
  final RxString membershipLevel = 'free'.obs;
  final RxString networkError = ''.obs;
  final RxString userPkid = ''.obs;
  bool get isLogin => userName.isNotEmpty;
  WeakReference<FFI> parent;

  Timer? _refreshTimer;
  Future<TokenRefreshResult>? _accessRefreshFuture;
  int _sessionGeneration = 0;

  static const _refreshTokenKey = 'refresh_token';
  static const _accessTokenExpiresAtKey = 'access_token_expires_at';
  static const _sessionExpiresAtKey = 'login_session_expires_at';
  static const _refreshBeforeExpiry = Duration(minutes: 15);

  // 로그인 직후 리셋 방지 가드 (디버그 모드 타이밍 이슈 해결)
  DateTime? _lastLoginTime;
  static const _loginProtectionDuration = Duration(seconds: 5);

  /// 로그인 보호 기간 내인지 확인 (로그인 직후 일정 시간 동안 401 응답 무시)
  bool isWithinLoginProtection() {
    return _lastLoginTime != null &&
        DateTime.now().difference(_lastLoginTime!) < _loginProtectionDuration;
  }

  UserModel(this.parent) {
    userName.listen((p0) {
      // When user name becomes empty, show login button
      // When user name becomes non-empty:
      //  For _updateLocalUserInfo, network error will be set later
      //  For login success, should clear network error
      networkError.value = '';
      if (p0.isEmpty && isAndroid && gFFI.serverModel.isStart) {
        gFFI.serverModel.stopService();
      }
    });
    // 10분마다 자동 리프레쉬 타이머 설정 (600초)
    _refreshTimer = Timer.periodic(const Duration(minutes: 10), (timer) {
      if (isLogin) {
        refreshCurrentUser();
      }
    });
  }

  Future<void> refreshCurrentUser() async {
    if (bind.isDisableAccount()) return;
    if (refreshingUser) return;
    refreshingUser = true;
    networkError.value = '';
    try {
      var token = bind.mainGetLocalOption(key: 'access_token');
      if (token.isEmpty) {
        final recovery = await refreshAccessToken(force: true);
        if (recovery == TokenRefreshResult.unavailable) {
          debugPrint('UserModel: No access token, skipping refresh');
          return;
        }
        if (recovery != TokenRefreshResult.success) {
          await reset(resetOther: true);
          return;
        }
        token = bind.mainGetLocalOption(key: 'access_token');
      }
      _updateLocalUserInfo();

      if (_shouldRefreshAccessToken()) {
        final proactive = await refreshAccessToken();
        if (proactive == TokenRefreshResult.rejected) {
          await reset(resetOther: true);
          return;
        }
        if (proactive == TokenRefreshResult.success) {
          token = bind.mainGetLocalOption(key: 'access_token');
        }
      }

      final url = await _accountApiServer();
      debugPrint('UserModel: Refreshing user from $url/api/userInfo');
      var response = await _requestCurrentUser(url, token);
      var status = response.statusCode;
      debugPrint('UserModel: Refresh response status: $status');
      if (status == 401 || status == 400) {
        final recovery = await refreshAccessToken(force: true);
        if (recovery == TokenRefreshResult.success) {
          token = bind.mainGetLocalOption(key: 'access_token');
          response = await _requestCurrentUser(url, token);
          status = response.statusCode;
          debugPrint('UserModel: Refresh retry status: $status');
        } else if (recovery == TokenRefreshResult.unavailable) {
          networkError.value =
              'Token refresh service is temporarily unavailable';
          return;
        }
      }
      if (status == 401 || status == 400) {
        // 로그인 직후 일정 시간 내에는 리셋 방지 (디버그 모드 타이밍 이슈)
        if (_lastLoginTime != null &&
            DateTime.now().difference(_lastLoginTime!) <
                _loginProtectionDuration) {
          debugPrint(
              'UserModel: Auth error ignored (within login protection period)');
          return;
        }
        debugPrint('UserModel: Auth error, resetting');
        await reset(resetOther: status == 401);
        return;
      }

      if (status < 200 || status >= 300) {
        networkError.value = 'HTTP $status';
        return;
      }

      final Map<String, dynamic> responseData = json.decode(response.body);

      // 새로운 API 형식 처리 (code: 1, data: { ... })
      if (responseData['code'] == 1 && responseData['data'] != null) {
        final userData = responseData['data'];
        // UserPayload가 기존 필드명을 유지하도록 처리 (username -> name 등 필요한 경우 매핑)
        if (userData['name'] == null && userData['username'] != null) {
          userData['name'] = userData['username'];
        }

        final user = UserPayload.fromJson(userData);
        debugPrint(
            'UserModel: Refreshed user info from userInfo API - Name: ${user.name}, Membership: ${user.membershipLevel}, UserPkid: ${user.userPkid}');
        debugPrint('UserModel: Raw userData keys: ${userData.keys.toList()}');
        debugPrint('UserModel: Raw user_pkid value: ${userData['user_pkid']}');
        _parseAndUpdateUser(user);

        // 기기 등록은 "원격자 등록" 다이얼로그에서만 수행
        // (로그인 시 자동 등록 제거)
      } else {
        debugPrint('UserModel: API response code is not 1 or data is null');
      }
    } catch (e) {
      networkError.value = e.toString();
      debugPrint('Failed to refreshCurrentUser: $e');
    } finally {
      refreshingUser = false;
      await updateOtherModels();
    }
  }

  Future<flutter_http.Response> _requestCurrentUser(
      String url, String accessToken) {
    return flutter_http.get(Uri.parse('$url/api/userInfo'), headers: {
      'Content-Type': 'application/json',
      'Authorization': 'Bearer $accessToken'
    });
  }

  Future<String> _accountApiServer() async {
    var url = await bind.mainGetApiServer();
    if (url.trim().isEmpty) {
      url = 'https://admin.787.kr';
    } else if (url.startsWith('http://')) {
      url = url.replaceFirst('http://', 'https://');
    }
    return url.replaceFirst(RegExp(r'/$'), '');
  }

  bool _shouldRefreshAccessToken() {
    final refreshToken = bind.mainGetLocalOption(key: _refreshTokenKey);
    if (refreshToken.isEmpty) return false;
    final expiresAt =
        int.tryParse(bind.mainGetLocalOption(key: _accessTokenExpiresAtKey));
    if (expiresAt == null) return false;
    return DateTime.now().millisecondsSinceEpoch +
            _refreshBeforeExpiry.inMilliseconds >=
        expiresAt;
  }

  Future<TokenRefreshResult> refreshAccessToken({bool force = false}) async {
    final pending = _accessRefreshFuture;
    if (pending != null) return pending;

    final request = _refreshAccessToken(force: force);
    _accessRefreshFuture = request;
    try {
      return await request;
    } finally {
      if (identical(_accessRefreshFuture, request)) {
        _accessRefreshFuture = null;
      }
    }
  }

  /// Returns true when the session should be kept (refreshed or temporarily
  /// offline). Returns false after a rejected/non-refreshable session is reset.
  Future<bool> recoverUnauthorized({bool resetOther = true}) async {
    if (isWithinLoginProtection()) return true;
    final result = await refreshAccessToken(force: true);
    if (result == TokenRefreshResult.success ||
        result == TokenRefreshResult.unavailable) {
      return true;
    }
    await reset(resetOther: resetOther);
    return false;
  }

  Future<TokenRefreshResult> _refreshAccessToken({required bool force}) async {
    final refreshGeneration = _sessionGeneration;
    final refreshToken = bind.mainGetLocalOption(key: _refreshTokenKey);
    if (refreshToken.isEmpty) return TokenRefreshResult.notConfigured;

    final sessionExpiresAt =
        int.tryParse(bind.mainGetLocalOption(key: _sessionExpiresAtKey));
    if (sessionExpiresAt != null &&
        DateTime.now().millisecondsSinceEpoch >= sessionExpiresAt) {
      return TokenRefreshResult.rejected;
    }
    if (!force && !_shouldRefreshAccessToken()) {
      return TokenRefreshResult.success;
    }

    try {
      final url = await _accountApiServer();
      final response = await flutter_http
          .post(
            Uri.parse('$url/api/token/refresh'),
            headers: {'Content-Type': 'application/json'},
            body: jsonEncode({
              'refresh_token': refreshToken,
              'id': await bind.mainGetMyId(),
              'uuid': await bind.mainGetUuid(),
            }),
          )
          .timeout(const Duration(seconds: 10));

      if (response.statusCode == 200) {
        final body = jsonDecode(response.body) as Map<String, dynamic>;
        final refreshed = LoginResponse.fromJson(body);
        if ((refreshed.access_token ?? '').isEmpty ||
            (refreshed.refresh_token ?? '').isEmpty) {
          return TokenRefreshResult.unavailable;
        }
        if (refreshGeneration != _sessionGeneration) {
          return TokenRefreshResult.rejected;
        }
        await storeLoginSession(refreshed);
        debugPrint('UserModel: Access token refreshed');
        return TokenRefreshResult.success;
      }
      if (response.statusCode == 400 || response.statusCode == 401) {
        debugPrint('UserModel: Refresh session rejected');
        return TokenRefreshResult.rejected;
      }
      debugPrint(
          'UserModel: Refresh service unavailable (${response.statusCode})');
      return TokenRefreshResult.unavailable;
    } catch (e) {
      debugPrint('UserModel: Token refresh failed: $e');
      return TokenRefreshResult.unavailable;
    }
  }

  Future<void> storeLoginSession(LoginResponse response) async {
    final accessToken = response.access_token ?? '';
    if (accessToken.isEmpty) return;

    final now = DateTime.now().millisecondsSinceEpoch;
    final accessSeconds = response.expires_in ?? 0;
    final sessionSeconds = response.session_expires_in ?? 0;
    await bind.mainSetLocalOption(key: 'access_token', value: accessToken);
    await bind.mainSetLocalOption(
        key: _refreshTokenKey, value: response.refresh_token ?? '');
    await bind.mainSetLocalOption(
      key: _accessTokenExpiresAtKey,
      value: accessSeconds > 0 ? '${now + accessSeconds * 1000}' : '',
    );
    await bind.mainSetLocalOption(
      key: _sessionExpiresAtKey,
      value: sessionSeconds > 0 ? '${now + sessionSeconds * 1000}' : '',
    );
  }

  /// Persist credentials before publishing the reactive user state.
  ///
  /// Peer-list listeners start authenticated requests as soon as [userName]
  /// changes, so publishing the user first can make them race with token
  /// persistence and send the previous token.
  Future<void> applyLoginResponse(
    LoginResponse response, {
    required bool storeSession,
  }) async {
    if (storeSession) {
      await storeLoginSession(response);
    }
    final user = response.user;
    if (user == null) return;

    await bind.mainSetLocalOption(key: 'user_info', value: jsonEncode(user));
    _parseAndUpdateUser(user);
  }

  static Map<String, dynamic>? getLocalUserInfo() {
    final userInfo = bind.mainGetLocalOption(key: 'user_info');
    if (userInfo == '') {
      return null;
    }
    try {
      return json.decode(userInfo);
    } catch (e) {
      debugPrint('Failed to get local user info "$userInfo": $e');
    }
    return null;
  }

  _updateLocalUserInfo() {
    final userInfo = getLocalUserInfo();
    if (userInfo != null) {
      userName.value = userInfo['name'];
      membershipLevel.value = userInfo['membership_level'] ?? 'free';
      userPkid.value = (userInfo['user_pkid'] ?? '').toString();
    }
  }

  Future<void> reset({bool resetOther = false}) async {
    _sessionGeneration++;
    debugPrint('UserModel.reset called with resetOther=$resetOther');
    debugPrint('UserModel.reset called from:');
    debugPrint(StackTrace.current.toString().split('\n').take(10).join('\n'));
    await bind.mainSetLocalOption(key: 'access_token', value: '');
    await bind.mainSetLocalOption(key: _refreshTokenKey, value: '');
    await bind.mainSetLocalOption(key: _accessTokenExpiresAtKey, value: '');
    await bind.mainSetLocalOption(key: _sessionExpiresAtKey, value: '');
    await bind.mainSetLocalOption(key: 'user_info', value: '');
    if (resetOther) {
      await gFFI.abModel.reset();
      await gFFI.groupModel.reset();
    }
    userName.value = '';
    membershipLevel.value = 'free';
    userPkid.value = '';
  }

  _parseAndUpdateUser(UserPayload user) {
    userName.value = user.name;
    isAdmin.value = user.isAdmin;
    membershipLevel.value = user.membershipLevel;
    // userPkid: 새 값이 있으면 업데이트, 없으면 기존 값 유지
    if (user.userPkid.isNotEmpty) {
      userPkid.value = user.userPkid;
    }
    bind.mainSetLocalOption(key: 'user_info', value: jsonEncode(user));
    if (isWeb) {
      // ugly here, tmp solution
      bind.mainSetLocalOption(key: 'verifier', value: user.verifier ?? '');
    }
    // 로그인 성공 시간 기록 (디버그 모드 타이밍 이슈 방지)
    _lastLoginTime = DateTime.now();
  }

  /// 현재 기기를 API 서버에 등록
  Future<void> _registerCurrentDevice(
      String accessToken, String userId, String userPkid) async {
    try {
      // 필수 정보 확인
      if (accessToken.isEmpty || userId.isEmpty || userPkid.isEmpty) {
        debugPrint(
            'UserModel: Skipping device registration - missing required info');
        return;
      }

      final remoteId = await bind.mainGetMyId();
      if (remoteId.isEmpty) {
        debugPrint('UserModel: Skipping device registration - no remote ID');
        return;
      }

      // 호스트명과 플랫폼 정보 가져오기
      String hostname = '';
      String platform = '';
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
      } catch (e) {
        debugPrint('UserModel: Error getting platform info: $e');
      }

      // 별칭: 호스트명 또는 플랫폼
      final alias = hostname.isNotEmpty ? hostname : platform;

      debugPrint(
          'UserModel: Registering device - remoteId=$remoteId, alias=$alias, platform=$platform');

      final response = await deviceRegisterService.registerDevice(
        apiServer: 'https://admin.787.kr',
        accessToken: accessToken,
        userId: userId,
        userPkid: userPkid,
        remoteId: remoteId,
        alias: alias,
        hostname: hostname,
        platform: platform,
      );

      if (response.success) {
        debugPrint(
            'UserModel: Device registered successfully - ${response.message}');
      } else {
        debugPrint(
            'UserModel: Device registration failed - ${response.message}');
      }
    } catch (e) {
      debugPrint('UserModel: Error registering device: $e');
    }
  }

  // update ab and group status
  static Future<void> updateOtherModels() async {
    await Future.wait([
      gFFI.abModel.pullAb(force: ForcePullAb.listAndCurrent, quiet: false),
      gFFI.groupModel.pull()
    ]);
  }

  Future<void> logOut({String? apiServer}) async {
    final tag = gFFI.dialogManager.showLoading(translate('Waiting'));
    try {
      final url = apiServer ?? await bind.mainGetApiServer();
      final authHeaders = getHttpHeaders();
      authHeaders['Content-Type'] = "application/json";
      await http
          .post(Uri.parse('$url/api/logout'),
              body: jsonEncode({
                'id': await bind.mainGetMyId(),
                'uuid': await bind.mainGetUuid(),
              }),
              headers: authHeaders)
          .timeout(Duration(seconds: 2));
    } catch (e) {
      debugPrint("request /api/logout failed: err=$e");
    } finally {
      await reset(resetOther: true);
      gFFI.dialogManager.dismissByTag(tag);
    }
  }

  /// throw [RequestException]
  Future<LoginResponse> login(LoginRequest loginRequest) async {
    var url = await bind.mainGetApiServer();
    // http:// -> https:// 강제 변환
    if (url.startsWith('http://')) {
      url = url.replaceFirst('http://', 'https://');
    }
    final loginUrl = '$url/api/login';
    final requestBody = jsonEncode(loginRequest.toJson());
    debugPrint('UserModel: Login request to $loginUrl');
    debugPrint('UserModel: Request body: $requestBody');

    // 직접 Flutter HTTP 사용 (Rust 바인딩 우회)
    final resp = await flutter_http.post(
      Uri.parse(loginUrl),
      headers: {'Content-Type': 'application/json'},
      body: requestBody,
    );

    debugPrint('UserModel: Response status: ${resp.statusCode}');

    final Map<String, dynamic> body;
    try {
      body = jsonDecode(resp.body);
    } catch (e) {
      debugPrint("login: jsonDecode resp body failed: ${e.toString()}");
      if (resp.statusCode != 200) {
        BotToast.showText(
            contentColor: Colors.red, text: 'HTTP ${resp.statusCode}');
      }
      rethrow;
    }
    if (resp.statusCode != 200) {
      throw RequestException(resp.statusCode, body['error'] ?? '');
    }
    if (body['error'] != null) {
      throw RequestException(0, body['error']);
    }

    return getLoginResponseFromAuthBody(body);
  }

  /// MDesk 2차 인증(2FA) 검증 - POST /api/login/2fa
  /// tfa_key, tfa_code로 인증코드 검증 후 성공 시 access_token 반환
  Future<LoginResponse> login2faVerify(String tfaKey, String tfaCode) async {
    var url = await bind.mainGetApiServer();
    if (url.startsWith('http://')) {
      url = url.replaceFirst('http://', 'https://');
    }
    final verifyUrl = '$url/api/login/2fa';
    final requestBody = jsonEncode({'tfa_key': tfaKey, 'tfa_code': tfaCode});
    debugPrint('UserModel: 2FA verify request to $verifyUrl');

    final resp = await flutter_http.post(
      Uri.parse(verifyUrl),
      headers: {'Content-Type': 'application/json'},
      body: requestBody,
    );

    debugPrint('UserModel: 2FA Response status: ${resp.statusCode}');

    final Map<String, dynamic> body;
    try {
      body = jsonDecode(resp.body);
    } catch (e) {
      debugPrint("login2faVerify: jsonDecode failed: ${e.toString()}");
      if (resp.statusCode != 200) {
        BotToast.showText(
            contentColor: Colors.red, text: 'HTTP ${resp.statusCode}');
      }
      rethrow;
    }
    if (resp.statusCode != 200) {
      throw RequestException(resp.statusCode, body['error'] ?? '');
    }
    if (body['error'] != null) {
      throw RequestException(0, body['error']);
    }

    return getLoginResponseFromAuthBody(body);
  }

  LoginResponse getLoginResponseFromAuthBody(Map<String, dynamic> body) {
    final LoginResponse loginResponse;
    try {
      loginResponse = LoginResponse.fromJson(body);
    } catch (e) {
      debugPrint("login: jsonDecode LoginResponse failed: ${e.toString()}");
      rethrow;
    }

    return loginResponse;
  }

  static Future<List<dynamic>> queryOidcLoginOptions() async {
    try {
      final url = await bind.mainGetApiServer();
      if (url.trim().isEmpty) return [];
      final resp = await http.get(Uri.parse('$url/api/login-options'));
      final List<String> ops = [];
      for (final item in jsonDecode(resp.body)) {
        ops.add(item as String);
      }
      for (final item in ops) {
        if (item.startsWith('common-oidc/')) {
          return jsonDecode(item.substring('common-oidc/'.length));
        }
      }
      return ops
          .where((item) => item.startsWith('oidc/'))
          .map((item) => {'name': item.substring('oidc/'.length)})
          .toList();
    } catch (e) {
      debugPrint(
          "queryOidcLoginOptions: jsonDecode resp body failed: ${e.toString()}");
      return [];
    }
  }
}
