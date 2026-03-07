import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:get/get.dart';
import 'package:flutter_hbb/common.dart';
import 'package:flutter_hbb/models/model.dart';
import 'package:flutter_hbb/models/platform_model.dart';

/// 화이트보드 메시지 접두사 (채팅과 구분용)
const String kWhiteboardPrefix = '##WB##';

/// 화이트보드 그리기 도구 종류
enum WhiteboardTool {
  pen,
  highlighter,
  eraser,
  text,
  arrow,
  rectangle,
  ellipse,
}

/// 그리기 스트로크 데이터
class DrawingStroke {
  final List<Offset> points;
  final Color color;
  final double strokeWidth;
  final WhiteboardTool tool;
  final bool isEraser;

  DrawingStroke({
    required this.points,
    required this.color,
    required this.strokeWidth,
    required this.tool,
    this.isEraser = false,
  });
  
  /// JSON 직렬화
  Map<String, dynamic> toJson() {
    return {
      'points': points.map((p) => {'x': p.dx, 'y': p.dy}).toList(),
      'color': color.value,
      'strokeWidth': strokeWidth,
      'tool': tool.index,
      'isEraser': isEraser,
    };
  }
  
  /// JSON 역직렬화
  factory DrawingStroke.fromJson(Map<String, dynamic> json) {
    return DrawingStroke(
      points: (json['points'] as List)
          .map((p) => Offset(p['x'].toDouble(), p['y'].toDouble()))
          .toList(),
      color: Color(json['color']),
      strokeWidth: json['strokeWidth'].toDouble(),
      tool: WhiteboardTool.values[json['tool']],
      isEraser: json['isEraser'] ?? false,
    );
  }
}

/// 화이트보드 컨트롤러
class WhiteboardController extends GetxController {
  final RxBool isEnabled = false.obs;
  final RxList<DrawingStroke> strokes = <DrawingStroke>[].obs;
  final Rx<WhiteboardTool> currentTool = WhiteboardTool.pen.obs;
  final Rx<Color> currentColor = Colors.red.obs;
  final RxDouble currentStrokeWidth = 3.0.obs;
  
  // 현재 그리고 있는 스트로크
  final RxList<Offset> currentPoints = <Offset>[].obs;
  
  // 세션 정보 (데이터 전송용)
  SessionID? sessionId;
  
  // 캔버스 크기 (화면에 그리는 용도)
  Size canvasSize = Size.zero;
  
  // 원격 화면 해상도 (좌표 정규화용) - 피제어자 화면 크기
  Size remoteDisplaySize = Size.zero;
  
  // 캔버스에서 원격 화면이 그려지는 영역 (오프셋 및 스케일 고려)
  Rect remoteDisplayRect = Rect.zero;
  
  // 색상 팔레트
  final List<Color> colorPalette = [
    Colors.grey,
    Colors.red,
    Colors.orange,
    Colors.yellow,
    Colors.green,
    Colors.blue,    
    Colors.purple,    
  ];
  
  /// 세션 ID 설정
  void setSessionId(SessionID? id) {
    sessionId = id;
  }
  
  /// 캔버스 크기 설정
  void setCanvasSize(Size size) {
    canvasSize = size;
  }
  
  /// 원격 화면 해상도 설정
  void setRemoteDisplaySize(double width, double height) {
    remoteDisplaySize = Size(width, height);
    debugPrint('Whiteboard: Remote display size set to ${width}x${height}');
  }
  
  /// 원격 화면이 캔버스에서 그려지는 영역 설정
  void setRemoteDisplayRect(Rect rect) {
    // 영역이 변경되면 제어자 측 그림만 지우기 (피제어자 측은 유지)
    if (remoteDisplayRect.width > 0 && remoteDisplayRect.height > 0) {
      final widthDiff = (rect.width - remoteDisplayRect.width).abs();
      final heightDiff = (rect.height - remoteDisplayRect.height).abs();
      // 크기가 1픽셀 이상 변경되면 제어자 측 그림 지우기
      if (widthDiff >= 1 || heightDiff >= 1) {
        clearLocalOnly();
      }
    }
    remoteDisplayRect = rect;
  }
  
