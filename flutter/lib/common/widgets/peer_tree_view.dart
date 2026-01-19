import 'package:flutter/material.dart';
import 'package:flutter_hbb/common.dart';
import 'package:flutter_hbb/common/widgets/peer_card.dart';
import 'package:flutter_hbb/common/widgets/login.dart';
import 'package:flutter_hbb/models/model.dart';
import 'package:flutter_hbb/models/peer_model.dart';
import 'package:flutter_hbb/models/peer_tab_model.dart';
import 'package:flutter_hbb/models/ab_model.dart';
import 'package:flutter_hbb/models/platform_model.dart';
import 'package:flutter_hbb/desktop/widgets/material_mod_popup_menu.dart' as mod_menu;
import 'package:flutter_hbb/desktop/widgets/popup_menu.dart';
import 'package:get/get.dart';
import 'package:provider/provider.dart';
import 'package:flutter_hbb/utils/device_register_service.dart';

/// 트리뷰에서 사용하는 피어 카드 타입
enum TreeViewPeerType { recent, favorite, mydevices, addressbook, recentApi }

/// 팀뷰어 스타일의 트리뷰 피어 목록 위젯
class PeerTreeView extends StatefulWidget {
  final EdgeInsets? menuPadding;
  
  const PeerTreeView({Key? key, this.menuPadding}) : super(key: key);

  @override
  State<PeerTreeView> createState() => _PeerTreeViewState();
}

class _PeerTreeViewState extends State<PeerTreeView> {
  // 카테고리별 접힘 상태
  final Map<String, bool> _expandedCategories = {
    'recent': true,
    'favorites': true,
    'mydevices': true,
    'addressbook': true,
    'recentApi': true,  // API 기반 최근 세션
  };
  
  // 검색어
  String _searchQuery = '';
  
  // 선택된 피어 ID
  String? _selectedPeerId;
  
  // 온라인 상태 쿼리 여부
  bool _onlineQueried = false;
  
  // 나의 관리장치 목록
  List<Peer> _myDevices = [];
  bool _myDevicesLoading = false;
  bool _myDevicesLoaded = false; // 로드 완료 플래그
  String? _lastUserPkid; // 마지막 로드한 userPkid
  
  // API 기반 최근 세션 목록
  List<RecentSession> _recentSessions = [];
  bool _recentSessionsLoading = false;
  bool _recentSessionsLoaded = false;
  
  // 최근 세션 온라인 상태 (peerId -> online)
  Map<String, bool> _recentSessionsOnline = {};

  @override
  void initState() {
    super.initState();
    // 데이터 로드
    _loadAllPeers();
    // 나의 관리장치 로드
    _loadMyDevices();
    // API 기반 최근 세션 로드
    _loadRecentSessions();
    // 온라인 상태 업데이트 이벤트 핸들러 등록
    platformFFI.registerEventHandler('callback_query_onlines', 'peer_tree_view', (evt) async {
      _updateOnlineState(evt);
    });
  }
  
  @override
  void dispose() {
    platformFFI.unregisterEventHandler('callback_query_onlines', 'peer_tree_view');
    super.dispose();
  }
  
  /// 온라인 상태 업데이트 (나의 관리장치 + 최근 세션)
  void _updateOnlineState(Map<String, dynamic> evt) {
    bool changed = false;
    final onlines = (evt['onlines'] as String? ?? '').split(',');
    final offlines = (evt['offlines'] as String? ?? '').split(',');
    
    // 나의 관리장치 온라인 상태 업데이트
    for (var i = 0; i < _myDevices.length; i++) {
      final peer = _myDevices[i];
      if (onlines.contains(peer.id) && !peer.online) {
        _myDevices[i].online = true;
        changed = true;
      } else if (offlines.contains(peer.id) && peer.online) {
        _myDevices[i].online = false;
        changed = true;
      }
    }
    
    // 최근 세션 온라인 상태 업데이트
    for (var session in _recentSessions) {
      final peerId = session.peerId;
      if (onlines.contains(peerId)) {
        if (_recentSessionsOnline[peerId] != true) {
          _recentSessionsOnline[peerId] = true;
          changed = true;
        }
      } else if (offlines.contains(peerId)) {
        if (_recentSessionsOnline[peerId] != false) {
          _recentSessionsOnline[peerId] = false;
          changed = true;
        }
      }
    }
    
    if (changed) {
      setState(() {});
    }
  }

