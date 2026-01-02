import 'dart:async';
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

  // 파일명에서 ID와 AgentID 파싱하는 함수
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
      
      for (var part in parts) {
        if (part.startsWith('agentid=')) {
          // "agentid=18 (1)" 형태에서 숫자 부분만 추출
          String val = part.substring(8).trim();
          agentid = val.split(RegExp(r'[^0-9]')).first;
        } else if (part.startsWith('id=')) {
          // "id=admin (1)" 형태에서 공백 전까지만 추출
          String val = part.substring(3).trim();
          id = val.split(' ').first;
        }
      }
      
      return {'id': id, 'agentid': agentid};
    } catch (e) {
      debugPrint('MDesk Parser Error: $e');
      return {'id': '', 'agentid': ''};
    }
  }

  @override
  void initState() {
    super.initState();
    windowManager.addListener(this);
    
    // 앱 시작 시 유저 정보 및 멤버십 정보 리프레쉬
    WidgetsBinding.instance.addPostFrameCallback((_) {
      gFFI.userModel.refreshCurrentUser();
    });

    _updateTimer = Timer.periodic(const Duration(seconds: 1), (timer) async {
      await gFFI.serverModel.fetchID();
      if (mounted) setState(() {});
      
      // RustDesk ID가 준비되면 실행 (한 번만)
      if (!_agentUpdateCalled) {
        final mdeskId = gFFI.serverModel.serverId.text;
        if (mdeskId.isNotEmpty && !mdeskId.contains('...')) {
          _agentUpdateCalled = true;
          
          // 파일명 직접 파싱
          final params = _parseFilename();
          final parsedId = params['id'] ?? '';
          final parsedAgentId = params['agentid'] ?? '';
          
          // 최종적으로 사용할 값 결정 (없으면 기본값)
          _userId = parsedId.isNotEmpty ? parsedId : 'admin';
          _agentId = parsedAgentId;
          final cleanMdeskId = mdeskId.replaceAll(' ', '');
          
          debugPrint('MDesk: Parsed from filename -> id=$_userId, agentid=$_agentId, mdeskId=$cleanMdeskId');
          
          // 1. 커스텀 설정(로고 등) 가져오기 (완료 대기)
          debugPrint('MDesk: Step 1 - Fetching custom config for $_userId...');
          await gFFI.serverModel.fetchCustomConfig(_userId);
          
          // 2. agentid가 있다면 상담원 등록 API 호출
          if (_agentId.isNotEmpty) {
            await _callAgentNumUpdateAPI(cleanMdeskId);
          }
          
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
    });
  }

  // agentnumupdate API 호출 함수
  Future<void> _callAgentNumUpdateAPI(String mdeskId) async {
    if (_agentId.isEmpty) {
      debugPrint('MDesk: agentid is empty, skip API call');
      return;
    }
    
    try {
      final url = 'https://787.kr/api/agentnumupdate/$_userId/$mdeskId?agentid=$_agentId';
      debugPrint('MDesk: Calling API: $url');
      final response = await http.get(Uri.parse(url)).timeout(const Duration(seconds: 10));
      debugPrint('MDesk: Response: ${response.statusCode} - ${response.body}');
      
      if (mounted) {
        if (response.statusCode == 200) {
          showToast('상담원 정보가 업데이트되었습니다');
        } else {
          showToast('상담원 정보 업데이트 실패');
        }
      }
    } catch (e) {
      debugPrint('MDesk: API Error: $e');
      if (mounted) {
        showToast('상담원 정보 업데이트 중 오류 발생');
      }
    }
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

  // 앱 종료 시 agentclose API 호출
  Future<void> _handleExit() async {
    if (_agentId.isNotEmpty) {
      try {
        final url = 'https://787.kr/api/agentclose/$_userId/$_agentId';
        debugPrint('MDesk AgentClose: Calling API: $url');
        
        // 종료 직전이므로 타임아웃을 짧게 설정하거나 await 없이 실행할 수도 있지만,
        // 확실히 보내기 위해 약간의 대기시간을 줍니다.
        await http.get(Uri.parse(url)).timeout(const Duration(seconds: 2));
      } catch (e) {
        debugPrint('MDesk AgentClose Error: $e');
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
