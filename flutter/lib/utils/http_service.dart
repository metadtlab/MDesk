import 'dart:convert';
import 'dart:io';
import 'package:flutter/foundation.dart';
import 'package:flutter_hbb/consts.dart';
import 'package:http/http.dart' as http;
import '../models/platform_model.dart';
import 'package:flutter_hbb/common.dart';
export 'package:http/http.dart' show Response;

enum HttpMethod { get, post, put, delete }

class HttpService {
  Future<http.Response> sendRequest(
    Uri url,
    HttpMethod method, {
    Map<String, String>? headers,
    dynamic body,
  }) async {
    headers ??= {'Content-Type': 'application/json'};

    // Use Rust HTTP implementation for non-web platforms for consistency.
    var useFlutterHttp = (isWeb || kIsWeb);
    if (!useFlutterHttp) {
      final enableFlutterHttpOnRust =
          mainGetLocalBoolOptionSync(kOptionEnableFlutterHttpOnRust);
      // Use flutter http if:
      // Not `enableFlutterHttpOnRust` and no proxy is set
      useFlutterHttp =
          !(enableFlutterHttpOnRust || await bind.mainGetProxyStatus());
    }

    if (useFlutterHttp) {
      return await _pollFlutterHttp(url, method, headers: headers, body: body);
    }

    String headersJson = jsonEncode(headers);
    String methodName = method.toString().split('.').last;
    await bind.mainHttpRequest(
        url: url.toString(),
        method: methodName.toLowerCase(),
        body: body,
        header: headersJson);

    var resJson = await _pollForResponse(url.toString());
    return _parseHttpResponse(resJson);
  }

  // SSL 인증서 검증 우회 HttpClient 생성
  HttpClient _createSecureHttpClient() {
    return HttpClient()
      ..badCertificateCallback = (X509Certificate cert, String host, int port) {
        debugPrint('HttpService SSL BadCertificate callback - host=$host, port=$port');
        return true; // 모든 인증서 허용
      };
  }

  Future<http.Response> _pollFlutterHttp(
    Uri url,
    HttpMethod method, {
    Map<String, String>? headers,
    dynamic body,
  }) async {
    // SSL 우회 HttpClient 사용
    final httpClient = _createSecureHttpClient();
    
    try {
      HttpClientRequest request;
      
      switch (method) {
        case HttpMethod.get:
          request = await httpClient.getUrl(url);
          break;
        case HttpMethod.post:
          request = await httpClient.postUrl(url);
          break;
        case HttpMethod.put:
          request = await httpClient.putUrl(url);
          break;
        case HttpMethod.delete:
          request = await httpClient.deleteUrl(url);
          break;
        default:
          throw Exception('Unsupported HTTP method');
      }
      
      // 헤더 설정
      if (headers != null) {
        headers.forEach((key, value) => request.headers.set(key, value));
      }
      
      // body 설정 (POST, PUT, DELETE)
      if (body != null && method != HttpMethod.get) {
        if (body is String) {
          request.write(body);
        } else if (body is Map) {
          request.write(jsonEncode(body));
        } else {
          request.write(body.toString());
        }
      }
      
      final response = await request.close();
      final responseBody = await response.transform(utf8.decoder).join();
      
      // http.Response로 변환하여 반환
      return http.Response(responseBody, response.statusCode);
    } finally {
      httpClient.close();
    }
  }

  Future<String> _pollForResponse(String url) async {
    String? responseJson = " ";
    while (responseJson == " ") {
      responseJson = await bind.mainGetHttpStatus(url: url);
      if (responseJson == null) {
        throw Exception('The HTTP request failed');
      }
      if (responseJson == " ") {
        await Future.delayed(const Duration(milliseconds: 100));
      }
    }
    return responseJson!;
  }

  http.Response _parseHttpResponse(String responseJson) {
    try {
      var parsedJson = jsonDecode(responseJson);
      String body = parsedJson['body'];
      Map<String, String> headers = {};
      for (var key in parsedJson['headers'].keys) {
        headers[key] = parsedJson['headers'][key];
      }
      int statusCode = parsedJson['status_code'];
      return http.Response(body, statusCode, headers: headers);
    } catch (e) {
      print('Failed to parse response\n$responseJson\nError:\n$e');
      throw Exception('Failed to parse response.\n$responseJson');
    }
  }
}

Future<http.Response> get(Uri url, {Map<String, String>? headers}) async {
  return await HttpService().sendRequest(url, HttpMethod.get, headers: headers);
}

Future<http.Response> post(Uri url,
    {Map<String, String>? headers, Object? body, Encoding? encoding}) async {
  return await HttpService()
      .sendRequest(url, HttpMethod.post, body: body, headers: headers);
}

Future<http.Response> put(Uri url,
    {Map<String, String>? headers, Object? body, Encoding? encoding}) async {
  return await HttpService()
      .sendRequest(url, HttpMethod.put, body: body, headers: headers);
}

Future<http.Response> delete(Uri url,
    {Map<String, String>? headers, Object? body, Encoding? encoding}) async {
  return await HttpService()
      .sendRequest(url, HttpMethod.delete, body: body, headers: headers);
}