  void _loadAllPeers() {
    bind.mainLoadRecentPeers();
    bind.mainLoadFavPeers();
    gFFI.abModel.pullAb(force: ForcePullAb.listAndCurrent, quiet: true);
  }
  
  /// API 기반 최근 세션 목록 로드
  Future<void> _loadRecentSessions({bool force = false}) async {
    if (!gFFI.userModel.isLogin) {
      setState(() {
        _recentSessions = [];
        _recentSessionsLoaded = false;
      });
      return;
    }
    
    // 이미 로드되었고 강제 로드가 아니면 스킵
    if (!force && _recentSessionsLoaded && !_recentSessionsLoading) {
      return;
    }
    
    // 이미 로딩 중이면 스킵
    if (_recentSessionsLoading) {
      return;
    }
    
    setState(() {
      _recentSessionsLoading = true;
    });
    
    try {
      final apiServer = await bind.mainGetApiServer();
      final accessToken = bind.mainGetLocalOption(key: 'access_token');
      final userId = gFFI.userModel.userName.value;
      
      if (apiServer.isEmpty || accessToken.isEmpty || userId.isEmpty) {
        setState(() {
          _recentSessions = [];
          _recentSessionsLoading = false;
          _recentSessionsLoaded = false;
        });
        return;
      }
      
      final response = await recentSessionService.getRecentSessions(
        apiServer: apiServer,
        accessToken: accessToken,
        userId: userId,
        limit: 5,
      );
      
      // 401 응답 처리 (토큰 무효화)
      if (response.isUnauthorized) {
        debugPrint('PeerTreeView: 401 Unauthorized on recent sessions');
        await gFFI.userModel.reset(resetOther: true);
        if (mounted) {
          showToast('비밀번호가 변경되어 다시 로그인해주세요');
          Future.delayed(const Duration(milliseconds: 500), () {
            if (mounted) {
              loginDialog();
            }
          });
        }
        setState(() {
          _recentSessions = [];
          _recentSessionsLoading = false;
          _recentSessionsLoaded = false;
        });
        return;
      }
      
      if (response.success) {
        setState(() {
          _recentSessions = response.data;
          _recentSessionsLoading = false;
          _recentSessionsLoaded = true;
        });
        debugPrint('PeerTreeView: Loaded ${response.data.length} recent sessions');
        
        // 최근 세션 PC들의 온라인 상태 쿼리
        if (response.data.isNotEmpty) {
          final peerIds = response.data.map((s) => s.peerId).toSet().toList();
          debugPrint('PeerTreeView: Querying online status for recent sessions: $peerIds');
          bind.queryOnlines(ids: peerIds);
        }
      } else {
        setState(() {
          _recentSessions = [];
          _recentSessionsLoading = false;
          _recentSessionsLoaded = false;
        });
      }
    } catch (e) {
      debugPrint('PeerTreeView: Error loading recent sessions: $e');
      setState(() {
        _recentSessions = [];
        _recentSessionsLoading = false;
        _recentSessionsLoaded = false;
      });
    }
  }
  
