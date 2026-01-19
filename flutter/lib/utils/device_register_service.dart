import 'dart:convert';
import 'package:flutter/foundation.dart';
import 'package:flutter_hbb/utils/http_service.dart' as http;

/// 기기 등록 응답 모델
class DeviceRegisterResponse {
  final bool success;
  final String message;
  final String? error;
  final DeviceData? data;
  final int? statusCode;  // HTTP 상태 코드

  DeviceRegisterResponse({
    required this.success,
    required this.message,
    this.error,
    this.data,
    this.statusCode,
  });
  
  /// 401 Unauthorized 응답인지 확인
  bool get isUnauthorized => statusCode == 401 || error == 'UNAUTHORIZED';

  factory DeviceRegisterResponse.fromJson(Map<String, dynamic> json) {
    return DeviceRegisterResponse(
      success: json['success'] ?? false,
      message: json['message'] ?? '',
      error: json['error'],
      data: json['data'] != null ? DeviceData.fromJson(json['data']) : null,
    );
  }

  Map<String, dynamic> toJson() => {
        'success': success,
        'message': message,
        'error': error,
        'data': data?.toJson(),
      };
}

/// 기기 데이터 모델
class DeviceData {
  final int deviceId;
  final String remoteId;
  final String alias;
  final String registeredAt;

  DeviceData({
    required this.deviceId,
    required this.remoteId,
    required this.alias,
    required this.registeredAt,
  });

  factory DeviceData.fromJson(Map<String, dynamic> json) {
    return DeviceData(
      deviceId: json['device_id'] ?? 0,
      remoteId: json['remote_id'] ?? '',
      alias: json['alias'] ?? '',
      registeredAt: json['registered_at'] ?? '',
    );
  }

  Map<String, dynamic> toJson() => {
        'device_id': deviceId,
        'remote_id': remoteId,
        'alias': alias,
        'registered_at': registeredAt,
      };
}

/// 등록된 기기 모델
class RegisteredDevice {
  final int deviceId;
  final String remoteId;
  final String alias;
  final String hostname;
  final String platform;
  final bool isOnline;
  final String? lastOnlineAt;
  final String registeredAt;

  RegisteredDevice({
    required this.deviceId,
    required this.remoteId,
    required this.alias,
    required this.hostname,
    required this.platform,
    required this.isOnline,
    this.lastOnlineAt,
    required this.registeredAt,
  });

  factory RegisteredDevice.fromJson(Map<String, dynamic> json) {
    return RegisteredDevice(
      deviceId: json['device_id'] ?? 0,
      remoteId: json['remote_id'] ?? '',
      alias: json['alias'] ?? '',
      hostname: json['hostname'] ?? '',
      platform: json['platform'] ?? '',
      // API 응답에서 is_active 또는 is_online 필드 지원
      isOnline: json['is_active'] ?? json['is_online'] ?? false,
      lastOnlineAt: json['last_online_at'] ?? json['updated_at'],
      registeredAt: json['registered_at'] ?? '',
    );
  }

  Map<String, dynamic> toJson() => {
        'device_id': deviceId,
        'remote_id': remoteId,
        'alias': alias,
        'hostname': hostname,
        'platform': platform,
        'is_online': isOnline,
        'last_online_at': lastOnlineAt,
        'registered_at': registeredAt,
      };
}

/// 기기 목록 응답 모델
class DeviceListResponse {
  final bool success;
  final String message;
  final String? error;
  final List<RegisteredDevice> data;
  final int? statusCode;  // HTTP 상태 코드

  DeviceListResponse({
    required this.success,
    required this.message,
    this.error,
    required this.data,
    this.statusCode,
  });
  
  /// 401 Unauthorized 응답인지 확인
  bool get isUnauthorized => statusCode == 401 || error == 'UNAUTHORIZED';

  factory DeviceListResponse.fromJson(Map<String, dynamic> json) {
    List<RegisteredDevice> devices = [];
    if (json['data'] != null) {
      devices = (json['data'] as List)
          .map((item) => RegisteredDevice.fromJson(item))
          .toList();
    }
    return DeviceListResponse(
      success: json['success'] ?? false,
      message: json['message'] ?? '',
      error: json['error'],
      data: devices,
    );
  }
}

