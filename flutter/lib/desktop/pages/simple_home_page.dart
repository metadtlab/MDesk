import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_hbb/desktop/pages/desktop_home_page.dart';
import 'package:flutter_hbb/models/platform_model.dart';
import 'package:flutter_hbb/models/server_model.dart';
import 'package:flutter_hbb/common/formatter/id_formatter.dart';
import 'package:provider/provider.dart';
import 'package:window_manager/window_manager.dart';
import 'package:http/http.dart' as http;
import '../../common.dart';
import '../../models/model.dart';

class SimpleHomePage extends StatefulWidget {
  @override
  _SimpleHomePageState createState() => _SimpleHomePageState();
}

class _SimpleHomePageState extends State<SimpleHomePage> with WindowListener {
  Timer? _updateTimer;
  bool _agentUpdateCalled = false;
  String _userId = 'admin';
  String _agentId = '';
  bool _isClientConnected = false;  // 클라이언트 연결 상태 추적
  bool _certNoEnabled = false;  // 인증번호 입력창 활성화 여부
  final TextEditingController _certNoController = TextEditingController();  // 인증번호 입력 컨트롤러
  bool _isCertNoVerified = false;  // 인증번호 확인 상태

  // 파일명에서 ID, AgentID, CertNo 파싱하는 함수
  Map<String, String> _parseFilename() {
    String filename = '';
    try {
      // 1. 포터블 패커가 제공하는 환경변수 우선 확인 (MDESK_APPNAME 우선)
      filename = Platform.environment['MDESK_APPNAME'] ?? 
                 Platform.environment['RUSTDESK_APPNAME'] ?? '';
      
      // 2. 환경변수가 없으면 현재 실행 파일명 확인
      if (filename.isEmpty) {
        filename = Platform.resolvedExecutable.split(Platform.isWindows ? '\\' : '/').last;
      }
      
      debugPrint('MDesk Parser: Raw filename = "$filename"');
      
      // 확장자 제거 및 소문자 변환
      String s = filename.toLowerCase();
      if (s.endsWith('.exe')) s = s.substring(0, s.length - 4);
      
      // "-"를 ","로 변환하여 파싱 용이하게 함
      List<String> parts = s.replaceAll('-', ',').split(',');
      
      String id = '';
      String agentid = '';
      String certno = '';
      
      for (var part in parts) {
        if (part.startsWith('agentid=')) {
          // "agentid=18 (1)" 형태에서 숫자 부분만 추출
          String val = part.substring(8).trim();
          agentid = val.split(RegExp(r'[^0-9]')).first;
        } else if (part.startsWith('id=')) {
          // "id=admin (1)" 형태에서 공백 전까지만 추출
          String val = part.substring(3).trim();
          id = val.split(' ').first;
        } else if (part.startsWith('certno=')) {
          // "certno=true" 형태 파싱
          String val = part.substring(7).trim();
          certno = val.split(' ').first;
        }
      }
      
      return {'id': id, 'agentid': agentid, 'certno': certno};
    } catch (e) {
      debugPrint('MDesk Parser Error: $e');
      return {'id': '', 'agentid': '', 'certno': ''};
    }
  }