  /// 제어자 화면의 그림만 지우기 (피제어자에게 전송하지 않음)
  void clearLocalOnly() {
    strokes.clear();
    currentPoints.clear();
    debugPrint('Whiteboard: Local strokes cleared due to resize');
  }
  
  void toggle() {
    isEnabled.value = !isEnabled.value;
    if (!isEnabled.value) {
      // 화이트보드 끄면 모든 그림 지우기
      clear();
    }
    // 상태 변경 전송
    _sendWhiteboardState();
  }
  
  void setTool(WhiteboardTool tool) {
    currentTool.value = tool;
  }
  
  void setColor(Color color) {
    currentColor.value = color;
  }
  
  void setStrokeWidth(double width) {
    currentStrokeWidth.value = width;
  }
  
  void startStroke(Offset point) {
    currentPoints.clear();
    currentPoints.add(point);
  }
  
  void addPoint(Offset point) {
    currentPoints.add(point);
  }
  
  void endStroke() {
    if (currentPoints.isNotEmpty) {
      final isEraser = currentTool.value == WhiteboardTool.eraser;
      final stroke = DrawingStroke(
        points: List.from(currentPoints),
        color: isEraser ? Colors.transparent : currentColor.value,
        strokeWidth: isEraser ? currentStrokeWidth.value * 3 : currentStrokeWidth.value,
        tool: currentTool.value,
        isEraser: isEraser,
      );
      strokes.add(stroke);
      currentPoints.clear();
      
      // 스트로크 전송
      _sendStroke(stroke);
    }
  }
  
  void clear() {
    strokes.clear();
    currentPoints.clear();
    // 클리어 명령 전송
    _sendClearCommand();
  }
  
  void undo() {
    if (strokes.isNotEmpty) {
      strokes.removeLast();
      // 실행취소 명령 전송
      _sendUndoCommand();
    }
  }
  
  /// 화이트보드 상태 전송
  void _sendWhiteboardState() {
    if (sessionId == null) return;
    
    final data = {
      'type': 'state',
      'enabled': isEnabled.value,
    };
    _sendData(data);
  }
  
  /// 캔버스 좌표를 원격 화면 좌표로 변환 (정규화)
  Map<String, double>? _normalizePoint(Offset canvasPoint) {
    // 원격 화면 영역이 설정되어 있으면 사용
    if (remoteDisplayRect.width > 0 && remoteDisplayRect.height > 0) {
      // 캔버스 좌표를 원격 화면 영역 내의 상대 좌표로 변환
      final relativeX = canvasPoint.dx - remoteDisplayRect.left;
      final relativeY = canvasPoint.dy - remoteDisplayRect.top;
      
      // 원격 화면 영역 밖이면 null 반환
      if (relativeX < 0 || relativeY < 0 ||
          relativeX > remoteDisplayRect.width ||
          relativeY > remoteDisplayRect.height) {
        return null;
      }
      
      // 정규화 (0~1 범위)
      return {
        'x': relativeX / remoteDisplayRect.width,
        'y': relativeY / remoteDisplayRect.height,
      };
    }
    
    // 원격 화면 해상도가 설정되어 있으면 사용 (fallback)
    if (remoteDisplaySize.width > 0 && remoteDisplaySize.height > 0) {
      // 캔버스 크기와 원격 화면 크기의 비율 계산
      final scaleX = canvasSize.width / remoteDisplaySize.width;
      final scaleY = canvasSize.height / remoteDisplaySize.height;
      final scale = scaleX < scaleY ? scaleX : scaleY;
      
      // 원격 화면이 캔버스에서 그려지는 위치 계산 (중앙 정렬 가정)
      final displayWidth = remoteDisplaySize.width * scale;
      final displayHeight = remoteDisplaySize.height * scale;
      final offsetX = (canvasSize.width - displayWidth) / 2;
      final offsetY = (canvasSize.height - displayHeight) / 2;
      
      // 캔버스 좌표를 원격 화면 좌표로 변환
      final remoteX = (canvasPoint.dx - offsetX) / scale;
      final remoteY = (canvasPoint.dy - offsetY) / scale;
      
      // 정규화 (0~1 범위)
      return {
        'x': remoteX / remoteDisplaySize.width,
        'y': remoteY / remoteDisplaySize.height,
      };
    }
    
    // fallback: 캔버스 크기 기준 정규화
    return {
      'x': canvasSize.width > 0 ? canvasPoint.dx / canvasSize.width : canvasPoint.dx,
      'y': canvasSize.height > 0 ? canvasPoint.dy / canvasSize.height : canvasPoint.dy,
    };
  }
  