  /// 나의 관리장치 목록 로드
  Future<void> _loadMyDevices({bool force = false}) async {
    if (!gFFI.userModel.isLogin) {
      setState(() {
        _myDevices = [];
        _myDevicesLoaded = false;
        _lastUserPkid = null;
      });
      return;
    }
    
    final userPkid = gFFI.userModel.userPkid.value;
    
    // 이미 로드되었고 같은 userPkid이고 강제 로드가 아니면 스킵
    if (!force && _myDevicesLoaded && _lastUserPkid == userPkid && !_myDevicesLoading) {
      return;
    }
    
    // 이미 로딩 중이면 스킵
    if (_myDevicesLoading) {
      return;
    }
    
    setState(() {
      _myDevicesLoading = true;
    });
    
    try {
      final apiServer = await bind.mainGetApiServer();
      final accessToken = bind.mainGetLocalOption(key: 'access_token');
      
      if (apiServer.isEmpty || accessToken.isEmpty || userPkid.isEmpty) {
        setState(() {
          _myDevices = [];
          _myDevicesLoading = false;
          _myDevicesLoaded = false;
          _lastUserPkid = null;
        });
        return;
      }
      
      final response = await deviceRegisterService.getRegisteredDevices(
        apiServer: apiServer,
        accessToken: accessToken,
        userPkid: userPkid,
      );
      
      // 401 응답 처리 (토큰 무효화)
      if (response.isUnauthorized) {
        debugPrint('PeerTreeView: 401 Unauthorized - Token invalidated');
        await gFFI.userModel.reset(resetOther: true);
        if (mounted) {
          showToast('비밀번호가 변경되어 다시 로그인해주세요');
          Future.delayed(const Duration(milliseconds: 500), () {
            if (mounted) {
              loginDialog();
            }
          });
        }
        setState(() {
          _myDevices = [];
          _myDevicesLoading = false;
          _myDevicesLoaded = false;
          _lastUserPkid = null;
        });
        return;
      }
      
      if (response.success && response.data.isNotEmpty) {
        // RegisteredDevice를 Peer로 변환
        final peers = response.data.map((device) {
          // 디버그: alias 값 확인
          debugPrint('Device: remoteId=${device.remoteId}, alias=${device.alias}, hostname=${device.hostname}');
          
          // alias가 있으면 alias를 사용, 없으면 hostname, 그것도 없으면 remoteId
          final deviceAlias = device.alias.isNotEmpty 
              ? device.alias 
              : (device.hostname.isNotEmpty ? device.hostname : device.remoteId);
          
          return Peer(
            id: device.remoteId,
            hash: '',
            password: '',
            username: '',
            hostname: device.hostname.isNotEmpty ? device.hostname : device.remoteId,
            platform: device.platform.isNotEmpty ? device.platform : 'Unknown',
            alias: deviceAlias, // alias 우선 사용
            tags: [],
            forceAlwaysRelay: false,
            rdpPort: '',
            rdpUsername: '',
            loginName: '',
            device_group_name: '',
            note: '',
          )..online = device.isOnline;
        }).toList();
        
        setState(() {
          _myDevices = peers;
          _myDevicesLoading = false;
          _myDevicesLoaded = true;
          _lastUserPkid = userPkid;
        });
        
        // 온라인 상태 쿼리
        if (peers.isNotEmpty) {
          final peerIds = peers.map((p) => p.id).toList();
          bind.queryOnlines(ids: peerIds);
        }
      } else {
        setState(() {
          _myDevices = [];
          _myDevicesLoading = false;
          _myDevicesLoaded = true;
          _lastUserPkid = userPkid;
        });
      }
    } catch (e) {
      debugPrint('Error loading my devices: $e');
      setState(() {
        _myDevices = [];
        _myDevicesLoading = false;
        _myDevicesLoaded = false;
        _lastUserPkid = null;
      });
    }
  }

  /// 모든 피어의 온라인 상태를 쿼리
  void _queryAllOnlineStatus() {
    final Set<String> allPeerIds = {};
    
    // 최근 세션 피어 ID 수집
    for (final peer in gFFI.recentPeersModel.peers) {
      allPeerIds.add(peer.id);
    }
    
    // 즐겨찾기 피어 ID 수집
    for (final peer in gFFI.favoritePeersModel.peers) {
      allPeerIds.add(peer.id);
    }
    
    // 나의 관리장치 피어 ID 수집
    for (final peer in _myDevices) {
      allPeerIds.add(peer.id);
    }
    
    // 주소록 피어 ID 수집
    for (final peer in gFFI.abModel.current.peers) {
      allPeerIds.add(peer.id);
    }
    
    // 온라인 상태 쿼리
    if (allPeerIds.isNotEmpty) {
      bind.queryOnlines(ids: allPeerIds.toList());
    }
  }