  @override
  void initState() {
    super.initState();
    windowManager.addListener(this);
    
    // 앱 시작 시 유저 정보 및 멤버십 정보 리프레쉬
    WidgetsBinding.instance.addPostFrameCallback((_) {
      gFFI.userModel.refreshCurrentUser();
      // 강제 업데이트 체크 후 다이얼로그 표시
      checkAndShowForceUpdateDialog(context);
    });

    _updateTimer = Timer.periodic(const Duration(seconds: 1), (timer) async {
      await gFFI.serverModel.fetchID();
      if (mounted) setState(() {});
      
      // RustDesk ID가 준비되면 실행 (한 번만)
      if (!_agentUpdateCalled) {
        final mdeskId = gFFI.serverModel.serverId.text;
        debugPrint('MDesk Timer: mdeskId="$mdeskId", isEmpty=${mdeskId.isEmpty}, contains...=${mdeskId.contains('...')}');
        
        // ID가 숫자로만 구성되어 있는지 추가 검증
        final cleanId = mdeskId.replaceAll(' ', '');
        final isValidId = cleanId.isNotEmpty && 
                          !mdeskId.contains('...') && 
                          RegExp(r'^\d+$').hasMatch(cleanId) &&
                          cleanId.length >= 9;  // 최소 9자리 숫자
        
        debugPrint('MDesk Timer: cleanId="$cleanId", isValidId=$isValidId');
        
        if (isValidId) {
          _agentUpdateCalled = true;
          
          // 파일명 직접 파싱
          final params = _parseFilename();
          final parsedId = params['id'] ?? '';
          final parsedAgentId = params['agentid'] ?? '';
          final parsedCertNo = params['certno'] ?? '';
          
          // certno=true 이면 인증번호 입력창 활성화 및 id 무시
          _certNoEnabled = parsedCertNo.toLowerCase() == 'true';
          debugPrint('MDesk: certno enabled = $_certNoEnabled');
          
          // 최종적으로 사용할 값 결정
          // certno=true 이면 id 값을 무시하고 'cert'로 설정 (인증번호로 누구나 접속 가능)
          if (_certNoEnabled) {
            _userId = 'cert';  // 인증번호 모드에서는 id를 무시하고 'cert' 사용
            _agentId = '';     // agentId도 사용하지 않음 (인증번호로 관리)
            debugPrint('MDesk: certno=true -> ignoring id="${parsedId}", using _userId="cert"');
          } else {
            _userId = parsedId.isNotEmpty ? parsedId : 'admin';
            _agentId = parsedAgentId;
          }
          
          // 옵션에 저장 (다른 모듈에서 사용할 수 있도록)
          bind.mainSetOption(key: 'custom-id', value: _userId);
          bind.mainSetOption(key: 'custom-agentid', value: _agentId);
          bind.mainSetOption(key: 'custom-certno', value: _certNoEnabled ? 'true' : 'false');
          
          debugPrint('MDesk: Parsed from filename -> id=$_userId, agentid=$_agentId, mdeskId=$cleanId');
          
          // 1. 커스텀 설정(로고 등) 가져오기 (완료 대기)
          debugPrint('MDesk: Step 1 - Fetching custom config for $_userId...');
          await gFFI.serverModel.fetchCustomConfig(_userId);
          
          // 2. agentid가 있다면 상담원 등록 API 호출
          if (_agentId.isNotEmpty) {
            await _callAgentNumUpdateAPI(cleanId);
          }
          
          // 디바이스 등록은 "원격자 등록" 다이얼로그에서만 수행
          // (프로그램 시작 시 자동 등록 제거)
          

          if (mounted) setState(() {});
          
          // 3. 결과 메시지 박스 표시 (실제 파싱된 값 확인용)
          /*
          if (mounted) {
            showDialog(
              context: context,
              builder: (ctx) => AlertDialog(
                title: const Text('MDesk 실시간 파싱 결과'),
                content: Text(
                  '=== 파일명 파싱 ===\n'
                  '환경변수: ${Platform.environment['RUSTDESK_APPNAME'] ?? "없음"}\n'
                  '실제파일명: ${Platform.resolvedExecutable.split(Platform.isWindows ? '\\' : '/').last}\n'
                  '추출 ID: "$finalUserId"\n'
                  '추출 AgentID: "$finalAgentId"\n\n'
                  '=== API 결과 ===\n'
                  '$agentUpdateResult'
                ),
                actions: [
                  TextButton(
                    onPressed: () => Navigator.of(ctx).pop(),
                    child: const Text('OK'),
                  ),
                ],
              ),
            );
          }
          */
        }
      }
      
      // 클라이언트 연결 상태 모니터링 (원격 연결 감지)
      if (_agentId.isNotEmpty) {
        final clients = gFFI.serverModel.clients;
        
        // 디버그: 클라이언트 목록 출력 (5초마다)
        if (DateTime.now().second % 5 == 0) {
          debugPrint('MDesk Monitor: clients.length=${clients.length}, _isClientConnected=$_isClientConnected');
          for (var c in clients) {
            debugPrint('  - Client: id=${c.id}, peerId=${c.peerId}, authorized=${c.authorized}, disconnected=${c.disconnected}');
          }
        }
        
        final hasConnectedClient = clients.any((c) => c.authorized && !c.disconnected);
        
        if (hasConnectedClient && !_isClientConnected) {
          // 새로운 연결 감지 → agentclose API 호출 (상담원 "통화 중" 상태)
          _isClientConnected = true;
          debugPrint('MDesk: Client connected! Calling agentclose API...');
          _callAgentCloseAPI();
        } else if (!hasConnectedClient && _isClientConnected) {
          // 연결 해제 감지 → 상태 초기화 (다음 연결을 위해)
          _isClientConnected = false;
          debugPrint('MDesk: Client disconnected, ready for next connection');
        }
      }
    });
  }