  /// 스트로크 전송
  void _sendStroke(DrawingStroke stroke) {
    if (sessionId == null || !isEnabled.value) return;
    
    // 좌표를 원격 화면 기준으로 정규화 (0~1 범위)
    final normalizedPoints = stroke.points
        .map((p) => _normalizePoint(p))
        .where((p) => p != null)
        .toList();
    
    if (normalizedPoints.isEmpty) return;
    
    final data = {
      'type': 'stroke',
      'points': normalizedPoints,
      'color': stroke.color.value,
      'strokeWidth': stroke.strokeWidth,
      'tool': stroke.tool.index,
      'isEraser': stroke.isEraser,
    };
    _sendData(data);
  }
  
  /// 클리어 명령 전송
  void _sendClearCommand() {
    if (sessionId == null) return;
    
    final data = {'type': 'clear'};
    _sendData(data);
  }
  
  /// 실행취소 명령 전송
  void _sendUndoCommand() {
    if (sessionId == null) return;
    
    final data = {'type': 'undo'};
    _sendData(data);
  }
  
  /// 데이터 전송 (채팅 메시지 활용)
  void _sendData(Map<String, dynamic> data) {
    if (sessionId == null) return;
    
    try {
      final jsonStr = jsonEncode(data);
      final message = '$kWhiteboardPrefix$jsonStr';
      bind.sessionSendChat(sessionId: sessionId!, text: message);
      debugPrint('Whiteboard: Sent data: $message');
    } catch (e) {
      debugPrint('Whiteboard: Failed to send data: $e');
    }
  }
}

/// 피제어자용 화이트보드 수신 컨트롤러
class WhiteboardReceiverController extends GetxController {
  final RxBool isEnabled = false.obs;
  final RxList<DrawingStroke> strokes = <DrawingStroke>[].obs;
  
  // 캔버스 크기 (좌표 역정규화용)
  Size canvasSize = Size.zero;
  
  /// 캔버스 크기 설정
  void setCanvasSize(Size size) {
    canvasSize = size;
  }
  
  /// 화이트보드 메시지 처리
  bool handleMessage(String text) {
    if (!text.startsWith(kWhiteboardPrefix)) {
      return false;
    }
    
    try {
      final jsonStr = text.substring(kWhiteboardPrefix.length);
      final data = jsonDecode(jsonStr) as Map<String, dynamic>;
      
      switch (data['type']) {
        case 'state':
          isEnabled.value = data['enabled'] ?? false;
          if (!isEnabled.value) {
            strokes.clear();
          }
          break;
        case 'stroke':
          _handleStroke(data);
          break;
        case 'clear':
          strokes.clear();
          break;
        case 'undo':
          if (strokes.isNotEmpty) {
            strokes.removeLast();
          }
          break;
      }
      
      debugPrint('Whiteboard: Received command: ${data['type']}');
      return true;
    } catch (e) {
      debugPrint('Whiteboard: Failed to parse message: $e');
      return false;
    }
  }
  
  /// 스트로크 처리
  void _handleStroke(Map<String, dynamic> data) {
    // 정규화된 좌표를 실제 좌표로 변환
    final points = (data['points'] as List).map((p) {
      final x = (p['x'] as num).toDouble() * canvasSize.width;
      final y = (p['y'] as num).toDouble() * canvasSize.height;
      return Offset(x, y);
    }).toList();
    
    final stroke = DrawingStroke(
      points: points,
      color: Color(data['color']),
      strokeWidth: (data['strokeWidth'] as num).toDouble(),
      tool: WhiteboardTool.values[data['tool']],
      isEraser: data['isEraser'] ?? false,
    );
    
    strokes.add(stroke);
  }
  
  void clear() {
    strokes.clear();
    isEnabled.value = false;
  }
}

