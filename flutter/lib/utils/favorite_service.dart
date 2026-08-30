import 'dart:convert';
import 'package:flutter/foundation.dart';
import 'package:flutter_hbb/models/peer_model.dart';
import 'package:flutter_hbb/utils/http_service.dart' as http;

/// 즐겨찾기 모델
class FavoriteItem {
  final String peerId;
  final String? displayName;
  final String? username;
  final String? hostname;
  final String? platform;
  final String? memo;

  FavoriteItem({
    required this.peerId,
    this.displayName,
    this.username,
    this.hostname,
    this.platform,
    this.memo,
  });

  factory FavoriteItem.fromJson(Map<String, dynamic> json) {
    return FavoriteItem(
      peerId: json['peer_id']?.toString() ?? json['id']?.toString() ?? '',
      displayName: json['display_name']?.toString(),
      username: json['username']?.toString(),
      hostname: json['hostname']?.toString(),
      platform: json['platform']?.toString(),
      memo: json['memo']?.toString(),
    );
  }
}

/// 즐겨찾기 응답 모델
class FavoriteResponse {
  final bool success;
  final List<FavoriteItem> data;
  final String? error;
  final int? statusCode;

  FavoriteResponse({
    required this.success,
    required this.data,
    this.error,
    this.statusCode,
  });

  bool get isUnauthorized => statusCode == 401 || error == 'UNAUTHORIZED';
}

/// 즐겨찾기 서비스 (로그인 사용자 전용, 서버 API 연동)
class FavoriteService {
  static final FavoriteService _instance = FavoriteService._internal();
  static FavoriteService get instance => _instance;

  FavoriteService._internal();

  /// FavoriteItem을 Peer 모델로 변환
  Peer favoriteToPeer(FavoriteItem fav) {
    return Peer(
      id: fav.peerId,
      hash: '',
      password: '',
      username: fav.username ?? '',
      hostname: fav.hostname ?? '',
      platform: fav.platform ?? '',
      alias: fav.displayName ?? '',
      tags: [],
      forceAlwaysRelay: false,
      rdpPort: '',
      rdpUsername: '',
      loginName: '',
      device_group_name: '',
      note: fav.memo ?? '',
    );
  }

  /// 즐겨찾기 목록 조회 (로그인 사용자 전용)
  Future<FavoriteResponse> getFavorites({
    required String apiServer,
    required String accessToken,
  }) async {
    try {
      String baseUrl = apiServer;
      if (baseUrl.startsWith('http://')) {
        baseUrl = baseUrl.replaceFirst('http://', 'https://');
      }

      final url = '$baseUrl/api/favorites';
      debugPrint('FavoriteService: getFavorites $url');

      final response = await http.get(
        Uri.parse(url),
        headers: {
          'Authorization': 'Bearer $accessToken',
          'Content-Type': 'application/json',
        },
      );

      if (response.statusCode == 401) {
        return FavoriteResponse(
          success: false,
          data: [],
          error: 'UNAUTHORIZED',
          statusCode: 401,
        );
      }

      if (response.statusCode == 200) {
        final jsonData = jsonDecode(response.body);
        final code = jsonData['code'] ?? 0;
        final dataList = jsonData['data'] as List<dynamic>? ?? [];
        final items = dataList
            .map((e) => FavoriteItem.fromJson(e as Map<String, dynamic>))
            .toList();

        return FavoriteResponse(
          success: code == 1,
          data: items,
          statusCode: 200,
        );
      }

      return FavoriteResponse(
        success: false,
        data: [],
        error: 'HTTP ${response.statusCode}',
        statusCode: response.statusCode,
      );
    } catch (e) {
      debugPrint('FavoriteService: getFavorites error - $e');
      return FavoriteResponse(
        success: false,
        data: [],
        error: e.toString(),
      );
    }
  }

  /// 즐겨찾기 추가
  Future<FavoriteResponse> addFavorite({
    required String apiServer,
    required String accessToken,
    required String peerId,
    String? displayName,
  }) async {
    try {
      String baseUrl = apiServer;
      if (baseUrl.startsWith('http://')) {
        baseUrl = baseUrl.replaceFirst('http://', 'https://');
      }

      final url = '$baseUrl/api/favorites';
      final body = jsonEncode({
        'peer_id': peerId,
        if (displayName != null && displayName.isNotEmpty)
          'display_name': displayName,
      });

      debugPrint('FavoriteService: addFavorite $peerId');

      final response = await http.post(
        Uri.parse(url),
        headers: {
          'Authorization': 'Bearer $accessToken',
          'Content-Type': 'application/json',
        },
        body: body,
      );

      if (response.statusCode == 401) {
        return FavoriteResponse(
          success: false,
          data: [],
          error: 'UNAUTHORIZED',
          statusCode: 401,
        );
      }

      if (response.statusCode == 200 || response.statusCode == 201) {
        final jsonData = jsonDecode(response.body);
        final code = jsonData['code'] ?? 0;
        return FavoriteResponse(
          success: code == 1,
          data: [],
          statusCode: response.statusCode,
        );
      }

      return FavoriteResponse(
        success: false,
        data: [],
        error: 'HTTP ${response.statusCode}',
        statusCode: response.statusCode,
      );
    } catch (e) {
      debugPrint('FavoriteService: addFavorite error - $e');
      return FavoriteResponse(
        success: false,
        data: [],
        error: e.toString(),
      );
    }
  }

  /// 즐겨찾기 삭제
  Future<FavoriteResponse> removeFavorite({
    required String apiServer,
    required String accessToken,
    required String peerId,
  }) async {
    try {
      String baseUrl = apiServer;
      if (baseUrl.startsWith('http://')) {
        baseUrl = baseUrl.replaceFirst('http://', 'https://');
      }

      final url = '$baseUrl/api/favorites/$peerId';
      debugPrint('FavoriteService: removeFavorite $peerId');

      final response = await http.delete(
        Uri.parse(url),
        headers: {
          'Authorization': 'Bearer $accessToken',
          'Content-Type': 'application/json',
        },
      );

      if (response.statusCode == 401) {
        return FavoriteResponse(
          success: false,
          data: [],
          error: 'UNAUTHORIZED',
          statusCode: 401,
        );
      }

      if (response.statusCode == 200 || response.statusCode == 204) {
        return FavoriteResponse(
          success: true,
          data: [],
          statusCode: response.statusCode,
        );
      }

      return FavoriteResponse(
        success: false,
        data: [],
        error: 'HTTP ${response.statusCode}',
        statusCode: response.statusCode,
      );
    } catch (e) {
      debugPrint('FavoriteService: removeFavorite error - $e');
      return FavoriteResponse(
        success: false,
        data: [],
        error: e.toString(),
      );
    }
  }

  /// API 응답을 Peer 목록으로 변환
  List<Peer> favoritesToPeers(List<FavoriteItem> items) {
    return items.map((f) => favoriteToPeer(f)).toList();
  }
}

final favoriteService = FavoriteService.instance;