  // agentnumupdate API 호출 함수
  Future<void> _callAgentNumUpdateAPI(String mdeskId) async {
    debugPrint('=== AgentNumUpdate START ===');
    debugPrint('AgentNumUpdate: mdeskId=$mdeskId');
    debugPrint('AgentNumUpdate: _userId=$_userId');
    debugPrint('AgentNumUpdate: _agentId=$_agentId');
    
    if (_agentId.isEmpty) {
      debugPrint('AgentNumUpdate: SKIP - agentid is empty');
      debugPrint('=== AgentNumUpdate END (skipped) ===');
      return;
    }
    
    final url = 'https://787.kr/api/agentnumupdate/$_userId/$mdeskId?agentid=$_agentId';
    debugPrint('AgentNumUpdate: URL=$url');
    
    // 최대 3번 재시도
    for (int attempt = 1; attempt <= 3; attempt++) {
      debugPrint('AgentNumUpdate: Attempt $attempt/3');
      
      try {
        debugPrint('AgentNumUpdate: Sending HTTP GET request...');
        
        final stopwatch = Stopwatch()..start();
        
        // SSL 인증서 검증을 우회하는 HttpClient 사용
        final httpClient = HttpClient()
          ..badCertificateCallback = (X509Certificate cert, String host, int port) {
            debugPrint('AgentNumUpdate: BadCertificate callback - host=$host, port=$port');
            return true; // 모든 인증서 허용
          };
        
        final request = await httpClient.getUrl(Uri.parse(url));
        final response = await request.close().timeout(const Duration(seconds: 10));
        final responseBody = await response.transform(utf8.decoder).join();
        stopwatch.stop();
        
        debugPrint('AgentNumUpdate: Response received in ${stopwatch.elapsedMilliseconds}ms');
        debugPrint('AgentNumUpdate: StatusCode=${response.statusCode}');
        debugPrint('AgentNumUpdate: Body=$responseBody');
        
        httpClient.close();
        
        if (mounted) {
          if (response.statusCode == 200) {
            debugPrint('AgentNumUpdate: SUCCESS');
            showToast('상담원 정보가 업데이트되었습니다');
          } else {
            debugPrint('AgentNumUpdate: FAILED - StatusCode is not 200');
            showToast('상담원 정보 업데이트 실패: ${response.statusCode}');
          }
        }
        debugPrint('=== AgentNumUpdate END ===');
        return; // 성공 시 종료
        
      } on HandshakeException catch (e) {
        debugPrint('AgentNumUpdate: HANDSHAKE ERROR (attempt $attempt): $e');
        if (attempt == 3) {
          if (mounted) {
            showToast('상담원 정보 업데이트 중 SSL 오류 발생');
          }
        } else {
          await Future.delayed(Duration(seconds: attempt)); // 재시도 전 대기
        }
      } on TimeoutException catch (e) {
        debugPrint('AgentNumUpdate: TIMEOUT ERROR (attempt $attempt): $e');
        if (attempt == 3) {
          if (mounted) {
            showToast('상담원 정보 업데이트 중 타임아웃 발생');
          }
        }
      } on SocketException catch (e) {
        debugPrint('AgentNumUpdate: SOCKET ERROR (attempt $attempt): $e');
        debugPrint('AgentNumUpdate: Socket message=${e.message}');
        if (attempt == 3) {
          if (mounted) {
            showToast('상담원 정보 업데이트 중 네트워크 오류 발생');
          }
        } else {
          await Future.delayed(Duration(seconds: attempt));
        }
      } catch (e, stackTrace) {
        debugPrint('AgentNumUpdate: ERROR (attempt $attempt): $e');
        debugPrint('AgentNumUpdate: Error type=${e.runtimeType}');
        debugPrint('AgentNumUpdate: StackTrace=$stackTrace');
        if (attempt == 3) {
          if (mounted) {
            showToast('상담원 정보 업데이트 중 오류 발생: ${e.runtimeType}');
          }
        }
      }
    }
    debugPrint('=== AgentNumUpdate END (all attempts failed) ===');
  }