/// 화이트보드 오버레이 위젯
class WhiteboardOverlay extends StatelessWidget {
  final WhiteboardController controller;
  final FFI? ffi;
  
  const WhiteboardOverlay({
    Key? key,
    required this.controller,
    this.ffi,
  }) : super(key: key);
  
  /// 원격 화면이 캔버스에서 그려지는 영역 계산
  Rect _calculateRemoteDisplayRect(Size canvasSize) {
    if (ffi == null) return Rect.zero;
    
    try {
      final canvasModel = ffi!.canvasModel;
      final displays = ffi!.ffiModel.pi.getCurDisplays();
      
      if (displays.isEmpty) return Rect.zero;
      
      final display = displays[0];
      final displayWidth = display.width.toDouble();
      final displayHeight = display.height.toDouble();
      
      // 스케일과 오프셋 가져오기
      final scale = canvasModel.scale;
      final x = canvasModel.x;
      final y = canvasModel.y;
      
      // 원격 화면이 캔버스에서 그려지는 영역
      return Rect.fromLTWH(
        x,
        y,
        displayWidth * scale,
        displayHeight * scale,
      );
    } catch (e) {
      debugPrint('Whiteboard: Failed to calculate remote display rect: $e');
      return Rect.zero;
    }
  }
  
  @override
  Widget build(BuildContext context) {
    return Obx(() {
      if (!controller.isEnabled.value) {
        return const SizedBox.shrink();
      }
      
      return Stack(
        children: [
          // 그리기 캔버스
          Positioned.fill(
            child: LayoutBuilder(
              builder: (context, constraints) {
                final canvasSize = Size(constraints.maxWidth, constraints.maxHeight);
                
                // 캔버스 크기 및 원격 화면 영역 업데이트
                WidgetsBinding.instance.addPostFrameCallback((_) {
                  controller.setCanvasSize(canvasSize);
                  
                  // 원격 화면 영역 계산 및 설정
                  final remoteRect = _calculateRemoteDisplayRect(canvasSize);
                  if (remoteRect.width > 0 && remoteRect.height > 0) {
                    controller.setRemoteDisplayRect(remoteRect);
                  }
                });
                
                return GestureDetector(
                  onPanStart: (details) {
                    controller.startStroke(details.localPosition);
                  },
                  onPanUpdate: (details) {
                    controller.addPoint(details.localPosition);
                  },
                  onPanEnd: (details) {
                    controller.endStroke();
                  },
                  child: Obx(() => CustomPaint(
                    painter: WhiteboardPainter(
                      strokes: controller.strokes.toList(),
                      currentPoints: controller.currentPoints.toList(),
                      currentColor: controller.currentColor.value,
                      currentStrokeWidth: controller.currentStrokeWidth.value,
                      currentTool: controller.currentTool.value,
                    ),
                    size: Size.infinite,
                  )),
                );
              },
            ),
          ),
          
          // 툴바
          Positioned(
            left: 10,
            top: 60,
            child: _buildToolbar(context),
          ),
        ],
      );
    });
  }
  
