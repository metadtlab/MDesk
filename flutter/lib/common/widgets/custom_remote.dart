import 'dart:async';
import 'dart:convert';
import 'dart:io' show Platform;
import 'package:flutter/material.dart';
import 'package:flutter_hbb/common/formatter/id_formatter.dart';
import 'package:get/get.dart';
import 'package:http/http.dart' as http;
import '../../common.dart';
import '../../models/model.dart';
import '../../models/platform_model.dart';
import 'login.dart';
import '../../utils/device_register_service.dart';

class CustomRemoteView extends StatefulWidget {
  final EdgeInsets? menuPadding;
  
  const CustomRemoteView({Key? key, this.menuPadding}) : super(key: key);

  @override
  State<CustomRemoteView> createState() => _CustomRemoteViewState();
}

class _CustomRemoteViewState extends State<CustomRemoteView> 
    with SingleTickerProviderStateMixin, WidgetsBindingObserver {
  List<Map<String, dynamic>> _counselors = [];
  List<Map<String, dynamic>> _devices = [];  // 디바이스 목록
  bool _isLoading = false;
  bool _isFetching = false;
  String _message = '';
  late AnimationController _blinkController;
  Timer? _autoRefreshTimer;  // 자동 새로고침 타이머
  bool _isAppFocused = true;  // 앱 포커스 상태
  
  // 인증번호 관련 상태
  String _certCode = '';
  String _certExpireTime = '';
  bool _isCertLoading = false;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);  // 앱 상태 감시 등록
    
    // 깜빡임 애니메이션 컨트롤러 설정
    _blinkController = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 800),
    )..repeat(reverse: true);

    // 초기 로딩 시 상담원 목록 및 디바이스 목록 조회
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (gFFI.userModel.isLogin) {
        _fetchCounselors(showLoading: true);
        _fetchDevices();
        _searchCertNo();  // 인증번호 조회
        _startAutoRefresh();
      }
    });
  }

  // 자동 새로고침 시작 (5초마다, 앱 포커스 시에만)
  void _startAutoRefresh() {
    _autoRefreshTimer?.cancel();
    _autoRefreshTimer = Timer.periodic(const Duration(seconds: 5), (_) {
      if (mounted && gFFI.userModel.isLogin && _isAppFocused) {
        _fetchCounselors();
        _fetchDevices();
        _searchCertNo();  // 인증번호 조회
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
      _fetchDevices();
      _searchCertNo();  // 인증번호 조회
    }
  }

  // 401 응답 처리 (토큰 무효화 - 비밀번호 변경 등)
  Future<void> _handleUnauthorized() async {
    debugPrint('CustomRemote: 401 Unauthorized - Token invalidated');
    
    // 자동 새로고침 중지
    _autoRefreshTimer?.cancel();
    
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
    WidgetsBinding.instance.removeObserver(this);  // 앱 상태 감시 해제
    _autoRefreshTimer?.cancel();
    _blinkController.dispose();
    super.dispose();
  }

  // 상담원 목록 조회
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

      debugPrint('Fetch Agents Response: ${response.statusCode} - ${response.body}');

      // 401 응답 처리 (토큰 무효화)
      if (response.statusCode == 401) {
        await _handleUnauthorized();
        return;
      }

      if (response.statusCode == 200) {
        final responseData = jsonDecode(response.body);
        if (responseData is Map && responseData['code'] == 1) {
          // 'agents' 또는 'data' 필드 지원
          final List<dynamic> agentList = responseData['agents'] ?? responseData['data'] ?? [];
          final newCounselors = agentList.map((e) => e is Map<String, dynamic> ? e : {'agent_name': e.toString()}).toList();
          
          // 이전 목록과 비교하여 새로 온라인이 된 상담원 찾기
          for (var newAgent in newCounselors) {
            final String name = _getCounselorName(newAgent);
            final String mdeskId = _getMdeskId(newAgent);
            
            if (mdeskId.isNotEmpty) {
              // 이전 목록에 없었거나, mdesk_id가 비어있었다면 새로 접속한 것
              bool wasOnline = _counselors.any((oldAgent) => 
                _getAgentNum(oldAgent) == _getAgentNum(newAgent) && 
                _getMdeskId(oldAgent).isNotEmpty
              );
              
              if (!wasOnline && _counselors.isNotEmpty) {
                // 접속 알림 표시 (짙은 녹색)
                showToast('$name님이 접속하셨습니다!');
              }
            }
          }

          setState(() {
            _counselors = newCounselors;
          });
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

      debugPrint('Fetch Devices Response: ${response.statusCode} - ${response.body}');

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
                .map((e) => e is Map ? Map<String, dynamic>.from(e) : <String, dynamic>{})
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

  // 상담원 추가
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
          _message = '상담원 추가 완료!';
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
      final userPkid = gFFI.userModel.userPkid.value;  // user_pk_id 추가
      final mdeskId = gFFI.serverModel.serverId.text.replaceAll(' ', '');
      final url = 'https://admin.787.kr/api/certno/generate';
      
      final body = jsonEncode({
        'customer_id': username,
        'user_pk_id': userPkid,  // user_pk_id 전달 (서버에서 인증번호 prefix로 사용)
        'mdesk_id': mdeskId,
      });
      
      debugPrint('CertNo Generate Request URL: $url');
      debugPrint('CertNo Generate Request Body: $body');

      final response = await http.post(
        Uri.parse(url),
        headers: {
          'Content-Type': 'application/json',
        },
        body: body,
      ).timeout(const Duration(seconds: 10));

      debugPrint('CertNo Generate Response: ${response.statusCode} - ${response.body}');

      // 401 응답 처리 (토큰 무효화)
      if (response.statusCode == 401) {
        await _handleUnauthorized();
        return;
      }

      if (response.statusCode == 200) {
        final data = jsonDecode(response.body);
        if (data['success'] == true) {
          setState(() {
            _certCode = data['cert_code']?.toString() ?? '';
            _certExpireTime = data['expires_at']?.toString() ?? '';
            _message = '인증번호 생성 완료!';
          });
          showToast('인증번호: $_certCode');
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

  // 인증번호 조회 API 호출
  Future<void> _searchCertNo() async {
    try {
      final username = gFFI.userModel.userName.value;
      final mdeskId = gFFI.serverModel.serverId.text.replaceAll(' ', '');
      
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

      final response = await http.post(
        Uri.parse(url),
        headers: {
          'Content-Type': 'application/json',
        },
        body: body,
      ).timeout(const Duration(seconds: 10));

      debugPrint('CertNo Search Response: ${response.statusCode} - ${response.body}');

      // 401 응답 처리 (토큰 무효화)
      if (response.statusCode == 401) {
        await _handleUnauthorized();
        return;
      }

      if (response.statusCode == 200) {
        final data = jsonDecode(response.body);
        if (data['success'] == true && data['exists'] == true) {
          final newCertCode = data['cert_code']?.toString() ?? '';
          if (newCertCode.isNotEmpty && newCertCode != _certCode) {
            setState(() {
              _certCode = newCertCode;
            });
          }
        } else {
          // 인증번호가 없으면 초기화
          if (_certCode.isNotEmpty) {
            setState(() {
              _certCode = '';
              _certExpireTime = '';
            });
          }
        }
      }
    } catch (e) {
      debugPrint('CertNo Search Error: $e');
    }
  }

  // 상담원 삭제
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

      debugPrint('DeleteNum Response: ${response.statusCode} - ${response.body}');

      // 401 응답 처리 (토큰 무효화)
      if (response.statusCode == 401) {
        await _handleUnauthorized();
        return;
      }

      if (response.statusCode == 200 || response.statusCode == 404) {
        // 200: 삭제 성공, 404: 이미 삭제되었거나 존재하지 않음 (조용히 처리)
        if (response.statusCode == 200) {
          setState(() {
            _message = '상담원 삭제 완료!';
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
    return agent['agent_name']?.toString() ?? '상담원';
  }

  int _getAgentNum(Map<String, dynamic> agent) {
    return agent['agent_num'] ?? 0;
  }

  String _getMdeskId(Map<String, dynamic> agent) {
    return agent['mdesk_id']?.toString() ?? '';
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
      
      // HTTP 직접 호출 방식 사용
      final url = 'https://admin.787.kr/api/device/register';
      
      // 요청 본문 구성 - alias는 사용자가 입력한 값 그대로 사용
      final bodyMap = <String, dynamic>{
        'user_id': username,
        'user_pkid': userPkid,
        'remote_id': remoteId,
        'alias': alias, // 사용자가 입력한 별칭 그대로 사용
        'hostname': hostname,
        'platform': platform,
        'uuid': uuid,
        'version': version,
      };
      
      // agent_id가 있으면 추가
      if (agentId != null && agentId.isNotEmpty) {
        bodyMap['agent_id'] = agentId;
      }
      
      final body = jsonEncode(bodyMap);

      debugPrint('Register Device URL: $url');
      debugPrint('Register Device Body: $body');
      debugPrint('Register Device - alias: $alias');

      final response = await http.post(
        Uri.parse(url),
        headers: {
          'Content-Type': 'application/json',
          'Authorization': 'Bearer $token',
        },
        body: body,
      ).timeout(const Duration(seconds: 10));

      debugPrint('Register Device Response: ${response.statusCode} - ${response.body}');

      // 401 응답 처리 (토큰 무효화)
      if (response.statusCode == 401) {
        await _handleUnauthorized();
        return;
      }

      if (response.statusCode == 200 || response.statusCode == 201) {
        final responseData = jsonDecode(response.body);
        if (responseData['success'] == true || responseData['code'] == 1) {
          // 별칭은 서버에서만 관리 (로컬 저장하지 않음)
          setState(() {
            _message = translate('Device registered successfully');
          });
          showToast('기기가 등록되었습니다: $remoteId');
          // 등록 후 목록 새로고침 (서버에서 최신 별칭 가져옴)
          await _fetchDevices();
        } else {
          setState(() {
            _message = responseData['message'] ?? '등록 실패';
          });
        }
      } else {
        setState(() {
          _message = '등록 오류: ${response.statusCode}';
        });
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

      final response = await http.post(
        Uri.parse(url),
        headers: {
          'Content-Type': 'application/json',
          'Authorization': 'Bearer $token',
        },
        body: body,
      ).timeout(const Duration(seconds: 10));

      debugPrint('Unregister Device Response: ${response.statusCode} - ${response.body}');

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
                  color: Theme.of(context).textTheme.bodyMedium?.color?.withOpacity(0.7),
                ),
              ),
              const SizedBox(height: 24),
              ElevatedButton(
                onPressed: loginDialog,
                child: Text(translate("Login")),
              ),
            ],
          ),
        );
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
                '상담원 관리 및 다이렉트 연결 기능을 사용하시려면\n멤버십을 업그레이드 해주세요.',
                textAlign: TextAlign.center,
                style: TextStyle(
                  fontSize: 14,
                  color: Theme.of(context).textTheme.bodyMedium?.color?.withOpacity(0.7),
                ),
              ),
            ],
          ),
        );
      }

      // 로그인된 상태 - 상담원 관리 UI
      // agent_num == 0 인 상담원 찾기 (바로 원격 연결용)
      Map<String, dynamic>? directAgent;
      for (var agent in _counselors) {
        if (_getAgentNum(agent) == 0 && _getMdeskId(agent).isNotEmpty) {
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
                padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
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
                      _certCode,
                      style: const TextStyle(
                        color: Colors.white,
                        fontSize: 24,
                        fontWeight: FontWeight.bold,
                        letterSpacing: 4,
                      ),
                    ),
                    const SizedBox(width: 12),
                    IconButton(
                      onPressed: () {
                        setState(() {
                          _certCode = '';
                          _certExpireTime = '';
                        });
                      },
                      icon: const Icon(Icons.close, color: Colors.white, size: 18),
                      padding: EdgeInsets.zero,
                      constraints: const BoxConstraints(),
                      tooltip: '인증번호 숨기기',
                    ),
                  ],
                ),
              ),
              const SizedBox(height: 12),
            ],
            // agent_num == 0인 상담원이 있으면 바로 원격 버튼 표시
            if (directAgent != null) ...[
              _buildDirectRemoteButton(directAgent),
              const SizedBox(height: 12),
            ],
            // 상담원 목록 (가로로 쌓임) - 상단
            Expanded(
              child: _isFetching
                  ? const Center(child: CircularProgressIndicator())
                  : _counselors.isEmpty
                      ? Center(
                          child: Column(
                            mainAxisAlignment: MainAxisAlignment.center,
                            children: [
                              Text(
                                '상담원 추가 버튼을 눌러주세요',
                                style: TextStyle(
                                  color: Theme.of(context).disabledColor,
                                ),
                              ),
                              const SizedBox(height: 8),
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
                              children: _counselors.where((agent) => _getAgentNum(agent) != 0).map((agent) {
                                final num = _getAgentNum(agent);
                                final name = _getCounselorName(agent);
                                final mdeskId = _getMdeskId(agent);
                                final bool isOnline = mdeskId.isNotEmpty;

                                return InkWell(
                                  onTap: () {
                                    if (mdeskId.isNotEmpty) {
                                      final mdeskIdClean = mdeskId.replaceAll(' ', '');
                                      try {
                                        // 1. IDTextEditingController 찾아서 업데이트
                                        if (Get.isRegistered<IDTextEditingController>()) {
                                          Get.find<IDTextEditingController>().id = mdeskIdClean;
                                        }

                                        // 2. 일반 TextEditingController 찾아서 업데이트 (화면 표시용)
                                        // ConnectionPage에서 Get.put<TextEditingController>(_idEditingController)로 등록됨
                                        if (Get.isRegistered<TextEditingController>()) {
                                          final controller = Get.find<TextEditingController>();
                                          controller.text = formatID(mdeskIdClean);
                                          
                                          // 커서를 끝으로 이동
                                          controller.selection = TextSelection.fromPosition(
                                            TextPosition(offset: controller.text.length),
                                          );
                                        }
                                        
                                        showToast('ID가 입력되었습니다: $mdeskIdClean');

                                        // 3. 즉시 연결 실행
                                        debugPrint('CustomRemote: Starting direct connection to $mdeskIdClean');
                                        connect(context, mdeskIdClean);
                                      } catch (e) {
                                        debugPrint('Error filling ID: $e');
                                      }
                                    } else {
                                      showToast('해당 상담원은 오프라인입니다.');
                                    }
                                  },
                                  borderRadius: BorderRadius.circular(16),
                                  child: Chip(
                                    avatar: Stack(
                                      children: [
                                        CircleAvatar(
                                          backgroundColor: Theme.of(context).colorScheme.primary,
                                          child: Text(
                                            '$num',
                                            style: const TextStyle(color: Colors.white, fontSize: 12),
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
                                                  color: const Color(0xFF00E676),
                                                  shape: BoxShape.circle,
                                                  border: Border.all(color: Colors.white, width: 2),
                                                  boxShadow: [
                                                    BoxShadow(
                                                      color: const Color(0xFF00E676).withOpacity(0.9),
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
                                    deleteIcon: const Icon(Icons.close, size: 16),
                                    onDeleted: _isLoading ? null : () => _deleteCounselor(num),
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
                  children: _devices
                      .where((device) {
                        final agentId = device['agent_id']?.toString() ?? '';
                        return agentId.isNotEmpty && agentId != '0';
                      })
                      .map((device) {
                    final remoteId = device['remote_id']?.toString() ?? '';
                    final agentId = device['agent_id']?.toString() ?? '';
                    final hostname = device['hostname']?.toString() ?? '';
                    final isActive = device['is_active'] == true;
                    
                    final deviceAlias = device['alias']?.toString() ?? '';
                    
                    return Container(
                      margin: const EdgeInsets.only(right: 8),
                      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
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
                                  padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 1),
                                  decoration: BoxDecoration(
                                    color: Theme.of(context).colorScheme.primary,
                                    borderRadius: BorderRadius.circular(4),
                                  ),
                                  child: Text(
                                    deviceAlias.isNotEmpty 
                                        ? deviceAlias 
                                        : (agentId.isNotEmpty ? '상담원$agentId' : '-'),
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
                                color: Theme.of(context).textTheme.bodyLarge?.color,
                              ),
                            ),
                            if (hostname.isNotEmpty)
                              Text(
                                hostname,
                                style: TextStyle(
                                  fontSize: 9,
                                  color: Theme.of(context).textTheme.bodySmall?.color,
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

            // 하단: 상담원 추가 버튼 + 인증번호원격 버튼 + 새로고침 + 메시지
            Row(
              children: [
                ElevatedButton.icon(
                  onPressed: _isLoading ? null : _addCounselor,
                  icon: _isLoading
                      ? const SizedBox(
                          width: 16,
                          height: 16,
                          child: CircularProgressIndicator(strokeWidth: 2),
                        )
                      : const Icon(Icons.person_add),
                  label: Text(_isLoading ? '추가 중...' : '상담원 추가'),
                  style: ElevatedButton.styleFrom(
                    padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
                  ),
                ),
                const SizedBox(width: 8),
                ElevatedButton.icon(
                  onPressed: _isCertLoading ? null : _generateCertNo,
                  icon: _isCertLoading
                      ? const SizedBox(
                          width: 16,
                          height: 16,
                          child: CircularProgressIndicator(strokeWidth: 2),
                        )
                      : const Icon(Icons.pin),
                  label: Text(_isCertLoading ? '생성 중...' : '인증번호원격'),
                  style: ElevatedButton.styleFrom(
                    backgroundColor: const Color(0xFFFF6B35),
                    foregroundColor: Colors.white,
                    padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
                  ),
                ),
                const SizedBox(width: 8),
                IconButton(
                  onPressed: _isFetching ? null : () async {
                    await _fetchCounselors();
                    await _fetchDevices();
                    await _searchCertNo();  // 인증번호 조회
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
                        color: _message.contains('완료') || _message.contains('성공') 
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

  // agent_num == 0인 상담원을 위한 바로 원격 버튼
  Widget _buildDirectRemoteButton(Map<String, dynamic> agent) {
    final mdeskId = _getMdeskId(agent);
    final mdeskIdClean = mdeskId.replaceAll(' ', '');
    
    return AnimatedBuilder(
      animation: _blinkController,
      builder: (context, child) {
        // 애니메이션 값으로 테두리 색상 및 glow 효과 조절 (0.0 ~ 1.0 범위 유지)
        final glowOpacity = (0.3 + (_blinkController.value * 0.4)).clamp(0.0, 1.0);
        final borderOpacity = (0.5 + (_blinkController.value * 0.3)).clamp(0.0, 1.0);
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
              onTap: () {
                debugPrint('Direct Remote: Connecting to $mdeskIdClean');
                connect(context, mdeskIdClean);
              },
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