  // 디바이스 등록 API 호출 함수
  Future<void> _registerDevice(String mdeskId) async {
    debugPrint('=== MDesk Device Register START ===');
    debugPrint('MDesk Device Register: mdeskId=$mdeskId');
    
    try {
      // 필요한 정보 수집
      debugPrint('MDesk Device Register: Collecting device info...');
      final uuid = await bind.mainGetUuid();
      debugPrint('MDesk Device Register: uuid=$uuid');
      final version = await bind.mainGetVersion();
      debugPrint('MDesk Device Register: version=$version');
      final hostname = Platform.localHostname;
      debugPrint('MDesk Device Register: hostname=$hostname');
      
      final url = 'https://admin.787.kr/api/device/register';
      final body = {
        'remote_id': mdeskId,
        'custom_id': _userId,
        'agent_id': _agentId,
        'uuid': uuid,
        'version': version,
        'hostname': hostname,
      };
      
      debugPrint('MDesk Device Register: Calling API: $url');
      debugPrint('MDesk Device Register: Body: ${jsonEncode(body)}');
      
      final response = await http.post(
        Uri.parse(url),
        headers: {'Content-Type': 'application/json'},
        body: jsonEncode(body),
      ).timeout(const Duration(seconds: 10));
      
      debugPrint('MDesk Device Register: Response: ${response.statusCode} - ${response.body}');
      
      if (mounted && response.statusCode == 200) {
        debugPrint('MDesk Device Register: 디바이스 등록 성공!');
      } else {
        debugPrint('MDesk Device Register: 응답 코드가 200이 아님 - ${response.statusCode}');
      }
    } catch (e, stackTrace) {
      debugPrint('MDesk Device Register Error: $e');
      debugPrint('MDesk Device Register StackTrace: $stackTrace');
    }
    
    debugPrint('=== MDesk Device Register END ===');
  }

  // agentid가 있으면 agentnumupdate API 호출 (레거시 함수)
  Future<void> _callAgentNumUpdate(String mdeskId) async {
    final customId = bind.mainGetOptionSync(key: 'custom-id');
    final agentId = "112";//bind.mainGetOptionSync(key: 'custom-agentid');
    
    // RustDesk ID에서 공백 제거
    final cleanMdeskId = mdeskId.replaceAll(' ', '');
    
    debugPrint('MDesk AgentUpdate: custom-id="$customId", custom-agentid="$agentId", mdeskId="$cleanMdeskId"');
    
    // agentid가 없으면 스킵 (customId는 이미 "admin"으로 하드코딩됨)
    if (agentId.isEmpty) {
      debugPrint('MDesk AgentUpdate: agentid is empty, skip API call');
      return;
    }
    
    // customId가 없으면 파일명에서 파싱된 id 사용, 그것도 없으면 "admin" 기본값
    final username = customId.isNotEmpty ? customId : 'admin';

    try {
      final url = 'https://787.kr/api/agentnumupdate/$username/$cleanMdeskId?agentid=$agentId';
      debugPrint('MDesk AgentUpdate: Calling API: $url');
      
      final response = await http.get(Uri.parse(url)).timeout(const Duration(seconds: 10));
      
      debugPrint('MDesk AgentUpdate: Response: ${response.statusCode} - ${response.body}');
    } catch (e) {
      debugPrint('MDesk AgentUpdate: Error: $e');
    }
  }

  // 원격 연결 시 agentclose API 호출 (상담원 "통화 중" 상태)
  Future<void> _callAgentCloseAPI() async {
    if (_agentId.isEmpty) return;
    
    try {
      final url = 'https://787.kr/api/agentclose/$_userId/$_agentId';
      debugPrint('MDesk AgentClose (Connected): Calling API: $url');
      
      final response = await http.get(Uri.parse(url)).timeout(const Duration(seconds: 5));
      debugPrint('MDesk AgentClose (Connected): Response: ${response.statusCode} - ${response.body}');
    } catch (e) {
      debugPrint('MDesk AgentClose (Connected) Error: $e');
    }
  }

  // 인증번호 인증 성공 후 agentnumupdate API 호출 (agentid=0)
  Future<void> _callAgentNumUpdateWithCertNo(String mdeskId) async {
    try {
      final url = 'https://787.kr/api/agentnumupdate/$_userId/$mdeskId?agentid=0';
      debugPrint('MDesk CertNo AgentNumUpdate: Calling API: $url');
      
      final response = await http.get(Uri.parse(url)).timeout(const Duration(seconds: 10));
      debugPrint('MDesk CertNo AgentNumUpdate: Response: ${response.statusCode} - ${response.body}');
      
      if (response.statusCode == 200) {
        debugPrint('MDesk CertNo: Agent registered with agentid=0');
      }
    } catch (e) {
      debugPrint('MDesk CertNo AgentNumUpdate Error: $e');
    }
  }