  Widget _buildToolbar(BuildContext context) {
    return Obx(() => Container(
      padding: const EdgeInsets.all(8),
      constraints: BoxConstraints(
        maxHeight: MediaQuery.of(context).size.height - 120, // 화면 높이 제한
      ),
      decoration: BoxDecoration(
        color: Colors.black.withOpacity(0.8),
        borderRadius: BorderRadius.circular(8),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withOpacity(0.3),
            blurRadius: 10,
            offset: const Offset(0, 2),
          ),
        ],
      ),
      child: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            // 도구 선택
            _buildToolButton(
              icon: Icons.edit,
              tool: WhiteboardTool.pen,
              tooltip: '펜',
            ),
            const SizedBox(height: 4),
            _buildToolButton(
              icon: Icons.brush,
              tool: WhiteboardTool.highlighter,
              tooltip: '형광펜',
            ),
            const SizedBox(height: 4),
            _buildToolButton(
              icon: Icons.auto_fix_high,
              tool: WhiteboardTool.eraser,
              tooltip: '지우개',
            ),
          
          const Padding(
            padding: EdgeInsets.symmetric(vertical: 8),
            child: Divider(color: Colors.white24, height: 1),
          ),
          
          // 색상 선택
          ...controller.colorPalette.map((color) => Padding(
            padding: const EdgeInsets.only(bottom: 4),
            child: _buildColorButton(color),
          )).toList(),
          
          const Padding(
            padding: EdgeInsets.symmetric(vertical: 8),
            child: Divider(color: Colors.white24, height: 1),
          ),
          
          // 선 두께
          _buildStrokeWidthButton(2.0, '가늘게'),
          const SizedBox(height: 4),
          _buildStrokeWidthButton(4.0, '보통'),
          const SizedBox(height: 4),
          _buildStrokeWidthButton(8.0, '굵게'),
          
          const Padding(
            padding: EdgeInsets.symmetric(vertical: 8),
            child: Divider(color: Colors.white24, height: 1),
          ),
          
          // 실행 취소
          IconButton(
            onPressed: controller.undo,
            icon: const Icon(Icons.undo, color: Colors.white, size: 20),
            tooltip: '실행 취소',
            padding: EdgeInsets.zero,
            constraints: const BoxConstraints(minWidth: 32, minHeight: 32),
          ),
          
          // 전체 지우기
          IconButton(
            onPressed: controller.clear,
            icon: const Icon(Icons.delete_outline, color: Colors.white, size: 20),
            tooltip: '전체 지우기',
            padding: EdgeInsets.zero,
            constraints: const BoxConstraints(minWidth: 32, minHeight: 32),
          ),
          
          // 닫기
          IconButton(
            onPressed: controller.toggle,
            icon: const Icon(Icons.close, color: Colors.red, size: 20),
            tooltip: '화이트보드 닫기',
            padding: EdgeInsets.zero,
            constraints: const BoxConstraints(minWidth: 32, minHeight: 32),
          ),
        ],
        ),
      ),
    ));
  }
  
  Widget _buildToolButton({
    required IconData icon,
    required WhiteboardTool tool,
    required String tooltip,
  }) {
    final isSelected = controller.currentTool.value == tool;
    return Tooltip(
      message: tooltip,
      child: GestureDetector(
        onTap: () {
          debugPrint('Tool button tapped: $tool');
          controller.setTool(tool);
        },
        child: Container(
          width: 32,
          height: 32,
          decoration: BoxDecoration(
            color: isSelected ? Colors.blue : Colors.transparent,
            borderRadius: BorderRadius.circular(4),
          ),
          child: Icon(
            icon,
            color: Colors.white,
            size: 20,
          ),
        ),
      ),
    );
  }
  
  Widget _buildColorButton(Color color) {
    final isSelected = controller.currentColor.value.value == color.value;
    // 검정색과 흰색은 특별히 테두리 처리
    final isBlack = color.value == Colors.grey.value;
    final isWhite = color.value == Colors.grey.shade300.value;
    
    return Tooltip(
      message: '색상',
      child: InkWell(
        onTap: () {
          debugPrint('Color button tapped: 0x${color.value.toRadixString(16)}');
          controller.setColor(color);
          // 색상 선택 시 펜 도구로 자동 전환 (지우개 상태면)
          if (controller.currentTool.value == WhiteboardTool.eraser) {
            controller.setTool(WhiteboardTool.pen);
          }
        },
        child: Container(
          width: 32,
          height: 32,
          decoration: BoxDecoration(
            color: color,
            borderRadius: BorderRadius.circular(4),
            border: Border.all(
              // 검정색은 흰색 테두리, 흰색은 회색 테두리로 항상 표시
              color: isSelected 
                  ? Colors.blue 
                  : (isBlack ? Colors.white54 : (isWhite ? Colors.grey : Colors.white24)),
              width: isSelected ? 3 : (isBlack || isWhite ? 2 : 1),
            ),
          ),
        ),
      ),
    );
  }
  
  Widget _buildStrokeWidthButton(double width, String tooltip) {
    final isSelected = (controller.currentStrokeWidth.value - width).abs() < 0.5;
    return Tooltip(
      message: tooltip,
      child: GestureDetector(
        onTap: () => controller.setStrokeWidth(width),
        child: Container(
          width: 32,
          height: 32,
          decoration: BoxDecoration(
            color: isSelected ? Colors.blue.withOpacity(0.3) : Colors.transparent,
            borderRadius: BorderRadius.circular(4),
            border: Border.all(
              color: isSelected ? Colors.blue : Colors.transparent,
              width: 1,
            ),
          ),
          child: Center(
            child: Container(
              width: width * 3,
              height: width * 3,
              decoration: BoxDecoration(
                color: Colors.white,
                shape: BoxShape.circle,
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// 화이트보드 페인터
class WhiteboardPainter extends CustomPainter {
  final List<DrawingStroke> strokes;
  final List<Offset> currentPoints;
  final Color currentColor;
  final double currentStrokeWidth;
  final WhiteboardTool currentTool;
  
  WhiteboardPainter({
    required this.strokes,
    required this.currentPoints,
    required this.currentColor,
    required this.currentStrokeWidth,
    required this.currentTool,
  });
  
  @override
  void paint(Canvas canvas, Size size) {
    // saveLayer를 사용하여 지우개가 제대로 작동하도록 함
    canvas.saveLayer(Rect.fromLTWH(0, 0, size.width, size.height), Paint());
    
    // 기존 스트로크 그리기
    for (final stroke in strokes) {
      if (stroke.isEraser) {
        _drawEraser(canvas, stroke);
      } else {
        _drawStroke(canvas, stroke.points, stroke.color, stroke.strokeWidth, stroke.tool);
      }
    }
    
    // 현재 그리고 있는 스트로크
    if (currentPoints.isNotEmpty) {
      if (currentTool == WhiteboardTool.eraser) {
        // 지우개로 그리는 중일 때 미리보기 (실제 지우개 효과)
        _drawEraserPreview(canvas, currentPoints, currentStrokeWidth);
      } else {
        _drawStroke(canvas, currentPoints, currentColor, currentStrokeWidth, currentTool);
      }
    }
    
    canvas.restore();
  }
  
  void _drawEraserPreview(Canvas canvas, List<Offset> points, double strokeWidth) {
    // 지우개 미리보기 - 실제 지움 효과
    final paint = Paint()
      ..blendMode = BlendMode.clear
      ..strokeWidth = strokeWidth * 3
      ..strokeCap = StrokeCap.round
      ..style = PaintingStyle.stroke;
    _drawPath(canvas, points, paint);
  }
  
  void _drawStroke(Canvas canvas, List<Offset> points, Color color, double strokeWidth, WhiteboardTool tool) {
    if (points.isEmpty) return;
    
    final paint = Paint()
      ..color = tool == WhiteboardTool.highlighter 
          ? color.withOpacity(0.4) 
          : color
      ..strokeWidth = tool == WhiteboardTool.highlighter 
          ? strokeWidth * 3 
          : strokeWidth
      ..strokeCap = StrokeCap.round
      ..strokeJoin = StrokeJoin.round
      ..style = PaintingStyle.stroke;
    
    _drawPath(canvas, points, paint);
  }
  
  void _drawPath(Canvas canvas, List<Offset> points, Paint paint) {
    if (points.length < 2) {
      // 점 하나만 찍은 경우
      if (points.isNotEmpty) {
        canvas.drawCircle(points.first, paint.strokeWidth / 2, paint..style = PaintingStyle.fill);
      }
      return;
    }
    
    final path = Path();
    path.moveTo(points.first.dx, points.first.dy);
    
    for (int i = 1; i < points.length - 1; i++) {
      final p0 = points[i];
      final p1 = points[i + 1];
      final midPoint = Offset((p0.dx + p1.dx) / 2, (p0.dy + p1.dy) / 2);
      path.quadraticBezierTo(p0.dx, p0.dy, midPoint.dx, midPoint.dy);
    }
    
    // 마지막 점
    if (points.length > 1) {
      path.lineTo(points.last.dx, points.last.dy);
    }
    
    canvas.drawPath(path, paint);
  }
  
  void _drawEraser(Canvas canvas, DrawingStroke stroke) {
    // 지우개는 BlendMode.clear를 사용하여 지움
    final paint = Paint()
      ..blendMode = BlendMode.clear
      ..strokeWidth = stroke.strokeWidth
      ..strokeCap = StrokeCap.round
      ..style = PaintingStyle.stroke;
    
    _drawPath(canvas, stroke.points, paint);
  }
  
  @override
  bool shouldRepaint(covariant WhiteboardPainter oldDelegate) {
    return strokes != oldDelegate.strokes ||
           currentPoints != oldDelegate.currentPoints ||
           currentColor != oldDelegate.currentColor ||
           currentStrokeWidth != oldDelegate.currentStrokeWidth;
  }
}

/// 피제어자용 화이트보드 오버레이 위젯 (수신 전용)
class WhiteboardReceiverOverlay extends StatelessWidget {
  final WhiteboardReceiverController controller;
  
  const WhiteboardReceiverOverlay({
    Key? key,
    required this.controller,
  }) : super(key: key);
  
  @override
  Widget build(BuildContext context) {
    return Obx(() {
      if (!controller.isEnabled.value) {
        return const SizedBox.shrink();
      }
      
      return Positioned.fill(
        child: IgnorePointer(
          // 피제어자는 그릴 수 없음, 입력 무시
          child: LayoutBuilder(
            builder: (context, constraints) {
              // 캔버스 크기 업데이트
              WidgetsBinding.instance.addPostFrameCallback((_) {
                controller.setCanvasSize(Size(constraints.maxWidth, constraints.maxHeight));
              });
              
              return Obx(() => CustomPaint(
                painter: WhiteboardReceiverPainter(
                  strokes: controller.strokes.toList(),
                ),
                size: Size.infinite,
              ));
            },
          ),
        ),
      );
    });
  }
}

/// 피제어자용 화이트보드 페인터 (수신 전용)
class WhiteboardReceiverPainter extends CustomPainter {
  final List<DrawingStroke> strokes;
  
  WhiteboardReceiverPainter({
    required this.strokes,
  });
  
  @override
  void paint(Canvas canvas, Size size) {
    for (final stroke in strokes) {
      if (stroke.isEraser) {
        _drawEraser(canvas, stroke);
      } else {
        _drawStroke(canvas, stroke);
      }
    }
  }
  
  void _drawStroke(Canvas canvas, DrawingStroke stroke) {
    if (stroke.points.isEmpty) return;
    
    final paint = Paint()
      ..color = stroke.tool == WhiteboardTool.highlighter 
          ? stroke.color.withOpacity(0.4) 
          : stroke.color
      ..strokeWidth = stroke.tool == WhiteboardTool.highlighter 
          ? stroke.strokeWidth * 3 
          : stroke.strokeWidth
      ..strokeCap = StrokeCap.round
      ..strokeJoin = StrokeJoin.round
      ..style = PaintingStyle.stroke;
    
    _drawPath(canvas, stroke.points, paint);
  }
  
  void _drawPath(Canvas canvas, List<Offset> points, Paint paint) {
    if (points.length < 2) {
      if (points.isNotEmpty) {
        canvas.drawCircle(points.first, paint.strokeWidth / 2, paint..style = PaintingStyle.fill);
      }
      return;
    }
    
    final path = Path();
    path.moveTo(points.first.dx, points.first.dy);
    
    for (int i = 1; i < points.length - 1; i++) {
      final p0 = points[i];
      final p1 = points[i + 1];
      final midPoint = Offset((p0.dx + p1.dx) / 2, (p0.dy + p1.dy) / 2);
      path.quadraticBezierTo(p0.dx, p0.dy, midPoint.dx, midPoint.dy);
    }
    
    if (points.length > 1) {
      path.lineTo(points.last.dx, points.last.dy);
    }
    
    canvas.drawPath(path, paint);
  }
  
  void _drawEraser(Canvas canvas, DrawingStroke stroke) {
    final paint = Paint()
      ..blendMode = BlendMode.clear
      ..strokeWidth = stroke.strokeWidth
      ..strokeCap = StrokeCap.round
      ..style = PaintingStyle.stroke;
    
    _drawPath(canvas, stroke.points, paint);
  }
  
  @override
  bool shouldRepaint(covariant WhiteboardReceiverPainter oldDelegate) {
    return strokes != oldDelegate.strokes;
  }
}