/// 기기 등록 서비스
/// 
/// HTTP를 통해 API 서버와 통신하여 기기 등록/해제/조회를 수행합니다.
class DeviceRegisterService {
  static DeviceRegisterService? _instance;
  DeviceRegisterService._();

  static DeviceRegisterService get instance {
    _instance ??= DeviceRegisterService._();
    return _instance!;
  }

  /// 원격 기기를 API 서버에 등록
  /// 
  /// HTTP를 통해 기기 등록 요청을 보냅니다.
  /// [apiServer] - API 서버 주소
  /// [accessToken] - 인증 토큰
  /// [userId] - 로그인된 유저 ID (username)
  /// [userPkid] - 유저 고유 번호
  /// [remoteId] - 원격 ID (peer ID)
  /// [alias] - 사용자 지정 별칭
  /// [hostname] - 호스트명 (선택)
  /// [platform] - 플랫폼 (선택)
  Future<DeviceRegisterResponse> registerDevice({
    required String apiServer,
    required String accessToken,
    required String userId,
    required String userPkid,
    required String remoteId,
    required String alias,
    String? hostname,
    String? platform,
  }) async {
    try {
      debugPrint('DeviceRegisterService: Registering device - remoteId=$remoteId, alias=$alias');
      
      final url = Uri.parse('$apiServer/api/device/register');
      
      final body = jsonEncode({
        'user_id': userId,
        'user_pkid': userPkid,
        'remote_id': remoteId,
        'alias': alias,
        'hostname': hostname ?? '',
        'platform': platform ?? '',
      });

      final response = await http.post(
        url,
        headers: {
          'Content-Type': 'application/json',
          'Authorization': 'Bearer $accessToken',
        },
        body: body,
      );

      debugPrint('DeviceRegisterService: Register response - ${response.statusCode}');

      // 401 응답 처리 (토큰 무효화)
      if (response.statusCode == 401) {
        return DeviceRegisterResponse(
          success: false,
          message: '인증이 만료되었습니다. 다시 로그인해주세요.',
          error: 'UNAUTHORIZED',
          statusCode: 401,
        );
      }

      if (response.statusCode == 200 || response.statusCode == 201) {
        final Map<String, dynamic> result = jsonDecode(response.body);
        return DeviceRegisterResponse.fromJson(result);
      } else {
        return DeviceRegisterResponse(
          success: false,
          message: 'HTTP Error: ${response.statusCode}',
          error: 'HTTP_ERROR',
          statusCode: response.statusCode,
        );
      }
    } catch (e) {
      debugPrint('DeviceRegisterService: Error registering device - $e');
      return DeviceRegisterResponse(
        success: false,
        message: 'Failed to register device: $e',
        error: 'HTTP_ERROR',
      );
    }
  }

  /// 기기 등록 해제
  /// 
  /// HTTP를 통해 기기 등록 해제 요청을 보냅니다.
  Future<DeviceRegisterResponse> unregisterDevice({
    required String apiServer,
    required String accessToken,
    required String userPkid,
    required String remoteId,
  }) async {
    try {
      debugPrint('DeviceRegisterService: Unregistering device - remoteId=$remoteId');
      
      final url = Uri.parse('$apiServer/api/device/unregister');
      
      final body = jsonEncode({
        'user_pkid': userPkid,
        'remote_id': remoteId,
      });

      final response = await http.post(
        url,
        headers: {
          'Content-Type': 'application/json',
          'Authorization': 'Bearer $accessToken',
        },
        body: body,
      );

      debugPrint('DeviceRegisterService: Unregister response - ${response.statusCode}');

      // 401 응답 처리 (토큰 무효화)
      if (response.statusCode == 401) {
        return DeviceRegisterResponse(
          success: false,
          message: '인증이 만료되었습니다. 다시 로그인해주세요.',
          error: 'UNAUTHORIZED',
          statusCode: 401,
        );
      }

      if (response.statusCode == 200 || response.statusCode == 201) {
        final Map<String, dynamic> result = jsonDecode(response.body);
        return DeviceRegisterResponse.fromJson(result);
      } else {
        return DeviceRegisterResponse(
          success: false,
          message: 'HTTP Error: ${response.statusCode}',
          error: 'HTTP_ERROR',
          statusCode: response.statusCode,
        );
      }
    } catch (e) {
      debugPrint('DeviceRegisterService: Error unregistering device - $e');
      return DeviceRegisterResponse(
        success: false,
        message: 'Failed to unregister device: $e',
        error: 'HTTP_ERROR',
      );
    }
  }