  // 인증번호 확인 함수 - certno=true 모드에서는 인증번호만으로 검증
  Future<void> _verifyCertNo() async {
    final certNo = _certNoController.text.trim();
    if (certNo.isEmpty) {
      showToast('인증번호를 입력해주세요');
      return;
    }
    
    final mdeskId = gFFI.serverModel.serverId.text.replaceAll(' ', '');
    if (mdeskId.isEmpty || mdeskId.contains('...')) {
      showToast('ID가 준비되지 않았습니다');
      return;
    }
    
    try {
      // 1. 인증번호 검증 API 호출 (인증번호만으로 검증 - 특정 고객에 종속되지 않음)
      final verifyUrl = 'https://admin.787.kr/api/certno/verify';
      final verifyBody = jsonEncode({
        'cert_code': certNo,    // 인증번호 (예: 42847291)
        'peer_id': mdeskId,     // 피제어자 ID (원격 받는 쪽, 예: 143165320)
      });
      
      debugPrint('MDesk CertNo Verify: Calling API: $verifyUrl');
      debugPrint('MDesk CertNo Verify: Body: $verifyBody');
      
      final verifyResponse = await http.post(
        Uri.parse(verifyUrl),
        headers: {'Content-Type': 'application/json'},
        body: verifyBody,
      ).timeout(const Duration(seconds: 10));
      
      debugPrint('MDesk CertNo Verify: Response: ${verifyResponse.statusCode} - ${verifyResponse.body}');
      
      if (verifyResponse.statusCode == 200) {
        final responseData = jsonDecode(verifyResponse.body);
        final success = responseData['success'] == true;
        
        if (success) {
          // 응답에서 customer_id 추출 (서버가 반환한 값 사용)
          final customerId = responseData['customer_id']?.toString() ?? '';
          final verifiedMdeskId = responseData['mdesk_id']?.toString() ?? mdeskId;
          
          debugPrint('MDesk CertNo: Verified! customer_id=$customerId, mdesk_id=$verifiedMdeskId');
          
          if (customerId.isEmpty) {
            showToast('인증 실패: customer_id가 없습니다');
            return;
          }
          
          // 2. agentnumupdate API 호출 (응답받은 customer_id 사용)
          final agentUrl = 'https://787.kr/api/agentnumupdate/$customerId/$verifiedMdeskId?agentid=0';
          debugPrint('MDesk CertNo: Calling agentnumupdate API: $agentUrl');
          
          final agentResponse = await http.get(Uri.parse(agentUrl)).timeout(const Duration(seconds: 10));
          debugPrint('MDesk CertNo: agentnumupdate Response: ${agentResponse.statusCode} - ${agentResponse.body}');
          
          if (agentResponse.statusCode == 200) {
            setState(() {
              _isCertNoVerified = true;
              _agentId = '0';  // 인증 완료 시 agentid=0으로 설정
              _userId = customerId;  // 인증번호 소유자 ID로 업데이트
            });
            
            // 옵션에 저장 (다른 모듈에서 사용할 수 있도록)
            bind.mainSetOption(key: 'custom-id', value: customerId);
            bind.mainSetOption(key: 'custom-agentid', value: '0');
            
            // 3. 인증번호 소유자의 커스텀 설정(로고 등) 가져오기
            debugPrint('MDesk CertNo: Fetching custom config for $customerId...');
            await gFFI.serverModel.fetchCustomConfig(customerId);
            
            showToast('인증이 완료되었습니다');
            
            // 4. 인증번호 삭제 API 호출 (인증번호 소유자 ID로)
            await _deleteCertNo(certNo, customerId);
            
            if (mounted) setState(() {});  // UI 갱신
          } else {
            showToast('인증 실패: 서버 오류');
          }
        } else {
          // success: false
          final message = responseData['message']?.toString() ?? '인증번호가 유효하지 않습니다';
          showToast(message);
        }
      } else {
        // HTTP 에러
        showToast('인증번호가 유효하지 않습니다');
      }
    } catch (e) {
      debugPrint('MDesk CertNo Error: $e');
      showToast('인증 중 오류가 발생했습니다');
    }
  }
  
