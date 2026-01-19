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

class UserModel {
  final RxString userName = ''.obs;
  final RxBool isAdmin = false.obs;
  final RxString membershipLevel = 'free'.obs;
  final RxString networkError = ''.obs;
  final RxString userPkid = ''.obs;
  bool get isLogin => userName.isNotEmpty;
  WeakReference<FFI> parent;

  Timer? _refreshTimer;

  UserModel(this.parent) {
    userName.listen((p0) {
      // When user name becomes empty, show login button
      // When user name becomes non-empty:
      //  For _updateLocalUserInfo, network error will be set later
      //  For login success, should clear network error
      networkError.value = '';
    });
    // 10분마다 자동 리프레쉬 타이머 설정 (600초)
    _refreshTimer = Timer.periodic(const Duration(minutes: 10), (timer) {
      if (isLogin) {
        refreshCurrentUser();
      }
    });
  }

  void refreshCurrentUser() async {
    if (bind.isDisableAccount()) return;
    networkError.value = '';
    final token = bind.mainGetLocalOption(key: 'access_token');
    if (token == '') {
      debugPrint('UserModel: No access token, skipping refresh');
      await updateOtherModels();
      return;
    }
    _updateLocalUserInfo();
    
    // 사용자가 새로 만든 userInfo API 사용 (admin.787.kr)
    const url = 'https://admin.787.kr';
    
    if (refreshingUser) return;
    try {
      refreshingUser = true;
      debugPrint('UserModel: Refreshing user from $url/api/userInfo');
      
      final flutter_http.Response response;
      try {
        response = await flutter_http.get(Uri.parse('$url/api/userInfo'),
            headers: {
              'Content-Type': 'application/json',
              'Authorization': 'Bearer $token'
            });
      } catch (e) {
        networkError.value = e.toString();
        debugPrint('UserModel: Network error during refresh: $e');
        rethrow;
      }
      refreshingUser = false;
      final status = response.statusCode;
      debugPrint('UserModel: Refresh response status: $status');
      debugPrint('UserModel: Refresh response body: ${response.body}');
      if (status == 401 || status == 400) {
        debugPrint('UserModel: Auth error, resetting');
        reset(resetOther: status == 401);
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
        debugPrint('UserModel: Refreshed user info from userInfo API - Name: ${user.name}, Membership: ${user.membershipLevel}, UserPkid: ${user.userPkid}');
        debugPrint('UserModel: Raw userData keys: ${userData.keys.toList()}');
        debugPrint('UserModel: Raw user_pkid value: ${userData['user_pkid']}');
        _parseAndUpdateUser(user);
        
        // 기기 등록은 "원격자 등록" 다이얼로그에서만 수행
        // (로그인 시 자동 등록 제거)
      } else {
        debugPrint('UserModel: API response code is not 1 or data is null');
      }
    } catch (e) {
      debugPrint('Failed to refreshCurrentUser: $e');
    } finally {
      refreshingUser = false;
      await updateOtherModels();
    }
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
    await bind.mainSetLocalOption(key: 'access_token', value: '');
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
  }

  /// 현재 기기를 API 서버에 등록
  Future<void> _registerCurrentDevice(String accessToken, String userId, String userPkid) async {
    try {
      // 필수 정보 확인
      if (accessToken.isEmpty || userId.isEmpty || userPkid.isEmpty) {
        debugPrint('UserModel: Skipping device registration - missing required info');
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

      debugPrint('UserModel: Registering device - remoteId=$remoteId, alias=$alias, platform=$platform');

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
        debugPrint('UserModel: Device registered successfully - ${response.message}');
      } else {
        debugPrint('UserModel: Device registration failed - ${response.message}');
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
    debugPrint('UserModel: Response body: ${resp.body}');

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

  LoginResponse getLoginResponseFromAuthBody(Map<String, dynamic> body) {
    final LoginResponse loginResponse;
    try {
      loginResponse = LoginResponse.fromJson(body);
    } catch (e) {
      debugPrint("login: jsonDecode LoginResponse failed: ${e.toString()}");
      rethrow;
    }

    final isLogInDone = loginResponse.type == HttpType.kAuthResTypeToken &&
        loginResponse.access_token != null;
    if (isLogInDone && loginResponse.user != null) {
      _parseAndUpdateUser(loginResponse.user!);
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