  @override
  Widget build(BuildContext context) {
    return Obx(() {
      // 로그인 상태 확인 (Obx로 감싸서 자동 업데이트)
      final isLoggedIn = gFFI.userModel.isLogin;
      
      // 로그인 상태에서만 온라인 상태 쿼리 및 나의 관리장치 로드
      if (isLoggedIn) {
        final currentUserPkid = gFFI.userModel.userPkid.value;
        // userPkid가 변경되었거나 아직 로드되지 않았을 때만 로드
        if (currentUserPkid.isNotEmpty && (_lastUserPkid != currentUserPkid || !_myDevicesLoaded)) {
          WidgetsBinding.instance.addPostFrameCallback((_) {
            if (!_onlineQueried) {
              _onlineQueried = true;
              Future.delayed(Duration(milliseconds: 500), () {
                _queryAllOnlineStatus();
              });
            }
            // 나의 관리장치 로드 (한 번만)
            if (!_myDevicesLoading && (_lastUserPkid != currentUserPkid || !_myDevicesLoaded)) {
              _loadMyDevices();
            }
            // 최근 세션 로드
            if (!_recentSessionsLoading && !_recentSessionsLoaded) {
              _loadRecentSessions();
            }
          });
        } else if (!_onlineQueried) {
          WidgetsBinding.instance.addPostFrameCallback((_) {
            if (!_onlineQueried) {
              _onlineQueried = true;
              Future.delayed(Duration(milliseconds: 500), () {
                _queryAllOnlineStatus();
              });
            }
          });
        }
      } else {
        // 로그아웃 시 쿼리 상태 초기화 및 장치 목록 초기화
        _onlineQueried = false;
        if (_myDevices.isNotEmpty || _myDevicesLoaded || _recentSessions.isNotEmpty || _recentSessionsLoaded) {
          // 빌드 중 setState 호출 방지 - addPostFrameCallback 사용
          WidgetsBinding.instance.addPostFrameCallback((_) {
            if (mounted && (_myDevices.isNotEmpty || _myDevicesLoaded || _recentSessions.isNotEmpty || _recentSessionsLoaded)) {
              setState(() {
                _myDevices = [];
                _myDevicesLoaded = false;
                _lastUserPkid = null;
                _recentSessions = [];
                _recentSessionsLoaded = false;
                _recentSessionsOnline = {};
              });
            }
          });
        }
      }
      
      return Container(
        color: Theme.of(context).brightness == Brightness.dark 
            ? Colors.grey.shade900 
            : Colors.white,
        child: Column(
          children: [
            // 검색 바
            _buildSearchBar(),
            // 컬럼 헤더
            _buildColumnHeader(),
            // 트리뷰 목록
            Expanded(
              child: isLoggedIn 
                  ? SingleChildScrollView(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          _buildRecentSessionsCategory(),  // API 기반 최근 세션 (로컬 대체)
                          _buildFavoritesCategory(),
                          _buildMyDevicesCategory(),
                          _buildAddressBookCategory(),
                        ],
                      ),
                    )
                  : _buildLoginRequiredMessage(),
            ),
          ],
        ),
      );
    });
  }

  /// 로그인 필요 메시지 위젯
  Widget _buildLoginRequiredMessage() {
    return Center(
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Icon(
            Icons.lock_outline,
            size: 48,
            color: Colors.grey.shade400,
          ),
          SizedBox(height: 16),
          Text(
            translate('Login required'),
            style: TextStyle(
              fontSize: 16,
              fontWeight: FontWeight.w500,
              color: Colors.grey.shade600,
            ),
          ),
          SizedBox(height: 8),
          Text(
            translate('Please login to view your peers'),
            style: TextStyle(
              fontSize: 13,
              color: Colors.grey.shade500,
            ),
            textAlign: TextAlign.center,
          ),
        ],
      ),
    );
  }

  Widget _buildSearchBar() {
    return Container(
      padding: EdgeInsets.symmetric(horizontal: 6, vertical: 4),
      color: Colors.grey.shade50,
      child: TextField(
        decoration: InputDecoration(
          hintText: translate('Search'),
          hintStyle: TextStyle(fontSize: 12, color: Colors.grey.shade500),
          prefixIcon: Icon(Icons.search, size: 16, color: Colors.grey.shade500),
          isDense: true,
          filled: true,
          fillColor: Colors.white,
          contentPadding: EdgeInsets.symmetric(horizontal: 8, vertical: 6),
          border: OutlineInputBorder(
            borderRadius: BorderRadius.circular(3),
            borderSide: BorderSide(color: Colors.grey.shade300),
          ),
          enabledBorder: OutlineInputBorder(
            borderRadius: BorderRadius.circular(3),
            borderSide: BorderSide(color: Colors.grey.shade300),
          ),
          focusedBorder: OutlineInputBorder(
            borderRadius: BorderRadius.circular(3),
            borderSide: BorderSide(color: Colors.blue.shade400),
          ),
        ),
        style: TextStyle(fontSize: 12),
        onChanged: (value) {
          setState(() {
            _searchQuery = value.toLowerCase();
          });
        },
      ),
    );
  }

  /// 컬럼 헤더 빌드 (팀뷰어 스타일)
  Widget _buildColumnHeader() {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    return Container(
      padding: EdgeInsets.symmetric(horizontal: 8, vertical: 5),
      decoration: BoxDecoration(
        color: isDark ? Colors.grey.shade800 : Colors.grey.shade100,
        border: Border(
          bottom: BorderSide(color: Colors.grey.shade300, width: 1),
        ),
      ),
      child: Row(
        children: [
          // 이름 컬럼
          Expanded(
            flex: 5,
            child: Text(
              translate('Name'),
              style: TextStyle(
                fontWeight: FontWeight.w600,
                fontSize: 11,
                color: isDark ? Colors.grey.shade400 : Colors.grey.shade600,
              ),
            ),
          ),
          // ID 컬럼
          Expanded(
            flex: 4,
            child: Text(
              'MDesk ID',
              style: TextStyle(
                fontWeight: FontWeight.w600,
                fontSize: 11,
                color: isDark ? Colors.grey.shade400 : Colors.grey.shade600,
              ),
            ),
          ),
          // 상태 컬럼
          SizedBox(
            width: 50,
            child: Text(
              translate('Status'),
              style: TextStyle(
                fontWeight: FontWeight.w600,
                fontSize: 11,
                color: isDark ? Colors.grey.shade400 : Colors.grey.shade600,
              ),
              textAlign: TextAlign.center,
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildCategoryHeader({
    required String title,
    required String categoryKey,
    required int itemCount,
    required IconData icon,
    required Color iconColor,
  }) {
    final isExpanded = _expandedCategories[categoryKey] ?? true;
    final isDark = Theme.of(context).brightness == Brightness.dark;
    
    return InkWell(
      onTap: () {
        setState(() {
          _expandedCategories[categoryKey] = !isExpanded;
        });
      },
      child: Container(
        padding: EdgeInsets.symmetric(horizontal: 6, vertical: 4),
        decoration: BoxDecoration(
          color: isDark ? Color(0xFF2A2A2A) : Colors.grey.shade50,
          border: Border(
            bottom: BorderSide(color: isDark ? Colors.grey.shade700 : Colors.grey.shade200, width: 0.5),
          ),
        ),
        child: Row(
          children: [
            Icon(
              isExpanded ? Icons.expand_more : Icons.chevron_right,
              size: 14,
              color: Colors.grey.shade500,
            ),
            SizedBox(width: 1),
            Icon(icon, size: 12, color: iconColor),
            SizedBox(width: 4),
            Text(
              title,
              style: TextStyle(
                fontWeight: FontWeight.w600,
                fontSize: 11,
                color: isDark ? Colors.grey.shade400 : Colors.grey.shade600,
              ),
            ),
            if (itemCount > 0) ...[
              SizedBox(width: 4),
              Text(
                '($itemCount)',
                style: TextStyle(
                  fontSize: 11,
                  color: Colors.grey.shade500,
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }

  Widget _buildPeerItem(Peer peer, TreeViewPeerType peerType) {
    final isOnline = peer.online;
    final isSelected = _selectedPeerId == peer.id;
    final isDark = Theme.of(context).brightness == Brightness.dark;
    // alias가 있으면 alias를 우선 표시, 없으면 hostname, 그것도 없으면 id
    final displayName = peer.alias.isNotEmpty 
        ? peer.alias 
        : (peer.hostname.isNotEmpty ? peer.hostname : peer.id);
    
    // 현재 기기인지 확인
    final myId = gFFI.serverModel.serverId.text.replaceAll(' ', '');
    final isCurrentDevice = peer.id.replaceAll(' ', '') == myId && myId.isNotEmpty;
    
    // 검색 필터
    if (_searchQuery.isNotEmpty) {
      final searchLower = _searchQuery.toLowerCase();
      if (!displayName.toLowerCase().contains(searchLower) &&
          !peer.id.toLowerCase().contains(searchLower)) {
        return SizedBox.shrink();
      }
    }
    
    return InkWell(
      onTap: () {
        setState(() {
          _selectedPeerId = peer.id;
        });
      },
      onDoubleTap: () {
        // 더블클릭으로 연결 (현재 기기가 아닐 때만)
        if (!isCurrentDevice) {
          connect(context, peer.id);
        }
      },
      onSecondaryTapDown: (details) {
        // 우클릭 메뉴 - 기존 PeerCard 메뉴 사용
        _showPeerContextMenu(context, details.globalPosition, peer, peerType);
      },
      child: Container(
        padding: EdgeInsets.only(left: 30, right: 8, top: 5, bottom: 5),
        decoration: BoxDecoration(
          color: isSelected 
              ? (isDark ? Colors.blue.shade900 : Colors.blue.shade50)
              : (isCurrentDevice ? (isDark ? Color(0xFF2D4A3D) : Colors.green.shade50) : null),
          border: Border(
            bottom: BorderSide(
              color: isDark ? Colors.grey.shade800 : Colors.grey.shade200,
              width: 0.5,
            ),
          ),
        ),
        child: Row(
          children: [
            // 이름 컬럼 (아이콘 + 이름)
            Expanded(
              flex: 5,
              child: Row(
                children: [
                  // 플랫폼 아이콘 (온라인: 녹색, 오프라인: 회색)
                  Container(
                    width: 18,
                    height: 18,
                    decoration: BoxDecoration(
                      color: isOnline ? Colors.green.shade600 : Colors.grey.shade500,
                      borderRadius: BorderRadius.circular(3),
                    ),
                    child: getPlatformImage(peer.platform, size: 12),
                  ),
                  SizedBox(width: 6),
                  // 이름
                  Expanded(
                    child: Row(
                      children: [
                        Flexible(
                          child: Text(
                            displayName.isNotEmpty ? displayName : peer.id,
                            style: TextStyle(
                              fontSize: 12,
                              fontWeight: FontWeight.w500,
                              color: isOnline 
                                  ? (isDark ? Colors.white : Colors.black87)
                                  : Colors.grey.shade500,
                            ),
                            overflow: TextOverflow.ellipsis,
                          ),
                        ),
                        // 현재 기기 표시
                        if (isCurrentDevice) ...[
                          SizedBox(width: 4),
                          Container(
                            padding: EdgeInsets.symmetric(horizontal: 4, vertical: 1),
                            decoration: BoxDecoration(
                              color: Colors.green.shade600,
                              borderRadius: BorderRadius.circular(3),
                            ),
                            child: Text(
                              '이 장치',
                              style: TextStyle(
                                fontSize: 9,
                                color: Colors.white,
                                fontWeight: FontWeight.w600,
                              ),
                            ),
                          ),
                        ],
                      ],
                    ),
                  ),
                ],
              ),
            ),
            // ID 컬럼
            Expanded(
              flex: 4,
              child: Text(
                _formatPeerId(peer.id),
                style: TextStyle(
                  fontSize: 12,
                  color: isDark ? Colors.grey.shade400 : Colors.grey.shade700,
                  fontFamily: 'monospace',
                ),
              ),
            ),
            // 상태 컬럼
            SizedBox(
              width: 50,
              child: Row(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  if (isOnline) ...[
                    Text(
                      'Online',
                      style: TextStyle(
                        fontSize: 11,
                        color: Colors.green.shade600,
                        fontWeight: FontWeight.w500,
                      ),
                    ),
                  ] else ...[
                    Text(
                      'Offline',
                      style: TextStyle(
                        fontSize: 11,
                        color: Colors.grey.shade500,
                      ),
                    ),
                  ],
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  /// 기존 PeerCard의 컨텍스트 메뉴를 표시
  void _showPeerContextMenu(BuildContext context, Offset position, Peer peer, TreeViewPeerType peerType) async {
    // 카테고리에 따라 적절한 PeerCard 생성
    BasePeerCard peerCard;
    switch (peerType) {
      case TreeViewPeerType.recent:
        peerCard = RecentPeerCard(peer: peer, menuPadding: widget.menuPadding);
        break;
      case TreeViewPeerType.favorite:
        peerCard = FavoritePeerCard(peer: peer, menuPadding: widget.menuPadding);
        break;
      case TreeViewPeerType.mydevices:
        peerCard = MyGroupPeerCard(peer: peer, menuPadding: widget.menuPadding);
        break;
      case TreeViewPeerType.addressbook:
        peerCard = AddressBookPeerCard(peer: peer, menuPadding: widget.menuPadding);
        break;
      case TreeViewPeerType.recentApi:
        // API 기반 최근 세션은 별도 처리 (이 메뉴는 호출되지 않음)
        peerCard = RecentPeerCard(peer: peer, menuPadding: widget.menuPadding);
        break;
    }
    
    // PeerCard의 팝업 메뉴 빌드 및 표시
    final menuItems = await peerCard.buildMenuItems(context);
    
    await mod_menu.showMenu(
      context: context,
      position: RelativeRect.fromLTRB(
        position.dx,
        position.dy,
        position.dx + 1,
        position.dy + 1,
      ),
      items: menuItems,
      elevation: 8,
    );
  }

  String _formatPeerId(String id) {
    // ID를 3자리씩 끊어서 공백으로 구분
    if (id.length <= 3) return id;
    final buffer = StringBuffer();
    for (var i = 0; i < id.length; i += 3) {
      if (i > 0) buffer.write(' ');
      buffer.write(id.substring(i, (i + 3) > id.length ? id.length : i + 3));
    }
    return buffer.toString();
  }

  Widget _buildRecentCategory() {
    return ChangeNotifierProvider<Peers>.value(
      value: gFFI.recentPeersModel,
      child: Consumer<Peers>(
        builder: (context, peers, child) {
          final peerList = peers.peers;
          final isExpanded = _expandedCategories['recent'] ?? true;
          
          return Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              _buildCategoryHeader(
                title: translate('Recent sessions'),
                categoryKey: 'recent',
                itemCount: peerList.length,
                icon: Icons.access_time,
                iconColor: Colors.blue,
              ),
              if (isExpanded)
                ...peerList.map((peer) => _buildPeerItem(peer, TreeViewPeerType.recent)).toList(),
            ],
          );
        },
      ),
    );
  }

  Widget _buildFavoritesCategory() {
    return ChangeNotifierProvider<Peers>.value(
      value: gFFI.favoritePeersModel,
      child: Consumer<Peers>(
        builder: (context, peers, child) {
          final peerList = peers.peers;
          final isExpanded = _expandedCategories['favorites'] ?? true;
          
          return Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              _buildCategoryHeader(
                title: translate('Favorites'),
                categoryKey: 'favorites',
                itemCount: peerList.length,
                icon: Icons.star,
                iconColor: Colors.amber,
              ),
              if (isExpanded)
                ...peerList.map((peer) => _buildPeerItem(peer, TreeViewPeerType.favorite)).toList(),
            ],
          );
        },
      ),
    );
  }

  Widget _buildMyDevicesCategory() {
    final isExpanded = _expandedCategories['mydevices'] ?? true;
    
    // 확장된 경우 표시할 위젯 리스트 생성
    List<Widget> expandedWidgets = [];
    if (isExpanded) {
      if (_myDevicesLoading) {
        expandedWidgets.add(
          Padding(
            padding: EdgeInsets.all(16),
            child: Center(
              child: CircularProgressIndicator(strokeWidth: 2),
            ),
          ),
        );
      } else if (_myDevices.isEmpty) {
        expandedWidgets.add(
          Padding(
            padding: EdgeInsets.symmetric(horizontal: 12, vertical: 8),
            child: Text(
              translate('No devices registered'),
              style: TextStyle(
                fontSize: 12,
                color: Colors.grey.shade500,
                fontStyle: FontStyle.italic,
              ),
            ),
          ),
        );
      } else {
        expandedWidgets.addAll(
          _myDevices.map((peer) => _buildPeerItem(peer, TreeViewPeerType.mydevices)),
        );
      }
    }
    
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        _buildCategoryHeader(
          title: translate('My Devices'),
          categoryKey: 'mydevices',
          itemCount: _myDevices.length,
          icon: Icons.devices,
          iconColor: Colors.purple,
        ),
        ...expandedWidgets,
      ],
    );
  }

  Widget _buildAddressBookCategory() {
    final abModel = gFFI.abModel;
    return Obx(() {
      final currentAb = abModel.current;
      final peers = currentAb.peers;
      final isExpanded = _expandedCategories['addressbook'] ?? true;
      
      return Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          _buildCategoryHeader(
            title: translate('Address book'),
            categoryKey: 'addressbook',
            itemCount: peers.length,
            icon: Icons.contacts,
            iconColor: Colors.green,
          ),
          if (isExpanded)
            ...peers.map((peer) => _buildPeerItem(peer, TreeViewPeerType.addressbook)).toList(),
        ],
      );
    });
  }
  
  /// API 기반 최근 세션 카테고리 빌드
  Widget _buildRecentSessionsCategory() {
    final isExpanded = _expandedCategories['recentApi'] ?? true;
    
    // 확장된 경우 표시할 위젯 리스트 생성
    List<Widget> expandedWidgets = [];
    if (isExpanded) {
      if (_recentSessionsLoading) {
        expandedWidgets.add(
          Padding(
            padding: EdgeInsets.all(16),
            child: Center(
              child: CircularProgressIndicator(strokeWidth: 2),
            ),
          ),
        );
      } else if (_recentSessions.isEmpty) {
        expandedWidgets.add(
          Padding(
            padding: EdgeInsets.symmetric(horizontal: 12, vertical: 8),
            child: Text(
              '최근 연결 기록이 없습니다',
              style: TextStyle(
                fontSize: 12,
                color: Colors.grey.shade500,
                fontStyle: FontStyle.italic,
              ),
            ),
          ),
        );
      } else {
        expandedWidgets.addAll(
          _recentSessions.map((session) => _buildSessionItem(session)),
        );
      }
    }
    
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        _buildCategoryHeader(
          title: '최근 세션',
          categoryKey: 'recentApi',
          itemCount: _recentSessions.length,
          icon: Icons.access_time,
          iconColor: Colors.blue,
        ),
        ...expandedWidgets,
      ],
    );
  }
  
  /// 세션 항목 빌드 (나의 관리장치 스타일)
  Widget _buildSessionItem(RecentSession session) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final isSelected = _selectedPeerId == session.peerId;
    
    // 표시 이름 (alias > hostname > id)
    final displayName = session.displayName;
    
    // 최근 세션 온라인 상태 확인
    final isOnline = _recentSessionsOnline[session.peerId] ?? false;
    
    // 검색 필터
    if (_searchQuery.isNotEmpty) {
      final searchLower = _searchQuery.toLowerCase();
      if (!displayName.toLowerCase().contains(searchLower) &&
          !session.peerId.toLowerCase().contains(searchLower)) {
        return SizedBox.shrink();
      }
    }
    
    return InkWell(
      onTap: () {
        setState(() {
          _selectedPeerId = session.peerId;
        });
      },
      onDoubleTap: () {
        // 더블클릭으로 연결
        connect(context, session.peerId);
      },
      onSecondaryTapDown: (details) {
        // 우클릭 메뉴 - RecentSession에서 Peer 생성
        final peer = Peer(
          id: session.peerId,
          hash: '',
          password: '',
          username: '',
          hostname: session.hostname,
          platform: '',
          alias: session.alias,
          tags: [],
          forceAlwaysRelay: false,
          rdpPort: '',
          rdpUsername: '',
          loginName: '',
          device_group_name: '',
          note: '',
        )..online = isOnline;
        _showPeerContextMenu(context, details.globalPosition, peer, TreeViewPeerType.recentApi);
      },
      child: Container(
        padding: EdgeInsets.only(left: 30, right: 8, top: 5, bottom: 5),
        decoration: BoxDecoration(
          color: isSelected 
              ? (isDark ? Colors.blue.shade900 : Colors.blue.shade50)
              : Colors.transparent,
          border: Border(
            bottom: BorderSide(
              color: isDark ? Colors.grey.shade800 : Colors.grey.shade200, 
              width: 0.5
            ),
          ),
        ),
        child: Row(
          children: [
            // 이름 컬럼 (아이콘 + 이름)
            Expanded(
              flex: 5,
              child: Row(
                children: [
                  // 아이콘 (온라인: 녹색, 오프라인: 회색)
                  Container(
                    width: 18,
                    height: 18,
                    decoration: BoxDecoration(
                      color: isOnline ? Colors.green.shade600 : Colors.grey.shade500,
                      borderRadius: BorderRadius.circular(3),
                    ),
                    child: Icon(
                      Icons.history,
                      size: 12,
                      color: Colors.white,
                    ),
                  ),
                  SizedBox(width: 6),
                  // 이름 (alias > hostname > id)
                  Expanded(
                    child: Text(
                      displayName,
                      style: TextStyle(
                        fontSize: 12,
                        fontWeight: FontWeight.w500,
                        color: isOnline 
                            ? (isDark ? Colors.white : Colors.black87)
                            : Colors.grey.shade500,
                      ),
                      overflow: TextOverflow.ellipsis,
                    ),
                  ),
                ],
              ),
            ),
            // ID 컬럼
            Expanded(
              flex: 4,
              child: Text(
                _formatPeerId(session.peerId),
                style: TextStyle(
                  fontSize: 12,
                  color: isOnline 
                      ? (isDark ? Colors.white70 : Colors.black54)
                      : Colors.grey.shade500,
                ),
              ),
            ),
            // 상태 컬럼 (Online/Offline 텍스트)
            SizedBox(
              width: 50,
              child: Text(
                isOnline ? 'Online' : 'Offline',
                style: TextStyle(
                  fontSize: 11,
                  color: isOnline ? Colors.green.shade600 : Colors.grey.shade500,
                  fontWeight: isOnline ? FontWeight.w500 : FontWeight.normal,
                ),
                textAlign: TextAlign.center,
              ),
            ),
          ],
        ),
      ),
    );
  }
}
