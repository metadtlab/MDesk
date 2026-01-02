import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:flutter_hbb/common/formatter/id_formatter.dart';
import 'package:get/get.dart';
import 'package:http/http.dart' as http;
import '../../common.dart';
import '../../models/model.dart';
import '../../models/platform_model.dart';
import 'login.dart';

class CustomRemoteView extends StatefulWidget {
  final EdgeInsets? menuPadding;
  
  const CustomRemoteView({Key? key, this.menuPadding}) : super(key: key);

  @override
  State<CustomRemoteView> createState() => _CustomRemoteViewState();
}

class _CustomRemoteViewState extends State<CustomRemoteView> with SingleTickerProviderStateMixin {
  List<Map<String, dynamic>> _counselors = [];
  bool _isLoading = false;
  bool _isFetching = false;
  String _message = '';
  late AnimationController _blinkController;

  @override
  void initState() {
    super.initState();
    // 깜빡임 애니메이션 컨트롤러 설정
    _blinkController = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 800),
    )..repeat(reverse: true);

    // 초기 로딩 시 상담원 목록 조회
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (gFFI.userModel.isLogin) {
        _fetchCounselors();
      }
    });
  }

  @override
  void dispose() {
    _blinkController.dispose();
    super.dispose();
  }

  // 상담원 목록 조회
  Future<void> _fetchCounselors() async {
    if (_isFetching) return;
    
    setState(() {
      _isFetching = true;
    });

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

      if (response.statusCode == 200) {
        final responseData = jsonDecode(response.body);
        if (responseData is Map && responseData['code'] == 1) {
          final List<dynamic> agentList = responseData['data'] ?? [];
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
      setState(() {
        _isFetching = false;
      });
    }
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

      if (response.statusCode == 200) {
        setState(() {
          _message = '상담원 삭제 완료!';
        });
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
      return Padding(
        padding: const EdgeInsets.all(16.0),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
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
                              children: _counselors.map((agent) {
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
            const SizedBox(height: 8),

            // 하단: 상담원 추가 버튼 + 새로고침 + 메시지
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
                IconButton(
                  onPressed: _isFetching ? null : _fetchCounselors,
                  icon: const Icon(Icons.refresh),
                  tooltip: '새로고침',
                ),
                if (_message.isNotEmpty) ...[
                  const SizedBox(width: 8),
                  Text(
                    _message,
                    style: TextStyle(
                      color: _message.contains('완료') ? Colors.green : Colors.red,
                      fontWeight: FontWeight.w500,
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
}
