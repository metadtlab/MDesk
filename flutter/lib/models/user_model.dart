import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:bot_toast/bot_toast.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_hbb/common/hbbs/hbbs.dart';
import 'package:flutter_hbb/models/ab_model.dart';
import 'package:flutter_hbb/utils/device_register_service.dart';
import 'package:get/get.dart';
import 'package:http/http.dart' as flutter_http;

import '../common.dart';
import '../utils/http_service.dart' as http;
import '../utils/session_refresh_coordinator.dart';
import '../utils/session_write_coordinator.dart';
import 'model.dart';
import 'login_session_status.dart';
import 'biometric_login.dart';
import 'platform_model.dart';
import '../utils/multi_window_manager.dart';

bool refreshingUser = false;

enum TokenRefreshResult { success, rejected, unavailable, notConfigured }

class UserModel {
  final RxString userName = ''.obs;
  final RxBool isAdmin = false.obs;
  final RxString membershipLevel = 'free'.obs;
  final RxString networkError = ''.obs;
  final RxString userPkid = ''.obs;
  final RxBool biometricLoginEnabled = false.obs;
  final _biometricLogin = const BiometricLogin();
  String? _biometricRefreshToken;
  bool _biometricLoginBusy = false;
  static const _biometricEnabledKey = 'biometric-login-enabled';
  bool get isBiometricLocked =>
      isMobile && biometricLoginEnabled.value && _biometricRefreshToken == null;
  String get _refreshToken =>
      _biometricRefreshToken ?? bind.mainGetLocalOption(key: _refreshTokenKey);
  bool get isLogin => userName.isNotEmpty;
  WeakReference<FFI> parent;

  Timer? _refreshTimer;
  Future<bool>? _sessionStatusFuture;
  DateTime _nextUserRefresh = DateTime.now();
  final _accessRefreshCoordinator =
      SessionRefreshCoordinator<TokenRefreshResult>();
  final _sessionWrites = SessionWriteCoordinator();
  int _sessionGeneration = 0;
  int? _sessionTransition;
  int _serverInfoRevision = 0;