  // 인증번호 삭제 API 호출
  Future<void> _deleteCertNo(String certCode, [String? customerId]) async {
    try {
      final url = 'https://admin.787.kr/api/certno/delete';
      final body = jsonEncode({
        'customer_id': customerId ?? _userId,
        'cert_code': certCode,
      });
      
      debugPrint('MDesk CertNo Delete: Calling API: $url');
      debugPrint('MDesk CertNo Delete: Body: $body');
      
      final response = await http.post(
        Uri.parse(url),
        headers: {'Content-Type': 'application/json'},
        body: body,
      ).timeout(const Duration(seconds: 10));
      
      debugPrint('MDesk CertNo Delete: Response: ${response.statusCode} - ${response.body}');
    } catch (e) {
      debugPrint('MDesk CertNo Delete Error: $e');
    }
  }

  // 앱 종료 시 agentclose API 호출
  Future<void> _handleExit() async {
    if (_agentId.isNotEmpty) {
      try {
        final url = 'https://787.kr/api/agentclose/$_userId/$_agentId';
        debugPrint('MDesk AgentClose (Exit): Calling API: $url');
        
        // 종료 직전이므로 타임아웃을 짧게 설정
        await http.get(Uri.parse(url)).timeout(const Duration(seconds: 2));
      } catch (e) {
        debugPrint('MDesk AgentClose (Exit) Error: $e');
      }
    }
    exit(0);
  }

  @override
  void onWindowClose() async {
    await _handleExit();
  }