  /// 등록된 기기 목록 조회
  /// 
  /// HTTP를 통해 등록된 기기 목록을 조회합니다.
  Future<DeviceListResponse> getRegisteredDevices({
    required String apiServer,
    required String accessToken,
    required String userPkid,
  }) async {
    try {
      debugPrint('========== DeviceRegisterService: getRegisteredDevices ==========');
      debugPrint('  apiServer: $apiServer');
      debugPrint('  userPkid: $userPkid');
      debugPrint('  accessToken: ${accessToken.isNotEmpty ? "${accessToken.substring(0, 20)}..." : "EMPTY"}');
      
      final url = Uri.parse('$apiServer/api/device/list?user_pkid=$userPkid');
      debugPrint('  Request URL: $url');

      final response = await http.get(
        url,
        headers: {
          'Content-Type': 'application/json',
          'Authorization': 'Bearer $accessToken',
        },
      );

      debugPrint('  Response Status: ${response.statusCode}');
      debugPrint('  Response Body: ${response.body}');

      // 401 응답 처리 (토큰 무효화)
      if (response.statusCode == 401) {
        debugPrint('  ❌ 401 Unauthorized - Token expired');
        return DeviceListResponse(
          success: false,
          message: '인증이 만료되었습니다. 다시 로그인해주세요.',
          error: 'UNAUTHORIZED',
          data: [],
          statusCode: 401,
        );
      }

      if (response.statusCode == 200) {
        final Map<String, dynamic> result = jsonDecode(response.body);
        debugPrint('  Parsed JSON keys: ${result.keys.toList()}');
        debugPrint('  success: ${result['success']}');
        debugPrint('  message: ${result['message']}');
        
        final dataList = result['data'];
        if (dataList is List) {
          debugPrint('  data count: ${dataList.length}');
          for (int i = 0; i < dataList.length && i < 5; i++) {
            final device = dataList[i];
            debugPrint('  Device[$i]: remote_id=${device['remote_id']}, alias=${device['alias']}, hostname=${device['hostname']}, is_online=${device['is_online']}');
          }
          if (dataList.length > 5) {
            debugPrint('  ... and ${dataList.length - 5} more devices');
          }
        } else {
          debugPrint('  data is not a List: ${dataList.runtimeType}');
        }
        
        final deviceListResponse = DeviceListResponse.fromJson(result);
        debugPrint('  ✅ Parsed ${deviceListResponse.data.length} devices successfully');
        debugPrint('=================================================================');
        return deviceListResponse;
      } else {
        debugPrint('  ❌ HTTP Error: ${response.statusCode}');
        debugPrint('=================================================================');
        return DeviceListResponse(
          success: false,
          message: 'HTTP Error: ${response.statusCode}',
          error: 'HTTP_ERROR',
          data: [],
          statusCode: response.statusCode,
        );
      }
    } catch (e, stackTrace) {
      debugPrint('  ❌ Exception: $e');
      debugPrint('  StackTrace: $stackTrace');
      debugPrint('=================================================================');
      return DeviceListResponse(
        success: false,
        message: 'Failed to get registered devices: $e',
        error: 'HTTP_ERROR',
        data: [],
      );
    }
  }
}

/// 최근 세션 모델
class RecentSession {
  final String peerId;      // 대상 ID
  final String alias;       // 대상 별칭
  final String hostname;    // 대상 호스트명
  final String connStart;   // 연결 시작 시간
  final String connEnd;     // 연결 종료 시간
  final String duration;    // 연결 시간
  final String sessionId;   // 세션 ID