  /// Read-only identity/version markers for account-bound StoreKit operations.
  int get sessionGeneration => _sessionGeneration;
  int get serverInfoRevision => _serverInfoRevision;
  bool get isSessionTransitioning => _sessionTransition != null;
  Future<String> accountApiServer() => _accountApiServer();

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
    _refreshTimer = Timer.periodic(const Duration(seconds: 10), (timer) async {
      if (parent.target == null) {
        _refreshTimer?.cancel();
        _refreshTimer = null;
        return;
      }
      // FFI instances for remote tabs must not run account monitors.
      if (!identical(parent.target, gFFI) ||
          (isDesktop && desktopType != DesktopType.main)) {
        return;
      }
      if (isLogin) {
        if (isDesktop && !await checkLoginSession()) return;
        if (DateTime.now().isAfter(_nextUserRefresh)) {
          _nextUserRefresh = DateTime.now().add(const Duration(minutes: 10));
          await refreshCurrentUser();
        }
      }
    });
  }

  /// Run before restoring user state or starting authenticated mobile requests.
  Future<void> prepareBiometricLogin() async {
    if (!isMobile) return;
    var enabled = bind.mainGetLocalOption(key: _biometricEnabledKey) == 'Y';
    try {
      enabled = await _biometricLogin.hasSession() || enabled;
    } catch (_) {
      // If the native vault is unavailable, an enrolled account stays locked.
    }
    if (!enabled) return;
    biometricLoginEnabled.value = true;
    await bind.mainSetLocalOption(key: _biometricEnabledKey, value: 'Y');
    await bind.mainSetLocalOption(key: 'access_token', value: '');
    await bind.mainSetLocalOption(key: _refreshTokenKey, value: '');
  }

  Future<bool> enableBiometricLogin() async {
    if (!isMobile || !isLogin || _biometricLoginBusy) return false;
    _biometricLoginBusy = true;
    final generation = _sessionGeneration;
    try {
      var enabled = false;
      await _sessionWrites.run(() async {
        if (generation != _sessionGeneration) return;
        final refresh = _refreshToken;
        final expiresAt =
            int.tryParse(bind.mainGetLocalOption(key: _sessionExpiresAtKey)) ??
                0;
        final user = getLocalUserInfo();
        final access = bind.mainGetLocalOption(key: 'access_token');
        if (refresh.isEmpty ||
            user == null ||
            expiresAt <= DateTime.now().millisecondsSinceEpoch) {
          throw PlatformException(code: 'not_configured');
        }
        if (!await _biometricLogin.isAvailable()) {
          throw PlatformException(code: 'unavailable');
        }
        final server = await _accountApiServer();
        if (generation != _sessionGeneration) return;
        final enrolled = await _biometricLogin.enroll(BiometricSession(
            refreshToken: refresh,
            expiresAt: expiresAt,
            apiServer: server,
            user: user));
        if (generation != _sessionGeneration) {
          await _biometricLogin.clear();
          return;
        }
        if (!enrolled) return;
        _biometricRefreshToken = refresh;
        biometricLoginEnabled.value = true;
        await bind.mainSetLocalOption(key: _biometricEnabledKey, value: 'Y');
        if (generation != _sessionGeneration) return;
        // Rust keeps this access token in memory once biometric login is on.
        await bind.mainSetLocalOption(key: 'access_token', value: access);
        if (generation != _sessionGeneration) return;
        await bind.mainSetLocalOption(key: _refreshTokenKey, value: '');
        enabled = generation == _sessionGeneration;
      });
      return enabled;
    } finally {
      _biometricLoginBusy = false;
    }
  }

  Future<void> disableBiometricLogin() {
    final generation = _sessionGeneration;
    return _sessionWrites.run(() async {
      if (generation != _sessionGeneration) return;
      final access =
          isLogin ? bind.mainGetLocalOption(key: 'access_token') : '';
      final refresh = isLogin ? _refreshToken : '';
      await _clearBiometricLogin();
      if (generation != _sessionGeneration) return;
      await bind.mainSetLocalOption(key: 'access_token', value: access);
      if (generation != _sessionGeneration) return;
      await bind.mainSetLocalOption(key: _refreshTokenKey, value: refresh);
    });
  }

  Future<void> _clearBiometricLogin() async {
    if (biometricLoginEnabled.value || _biometricLoginBusy) {
      try {
        await _biometricLogin.clear();
      } catch (_) {
        // Local logout must still finish if native storage is unavailable.
        debugPrint('Biometric vault cleanup unavailable');
      }
      await bind.mainSetLocalOption(key: 'access_token', value: '');
      await bind.mainSetLocalOption(key: _refreshTokenKey, value: '');
    }
    _biometricRefreshToken = null;
    biometricLoginEnabled.value = false;
    await bind.mainSetLocalOption(key: _biometricEnabledKey, value: '');
  }

  Future<void> cancelBiometricLogin() async {
    if (!_biometricLoginBusy) return;
    ++_sessionGeneration;
    try {
      await _biometricLogin.cancel();
    } catch (_) {}
  }

  Future<bool> loginWithBiometrics() async {
    if (!isMobile || !biometricLoginEnabled.value || _biometricLoginBusy) {
      return false;
    }
    _biometricLoginBusy = true;
    final generation = ++_sessionGeneration;
    _sessionStatusFuture = null;
    try {
      final session = await _biometricLogin.unlock();
      if (generation != _sessionGeneration || session == null) return false;
      final server = await _accountApiServer();
      if (generation != _sessionGeneration) return false;
      if (!session.canRestore(server, DateTime.now())) {
        await reset(resetOther: true);
        throw PlatformException(code: 'expired');
      }
      await _sessionWrites.run(() async {
        if (generation != _sessionGeneration) return;
        _biometricRefreshToken = session.refreshToken;
        await bind.mainSetLocalOption(
            key: _sessionExpiresAtKey, value: '${session.expiresAt}');
        if (generation != _sessionGeneration) return;
        await bind.mainSetLocalOption(
            key: 'user_info', value: jsonEncode(session.user));
      });
      if (generation != _sessionGeneration) return false;
      final refreshed = await refreshAccessToken(force: true);
      if (generation != _sessionGeneration) return false;
      if (refreshed == TokenRefreshResult.rejected ||
          refreshed == TokenRefreshResult.notConfigured) {
        await reset(resetOther: true);
        throw PlatformException(code: 'expired');
      }
      if (refreshed != TokenRefreshResult.success) {
        _biometricRefreshToken = null;
        throw PlatformException(code: 'network');
      }
      // Publish the cached identity only after the server has accepted the
      // refresh credential, even if another user-info request is in flight.
      await _sessionWrites.run(() async {
        if (generation != _sessionGeneration) return;
        final user = UserPayload.fromJson(session.user);
        await _storeUserInfo(user, generation: generation);
        if (generation != _sessionGeneration) return;
        _lastLoginTime = DateTime.now();
        _parseAndUpdateUser(user);
      });
      await refreshCurrentUser();
      return generation == _sessionGeneration && isLogin;
    } on FormatException {
      if (generation != _sessionGeneration) return false;
      await reset(resetOther: true);
      throw PlatformException(code: 'invalidated');
    } on PlatformException catch (error) {
      if (generation != _sessionGeneration) return false;
      if (error.code == 'invalidated') await reset(resetOther: true);
      rethrow;
    } finally {
      _biometricLoginBusy = false;
    }
  }

  /// Poll immediately before a new connection as well as while idle.
  Future<bool> checkLoginSession() async {
    // Temporarily keep Windows accounts signed in across server-side replacement.
    if (isWindows) return true;
    if (isBiometricLocked) return false;
    if (bind.isDisableAccount()) return true;
    final pending = _sessionStatusFuture;
    if (pending != null) return pending;
    final request = _checkLoginSession();
    _sessionStatusFuture = request;
    try {
      return await request;
    } finally {
      if (identical(_sessionStatusFuture, request)) _sessionStatusFuture = null;
    }
  }

  Future<bool> _checkLoginSession() async {
    final snapshot = LoginSessionSnapshot(
        _sessionGeneration, bind.mainGetLocalOption(key: 'access_token'));
    if (snapshot.accessToken.isEmpty) return !isLogin;
    bool isCurrent() => snapshot.matches(
        _sessionGeneration, bind.mainGetLocalOption(key: 'access_token'));
    try {
      final url = await _accountApiServer();
      if (!isCurrent()) return isLogin;
      final response = await flutter_http.get(
        Uri.parse('$url/api/session/status'),
        headers: {'Authorization': 'Bearer ${snapshot.accessToken}'},
      ).timeout(const Duration(seconds: 5));
      if (!isCurrent()) return isLogin;
      final status =
          parseLoginSessionStatus(response.statusCode, response.body);
      if (status == LoginSessionStatus.replaced ||
          status == LoginSessionStatus.revoked) {
        await _endRevokedSession(status);
        return false;
      }
      if (status == LoginSessionStatus.expired) {
        return recoverUnauthorized();
      }
    } catch (e) {
      debugPrint('Login session check unavailable: $e');
    }
    return true;
  }

  Future<void> _endRevokedSession(LoginSessionStatus status) async {
    final revokedGeneration = _sessionGeneration + 1;
    if (!await _resetAfterAuthenticationFailure(resetOther: true)) return;
    if (_sessionGeneration != revokedGeneration) return;
    if (isDesktop && desktopType == DesktopType.main) {
      try {
        await RustDeskMultiWindowManager.instance.closeAllSubWindows();
      } catch (e) {
        debugPrint('Failed to close revoked account sessions: $e');
      }
    }
    if (status == LoginSessionStatus.replaced) {
      showToast('다른 PC에서 로그인하여 로그아웃되었습니다.');
    }
  }

  Future<void> refreshCurrentUser() async {
    if (isBiometricLocked) return;
    if (bind.isDisableAccount()) return;
    if (isSessionTransitioning) return;
    if (refreshingUser) return;
    refreshingUser = true;
    final generation = _sessionGeneration;
    String? requestedName;
    String? requestedUserId;
    bool isCurrentSession() =>
        generation == _sessionGeneration &&
        (requestedName == null || requestedName == userName.value) &&
        (requestedUserId == null || requestedUserId == userPkid.value);
    networkError.value = '';
    try {
      var token = bind.mainGetLocalOption(key: 'access_token');
      if (token.isEmpty) {
        final recovery = await refreshAccessToken(force: true);
        if (!isCurrentSession()) return;
        if (recovery == TokenRefreshResult.unavailable) {
          debugPrint('UserModel: No access token, skipping refresh');
          return;
        }
        if (recovery != TokenRefreshResult.success) {
          await _resetAfterAuthenticationFailure(resetOther: true);
          return;
        }
        token = bind.mainGetLocalOption(key: 'access_token');
      }
      _updateLocalUserInfo();
      requestedName = userName.value;
      requestedUserId = userPkid.value;

      if (_shouldRefreshAccessToken()) {
        final proactive = await refreshAccessToken();
        if (!isCurrentSession()) return;
        if (proactive == TokenRefreshResult.rejected) {
          await _resetAfterAuthenticationFailure(resetOther: true);
          return;
        }
        if (proactive == TokenRefreshResult.success) {
          token = bind.mainGetLocalOption(key: 'access_token');
        }
      }

      final url = await _accountApiServer();
      if (!isCurrentSession()) return;
      debugPrint('UserModel: Refreshing user from $url/api/userInfo');
      var response = await _requestCurrentUser(url, token);
      if (!isCurrentSession() ||
          token != bind.mainGetLocalOption(key: 'access_token')) {
        return;
      }
      var status = response.statusCode;
      debugPrint('UserModel: Refresh response status: $status');
      if (status == 401 || status == 400) {
        final recovery = await refreshAccessToken(force: true);
        if (!isCurrentSession()) return;
        if (recovery == TokenRefreshResult.success) {
          token = bind.mainGetLocalOption(key: 'access_token');
          response = await _requestCurrentUser(url, token);
          if (!isCurrentSession() ||
              token != bind.mainGetLocalOption(key: 'access_token')) {
            return;
          }
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
        debugPrint('UserModel: Auth error, handling account state');
        await _resetAfterAuthenticationFailure(resetOther: status == 401);
        return;
      }

      if (status < 200 || status >= 300) {
        networkError.value = 'HTTP $status';
        return;
      }

      final Map<String, dynamic> responseData = json.decode(response.body);
      final currentUrl = await _accountApiServer();
      if (!isCurrentSession() || currentUrl != url) return;

      // 새로운 API 형식 처리 (code: 1, data: { ... })
      if (responseData['code'] == 1 && responseData['data'] != null) {
        final userData = responseData['data'];
        // UserPayload가 기존 필드명을 유지하도록 처리 (username -> name 등 필요한 경우 매핑)
        if (userData['name'] == null && userData['username'] != null) {
          userData['name'] = userData['username'];
        }

        final user = UserPayload.fromJson(userData);
        if (requestedUserId.isNotEmpty &&
            user.userPkid.isNotEmpty &&
            requestedUserId != user.userPkid) {
          networkError.value =
              'Account information does not match this session';
          return;
        }
        debugPrint(
            'UserModel: Refreshed user info from userInfo API - Name: ${user.name}, Membership: ${user.membershipLevel}, UserPkid: ${user.userPkid}');
        debugPrint('UserModel: Raw userData keys: ${userData.keys.toList()}');
        debugPrint('UserModel: Raw user_pkid value: ${userData['user_pkid']}');
        await _sessionWrites.run(() async {
          if (!isCurrentSession() ||
              token != bind.mainGetLocalOption(key: 'access_token')) {
            return;
          }
          await _storeUserInfo(user, generation: generation);
          if (!isCurrentSession() ||
              token != bind.mainGetLocalOption(key: 'access_token')) {
            return;
          }
          _parseAndUpdateUser(user);
          _serverInfoRevision++;
        });

        // 기기 등록은 "원격자 등록" 다이얼로그에서만 수행
        // (로그인 시 자동 등록 제거)
      } else {
        debugPrint('UserModel: API response code is not 1 or data is null');
      }
    } catch (e) {
      if (!isCurrentSession()) return;
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
    }).timeout(const Duration(seconds: 10));
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
    final refreshToken = _refreshToken;
    if (refreshToken.isEmpty) return false;
    final expiresAt =
        int.tryParse(bind.mainGetLocalOption(key: _accessTokenExpiresAtKey));
    if (expiresAt == null) return false;
    return DateTime.now().millisecondsSinceEpoch +
            _refreshBeforeExpiry.inMilliseconds >=
        expiresAt;
  }

  Future<TokenRefreshResult> refreshAccessToken({
    bool force = false,
    String? expectedOrigin,
    int? expectedGeneration,
  }) async {
    if (isBiometricLocked) return TokenRefreshResult.notConfigured;
    if (isSessionTransitioning) return TokenRefreshResult.unavailable;
    final generation = _sessionGeneration;
    final configuredUrl = await _accountApiServer();
    if (generation != _sessionGeneration ||
        (expectedGeneration != null && expectedGeneration != generation)) {
      return TokenRefreshResult.rejected;
    }
    // Billing pins the first-party origin. A mutable server-setting change must
    // never redirect its refresh token, even between two asynchronous reads.
    if (expectedOrigin != null) {
      final configured = Uri.tryParse(configuredUrl);
      final expected = Uri.tryParse(expectedOrigin);
      if (configured == null ||
          expected == null ||
          configured.scheme != 'https' ||
          expected.scheme != 'https' ||
          configured.host.isEmpty ||
          expected.host.isEmpty ||
          configured.origin != expected.origin ||
          configured.userInfo.isNotEmpty ||
          expected.userInfo.isNotEmpty ||
          configured.hasQuery ||
          configured.hasFragment ||
          expected.hasQuery ||
          expected.hasFragment ||
          (configured.path.isNotEmpty && configured.path != '/') ||
          (expected.path.isNotEmpty && expected.path != '/')) {
        return TokenRefreshResult.rejected;
      }
    }
    if (_refreshToken.isEmpty) {
      return TokenRefreshResult.notConfigured;
    }
    final sessionExpiresAt =
        int.tryParse(bind.mainGetLocalOption(key: _sessionExpiresAtKey));
    if (sessionExpiresAt != null &&
        DateTime.now().millisecondsSinceEpoch >= sessionExpiresAt) {
      return TokenRefreshResult.rejected;
    }
    // Do not pool no-op refreshes with a forced retry after an HTTP 401.
    if (!force && !_shouldRefreshAccessToken()) {
      return TokenRefreshResult.success;
    }
    return _accessRefreshCoordinator.run(
      generation: generation,
      server: configuredUrl,
      request: () => _refreshAccessToken(
        generation: generation,
        configuredUrl: configuredUrl,
        requestUrl: expectedOrigin ?? configuredUrl,
      ),
    );
  }

  /// Returns true when account state is kept, including Windows authentication
  /// failures. This does not indicate that a failed server request succeeded.
  Future<bool> recoverUnauthorized({bool resetOther = true}) async {
    if (isWithinLoginProtection()) return true;
    final generation = _sessionGeneration;
    final result = await refreshAccessToken(force: true);
    if (generation != _sessionGeneration) return isLogin;
    if (result == TokenRefreshResult.success ||
        result == TokenRefreshResult.unavailable) {
      return true;
    }
    return !await _resetAfterAuthenticationFailure(resetOther: resetOther);
  }

  /// Windows auto logout is temporarily disabled; explicit reset/logout still
  /// clears credentials. Other platforms retain automatic authentication cleanup.
  Future<bool> _resetAfterAuthenticationFailure(
      {required bool resetOther}) async {
    if (isWindows) {
      networkError.value = '로그인 인증을 갱신하지 못했습니다. 다시 로그인해 주세요.';
      debugPrint('Windows account retained after authentication failure');
      return false;
    }
    await reset(resetOther: resetOther);
    return true;
  }

  Future<TokenRefreshResult> _refreshAccessToken({
    required int generation,
    required String configuredUrl,
    required String requestUrl,
  }) async {
    if (generation != _sessionGeneration) return TokenRefreshResult.rejected;
    final refreshToken = _refreshToken;
    if (refreshToken.isEmpty) return TokenRefreshResult.notConfigured;

    final sessionExpiresAt =
        int.tryParse(bind.mainGetLocalOption(key: _sessionExpiresAtKey));
    if (sessionExpiresAt != null &&
        DateTime.now().millisecondsSinceEpoch >= sessionExpiresAt) {
      return TokenRefreshResult.rejected;
    }
    try {
      final id = await bind.mainGetMyId();
      final uuid = await bind.mainGetUuid();
      final currentUrl = await _accountApiServer();
      if (generation != _sessionGeneration || currentUrl != configuredUrl) {
        return TokenRefreshResult.rejected;
      }
      final request = flutter_http.Request(
          'POST', Uri.parse('$requestUrl/api/token/refresh'))
        ..followRedirects = false
        ..headers['Content-Type'] = 'application/json'
        ..body = jsonEncode({
          'refresh_token': refreshToken,
          'id': id,
          'uuid': uuid,
        });
      final client = flutter_http.Client();
      final flutter_http.Response response;
      try {
        response = await (() async {
          final streamed = await client.send(request);
          return flutter_http.Response.fromStream(streamed);
        })()
            .timeout(const Duration(seconds: 10));
      } finally {
        client.close();
      }
      final responseUrl = await _accountApiServer();
      if (generation != _sessionGeneration || responseUrl != configuredUrl) {
        return TokenRefreshResult.rejected;
      }

      if (response.statusCode == 200) {
        final body = jsonDecode(response.body) as Map<String, dynamic>;
        final refreshed = LoginResponse.fromJson(body);
        if ((refreshed.access_token ?? '').isEmpty ||
            (refreshed.refresh_token ?? '').isEmpty) {
          return TokenRefreshResult.unavailable;
        }
        if (generation != _sessionGeneration) {
          return TokenRefreshResult.rejected;
        }
        await storeLoginSession(refreshed,
            expectedGeneration: generation, expectedServer: configuredUrl);
        final storedServer = await _accountApiServer();
        if (generation != _sessionGeneration ||
            isSessionTransitioning ||
            storedServer != configuredUrl) {
          return TokenRefreshResult.rejected;
        }
        debugPrint('UserModel: Access token refreshed');
        return TokenRefreshResult.success;
      }
      if (response.statusCode == 400 || response.statusCode == 401) {
        final status =
            parseLoginSessionStatus(response.statusCode, response.body);
        if (status == LoginSessionStatus.replaced ||
            status == LoginSessionStatus.revoked) {
          await _endRevokedSession(status);
        }
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

  Future<void> storeLoginSession(
    LoginResponse response, {
    int? expectedGeneration,
    String? expectedServer,
  }) {
    final generation = expectedGeneration ?? _sessionGeneration;
    return _sessionWrites.run(() => _storeLoginSession(response,
        generation: generation, expectedServer: expectedServer));
  }

  /// Runs inside the FIFO writer; calling the public wrapper here would enqueue
  /// a nested operation and deadlock login/refresh publication.
  Future<void> _storeLoginSession(
    LoginResponse response, {
    required int generation,
    String? expectedServer,
  }) async {
    if (generation != _sessionGeneration) return;
    final accessToken = response.access_token ?? '';
    if (accessToken.isEmpty) return;

    final now = DateTime.now().millisecondsSinceEpoch;
    final accessSeconds = response.expires_in ?? 0;
    final sessionSeconds = response.session_expires_in ?? 0;
    final sessionExpiresAt =
        sessionSeconds > 0 ? now + sessionSeconds * 1000 : 0;
    final server = await _accountApiServer();
    if (generation != _sessionGeneration ||
        (expectedServer != null && server != expectedServer)) {
      return;
    }
    if (isMobile && biometricLoginEnabled.value) {
      final user = response.user?.toJson() ?? getLocalUserInfo();
      if (user == null ||
          (response.refresh_token ?? '').isEmpty ||
          sessionExpiresAt <= now) {
        throw PlatformException(code: 'invalidated');
      }
      await _biometricLogin.update(BiometricSession(
          refreshToken: response.refresh_token!,
          expiresAt: sessionExpiresAt,
          apiServer: server,
          user: user));
      if (generation != _sessionGeneration) return;
      _biometricRefreshToken = response.refresh_token;
    }
    if (expectedServer != null) {
      final currentServer = await _accountApiServer();
      if (generation != _sessionGeneration || currentServer != expectedServer) {
        return;
      }
    }
    await bind.mainSetLocalOption(key: 'access_token', value: accessToken);
    if (generation != _sessionGeneration) return;
    await bind.mainSetLocalOption(
        key: _refreshTokenKey,
        value: biometricLoginEnabled.value ? '' : response.refresh_token ?? '');
    if (generation != _sessionGeneration) return;
    await bind.mainSetLocalOption(
      key: _accessTokenExpiresAtKey,
      value: accessSeconds > 0 ? '${now + accessSeconds * 1000}' : '',
    );
    if (generation != _sessionGeneration) return;
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
    // A fresh login invalidates a purchase/refresh started by the old session,
    // even when the account name is the same. Token rotation does not use this.
    final generation = ++_sessionGeneration;
    _sessionTransition = generation;
    _sessionStatusFuture = null;
    try {
      await _sessionWrites.run(() async {
        if (generation != _sessionGeneration) return;
        // Require a new biometric opt-in after password/OIDC/2FA login rather
        // than silently replacing the account enrolled in the native vault.
        final wasBiometric = biometricLoginEnabled.value;
        if (isMobile) await _clearBiometricLogin();
        if (generation != _sessionGeneration) return;
        if (storeSession || (isMobile && wasBiometric)) {
          await _storeLoginSession(response, generation: generation);
        }
        if (generation != _sessionGeneration) return;
        final user = response.user;
        if (user == null) return;
        await _storeUserInfo(user, generation: generation);
        if (generation != _sessionGeneration) return;
        _lastLoginTime = DateTime.now();
        _parseAndUpdateUser(user);
      });
    } finally {
      if (_sessionTransition == generation) _sessionTransition = null;
    }
  }

  static Map<String, dynamic>? getLocalUserInfo() {
    final userInfo = bind.mainGetLocalOption(key: 'user_info');
    if (userInfo == '') {
      return null;
    }
    try {
      return json.decode(userInfo);
    } catch (_) {
      debugPrint('UserModel: Saved account information could not be decoded');
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
    final generation = ++_sessionGeneration;
    _sessionTransition = generation;
    _sessionStatusFuture = null;
    debugPrint('UserModel.reset called with resetOther=$resetOther');
    debugPrint('UserModel.reset called from:');
    debugPrint(StackTrace.current.toString().split('\n').take(10).join('\n'));
    try {
      if (isMobile && _biometricLoginBusy) {
        try {
          await _biometricLogin.cancel();
        } catch (_) {
          // Native cancellation errors must not prevent explicit logout.
        }
      }
      await _sessionWrites.run(() async {
        if (generation != _sessionGeneration) return;
        if (isMobile) await _clearBiometricLogin();
        for (final key in [
          'access_token',
          _refreshTokenKey,
          _accessTokenExpiresAtKey,
          _sessionExpiresAtKey,
          'user_info',
        ]) {
          if (generation != _sessionGeneration) return;
          await bind.mainSetLocalOption(key: key, value: '');
        }
      });
      if (generation != _sessionGeneration) return;
      if (resetOther) {
        await gFFI.abModel.reset();
        if (generation != _sessionGeneration) return;
        await gFFI.groupModel.reset();
      }
      if (generation != _sessionGeneration) return;
      userName.value = '';
      isAdmin.value = false;
      _lastLoginTime = null;
      membershipLevel.value = 'free';
      userPkid.value = '';
    } finally {
      if (_sessionTransition == generation) _sessionTransition = null;
    }
  }

  /// The caller owns the FIFO writer and publishes only after this completes.
  Future<void> _storeUserInfo(UserPayload user,
      {required int generation}) async {
    if (generation != _sessionGeneration) return;
    await bind.mainSetLocalOption(key: 'user_info', value: jsonEncode(user));
    if (isWeb && generation == _sessionGeneration) {
      await bind.mainSetLocalOption(
          key: 'verifier', value: user.verifier ?? '');
    }
  }

  void _parseAndUpdateUser(UserPayload user) {
    userName.value = user.name;
    isAdmin.value = user.isAdmin;
    membershipLevel.value = user.membershipLevel;
    // userPkid: 새 값이 있으면 업데이트, 없으면 기존 값 유지
    if (user.userPkid.isNotEmpty) {
      userPkid.value = user.userPkid;
    }
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