  @override
  void dispose() {
    windowManager.removeListener(this);
    _updateTimer?.cancel();
    _certNoController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return ChangeNotifierProvider.value(
      value: gFFI.serverModel,
      child: Consumer<ServerModel>(
        builder: (context, model, child) {
          final config = model.customConfig;
          final appName = config?.appName ?? 'MDesk';
          final title = config?.title ?? translate('Your Desktop');
          final description = config?.description ?? translate('desk_tip');
          final logoUrl = config?.logoUrl ?? '';

          return Scaffold(
            backgroundColor: const Color(0xFF1E1E1E),
            body: Column(
              children: [
                Container(
                  height: 40,
                  color: const Color(0xFF1E1E1E),
                  child: Row(
                    children: [
                      Expanded(
                        child: DragToMoveArea(
                          child: Container(
                            alignment: Alignment.centerLeft,
                            padding: const EdgeInsets.only(left: 15),
                            child: Text(
                              appName,
                              style: const TextStyle(color: Color(0xFF888888), fontSize: 12),
                            ),
                          ),
                        ),
                      ),
                      SizedBox(
                        width: 46,
                        height: 40,
                        child: InkWell(
                          onTap: () => windowManager.minimize(),
                          hoverColor: const Color(0xFF333333),
                          child: const Icon(Icons.remove, color: Color(0xFF888888), size: 18),
                        ),
                      ),
                      SizedBox(
                        width: 46,
                        height: 40,
                        child: InkWell(
                          onTap: _handleExit,
                          hoverColor: const Color(0xFFE81123),
                          child: const Icon(Icons.close, color: Color(0xFF888888), size: 18),
                        ),
                      ),
                    ],
                  ),
                ),
                Expanded(
                  child: DragToMoveArea(
                    child: Center(
                      child: Container(
                        width: 350,
                        padding: const EdgeInsets.fromLTRB(30, 10, 30, 30),
                        child: Column(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            Text(
                              'Powered by MDesk',
                              style: const TextStyle(color: Color(0xFF888888), fontSize: 12),
                            ),
                            const SizedBox(height: 10),
                            Container(
                              height: 1,
                              color: const Color(0xFF333333),
                            ),
                            const SizedBox(height: 30),
                            Container(
                              width: 80,
                              height: 80,
                              decoration: BoxDecoration(
                                color: const Color(0xFF333333),
                                borderRadius: BorderRadius.circular(8),
                              ),
                              alignment: Alignment.center,
                              child: logoUrl.isNotEmpty
                                  ? ClipRRect(
                                      borderRadius: BorderRadius.circular(8),
                                      child: Image.network(
                                        logoUrl,
                                        fit: BoxFit.cover,
                                        errorBuilder: (context, error, stackTrace) => Text(
                                          appName.isNotEmpty ? appName[0] : 'M',
                                          style: const TextStyle(
                                            color: Color(0xFFFF6B35),
                                            fontSize: 32,
                                            fontWeight: FontWeight.bold,
                                          ),
                                        ),
                                      ),
                                    )
                                  : const Text(
                                      'M',
                                      style: TextStyle(
                                        color: Color(0xFFFF6B35),
                                        fontSize: 32,
                                        fontWeight: FontWeight.bold,
                                      ),
                                    ),
                            ),
                            const SizedBox(height: 15),
                            Text(
                              appName,
                              style: const TextStyle(
                                color: Color(0xFFFF6B35),
                                fontSize: 24,
                                fontWeight: FontWeight.bold,
                              ),
                            ),
                            const Text(
                              '원격 데스크톱 제어',
                              style: TextStyle(color: Color(0xFFAAAAAA), fontSize: 14),
                            ),
                            const SizedBox(height: 40),
                            Align(
                              alignment: Alignment.centerLeft,
                              child: Column(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  Text(
                                    title,
                                    style: const TextStyle(
                                      color: Colors.white,
                                      fontSize: 20,
                                      fontWeight: FontWeight.w600,
                                    ),
                                  ),
                                  const SizedBox(height: 15),
                                  Text(
                                    description,
                                    style: const TextStyle(color: Color(0xFFAAAAAA), fontSize: 14),
                                  ),
                                  const SizedBox(height: 30),
                                  Text(
                                    translate('ID'),
                                    style: const TextStyle(
                                      color: Color(0xFF888888),
                                      fontSize: 12,
                                      letterSpacing: 1,
                                    ),
                                  ),
                                  const SizedBox(height: 8),
                                  Container(
                                    padding: const EdgeInsets.symmetric(horizontal: 15, vertical: 12),
                                    decoration: BoxDecoration(
                                      color: const Color(0xFF2A2A2A),
                                      border: Border.all(color: const Color(0xFF444444)),
                                      borderRadius: BorderRadius.circular(6),
                                    ),
                                    child: Row(
                                      children: [
                                        Expanded(
                                          child: Text(
                                            formatID(model.serverId.text),
                                            style: const TextStyle(
                                              color: Color(0xFF4A9EFF),
                                              fontSize: 18,
                                              fontWeight: FontWeight.bold,
                                              letterSpacing: 2,
                                            ),
                                          ),
                                        ),
                                        IconButton(
                                          icon: const Icon(Icons.copy, size: 20, color: Color(0xFF888888)),
                                          onPressed: () {
                                            Clipboard.setData(ClipboardData(text: model.serverId.text));
                                            showToast(translate('Copied'));
                                          },
                                          padding: EdgeInsets.zero,
                                          constraints: const BoxConstraints(),
                                          splashRadius: 20,
                                        ),
                                      ],
                                    ),
                                  ),
                                  // 인증번호 입력창 (certno=true 일 때만 표시)
                                  if (_certNoEnabled) ...[
                                    const SizedBox(height: 20),
                                    Container(
                                      padding: const EdgeInsets.symmetric(horizontal: 15, vertical: 10),
                                      decoration: BoxDecoration(
                                        color: const Color(0xFF2A2A2A),
                                        border: Border.all(
                                          color: _isCertNoVerified 
                                              ? const Color(0xFF4CAF50) 
                                              : const Color(0xFFFF6B35),
                                          width: 2,
                                        ),
                                        borderRadius: BorderRadius.circular(6),
                                      ),
                                      child: Row(
                                        children: [
                                          Icon(
                                            _isCertNoVerified ? Icons.verified : Icons.pin,
                                            size: 18,
                                            color: _isCertNoVerified 
                                                ? const Color(0xFF4CAF50) 
                                                : const Color(0xFFFF6B35),
                                          ),
                                          const SizedBox(width: 8),
                                          Expanded(
                                            child: TextField(
                                              controller: _certNoController,
                                              enabled: !_isCertNoVerified,
                                              cursorColor: Colors.white,
                                              style: TextStyle(
                                                color: _isCertNoVerified 
                                                    ? const Color(0xFF4CAF50) 
                                                    : Colors.white,
                                                fontSize: 14,
                                                fontWeight: FontWeight.w500,
                                              ),
                                              decoration: InputDecoration(
                                                hintText: _isCertNoVerified ? '인증완료' : '인증번호 입력',
                                                hintStyle: TextStyle(
                                                  color: _isCertNoVerified 
                                                      ? const Color(0xFF4CAF50).withOpacity(0.7) 
                                                      : const Color(0xFF888888),
                                                  fontSize: 14,
                                                ),
                                                filled: true,
                                                fillColor: const Color(0xFF2A2A2A),
                                                hoverColor: Colors.transparent,
                                                border: OutlineInputBorder(
                                                  borderSide: BorderSide.none,
                                                  borderRadius: BorderRadius.circular(4),
                                                ),
                                                enabledBorder: OutlineInputBorder(
                                                  borderSide: BorderSide.none,
                                                  borderRadius: BorderRadius.circular(4),
                                                ),
                                                focusedBorder: OutlineInputBorder(
                                                  borderSide: BorderSide.none,
                                                  borderRadius: BorderRadius.circular(4),
                                                ),
                                                disabledBorder: OutlineInputBorder(
                                                  borderSide: BorderSide.none,
                                                  borderRadius: BorderRadius.circular(4),
                                                ),
                                                isDense: true,
                                                contentPadding: const EdgeInsets.symmetric(horizontal: 8, vertical: 8),
                                              ),
                                              keyboardType: TextInputType.number,
                                              onSubmitted: (value) => _verifyCertNo(),
                                            ),
                                          ),
                                          IconButton(
                                            icon: Icon(
                                              _isCertNoVerified ? Icons.check_circle : Icons.send,
                                              size: 18,
                                              color: _isCertNoVerified 
                                                  ? const Color(0xFF4CAF50) 
                                                  : const Color(0xFFFF6B35),
                                            ),
                                            onPressed: _isCertNoVerified ? null : _verifyCertNo,
                                            padding: EdgeInsets.zero,
                                            constraints: const BoxConstraints(),
                                            splashRadius: 20,
                                            tooltip: _isCertNoVerified ? '인증완료' : '인증번호 확인',
                                          ),
                                        ],
                                      ),
                                    ),
                                  ],
                                  // 상담원 정보 표시 (agentid가 있을 때만)
                                  if (_agentId.isNotEmpty) ...[
                                    const SizedBox(height: 20),
                                    Container(
                                      padding: const EdgeInsets.symmetric(horizontal: 15, vertical: 10),
                                      decoration: BoxDecoration(
                                        color: const Color(0xFF2A2A2A),
                                        border: Border.all(color: const Color(0xFF444444)),
                                        borderRadius: BorderRadius.circular(6),
                                      ),
                                      child: Row(
                                        children: [
                                          const Icon(Icons.person, size: 18, color: Color(0xFF4A9EFF)),
                                          const SizedBox(width: 8),
                                          Expanded(
                                            child: Text(
                                              '상담원$_agentId',
                                              style: const TextStyle(
                                                color: Color(0xFF4A9EFF),
                                                fontSize: 14,
                                                fontWeight: FontWeight.w500,
                                              ),
                                            ),
                                          ),
                                          IconButton(
                                            icon: const Icon(Icons.refresh, size: 18, color: Color(0xFF4A9EFF)),
                                            onPressed: () async {
                                              final mdeskId = model.serverId.text.replaceAll(' ', '');
                                              if (mdeskId.isNotEmpty && !mdeskId.contains('...')) {
                                                await _callAgentNumUpdateAPI(mdeskId);
                                              } else {
                                                showToast('ID가 준비되지 않았습니다');
                                              }
                                            },
                                            padding: EdgeInsets.zero,
                                            constraints: const BoxConstraints(),
                                            splashRadius: 20,
                                            tooltip: '상담원 정보 새로고침',
                                          ),
                                        ],
                                      ),
                                    ),
                                  ],
                                  const SizedBox(height: 25),
                                  Text(
                                    translate('Password'),
                                    style: const TextStyle(
                                      color: Color(0xFF888888),
                                      fontSize: 12,
                                      letterSpacing: 1,
                                    ),
                                  ),
                                  const SizedBox(height: 8),
                                  Container(
                                    padding: const EdgeInsets.symmetric(horizontal: 15, vertical: 12),
                                    decoration: BoxDecoration(
                                      color: const Color(0xFF2A2A2A),
                                      border: Border.all(color: const Color(0xFF444444)),
                                      borderRadius: BorderRadius.circular(6),
                                    ),
                                    child: const Row(
                                      children: [
                                        Expanded(
                                          child: Text(
                                            '••••••••',
                                            style: TextStyle(
                                              color: Colors.white,
                                              fontSize: 16,
                                              fontWeight: FontWeight.w500,
                                              fontFamily: 'monospace',
                                            ),
                                          ),
                                        ),
                                        Icon(Icons.lock, size: 18, color: Color(0xFF888888)),
                                      ],
                                    ),
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
              ],
            ),
          );
        },
      ),
    );
  }
}