  RecentSession({
    required this.peerId,
    required this.alias,
    required this.hostname,
    required this.connStart,
    required this.connEnd,
    required this.duration,
    required this.sessionId,
  });

  factory RecentSession.fromJson(Map<String, dynamic> json) {
    return RecentSession(
      peerId: json['id']?.toString() ?? '',
      alias: json['alias']?.toString() ?? '',
      hostname: json['hostname']?.toString() ?? '',
      connStart: json['conn_start'] ?? '',
      connEnd: json['conn_end'] ?? '',
      duration: json['duration'] ?? '',
      sessionId: json['session_id']?.toString() ?? '',
    );
  }
  
  /// 표시 이름 (alias > hostname > id 순)
  String get displayName {
    if (alias.isNotEmpty) return alias;
    if (hostname.isNotEmpty) return hostname;
    return peerId;
  }
}

/// 최근 세션 응답 모델
class RecentSessionResponse {
  final bool success;
  final int count;
  final List<RecentSession> data;
  final String? error;
  final int? statusCode;

  RecentSessionResponse({
    required this.success,
    required this.count,
    required this.data,
    this.error,
    this.statusCode,
  });

  bool get isUnauthorized => statusCode == 401 || error == 'UNAUTHORIZED';
}

/// 최근 세션 서비스
class RecentSessionService {
  static final RecentSessionService _instance = RecentSessionService._internal();
  static RecentSessionService get instance => _instance;
  
  RecentSessionService._internal();

  /// 최근 세션 목록 조회
  Future<RecentSessionResponse> getRecentSessions({
    required String apiServer,
    required String accessToken,
    required String userId,
    int limit = 5,
  }) async {
    try {
      // HTTP에서 HTTPS로 변환
      String baseUrl = apiServer;
      if (baseUrl.startsWith('http://')) {
        baseUrl = baseUrl.replaceFirst('http://', 'https://');
      }
      
      final url = '$baseUrl/api/sessions/recent?user_id=$userId&limit=$limit';
      
      debugPrint('========== RecentSessionService: getRecentSessions ==========');
      debugPrint('  Request URL: $url');
      debugPrint('  userId: $userId');
      debugPrint('  limit: $limit');
      
      final response = await http.get(
        Uri.parse(url),
        headers: {
          'Authorization': 'Bearer $accessToken',
          'Content-Type': 'application/json',
        },
      );
      
      debugPrint('  Response Status: ${response.statusCode}');
      
      if (response.statusCode == 401) {
        debugPrint('  ❌ 401 Unauthorized');
        return RecentSessionResponse(
          success: false,
          count: 0,
          data: [],
          error: 'UNAUTHORIZED',
          statusCode: 401,
        );
      }
      
      if (response.statusCode == 200) {
        final json = jsonDecode(response.body);
        debugPrint('  Response Body: ${response.body}');
        
        final code = json['code'] ?? 0;
        final count = json['count'] ?? 0;
        final dataList = json['data'] as List<dynamic>? ?? [];
        
        final sessions = dataList.map((item) => RecentSession.fromJson(item)).toList();
        
        debugPrint('  ✅ Parsed $count sessions successfully');
        debugPrint('=================================================================');
        
        return RecentSessionResponse(
          success: code == 1,
          count: count,
          data: sessions,
          statusCode: 200,
        );
      } else {
        debugPrint('  ❌ HTTP Error: ${response.statusCode}');
        return RecentSessionResponse(
          success: false,
          count: 0,
          data: [],
          error: 'HTTP_ERROR',
          statusCode: response.statusCode,
        );
      }
    } catch (e) {
      debugPrint('  ❌ Exception: $e');
      debugPrint('=================================================================');
      return RecentSessionResponse(
        success: false,
        count: 0,
        data: [],
        error: e.toString(),
      );
    }
  }
}

/// 글로벌 인스턴스
final deviceRegisterService = DeviceRegisterService.instance;
final recentSessionService = RecentSessionService.instance;
