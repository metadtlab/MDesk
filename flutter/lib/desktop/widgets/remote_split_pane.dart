import 'dart:ui' as ui;

import 'package:desktop_drop/desktop_drop.dart';
import 'package:desktop_multi_window/desktop_multi_window.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:get/get.dart';

import '../../common/widgets/remote_input.dart';
import '../../models/input_model.dart';
import '../../models/model.dart';
import '../../models/platform_model.dart';
import '../models/remote_layout_model.dart';
import '../models/remote_pane_geometry.dart';
import 'remote_pane_drag.dart';

class RemoteSplitPane extends StatefulWidget {
  const RemoteSplitPane(
      {super.key,
      required this.target,
      required this.ffi,
      required this.active,
      required this.missing,
      required this.revision,
      required this.onActivate,
      required this.onExpand,
      required this.onClear,
      this.peerLabel,
      this.usedDisplays = const {},
      this.onSelectMonitor,
      this.onDragStart,
      this.onDragEnd,
      this.onFileDrop});

  final RemotePaneTarget? target;
  final FFI? ffi;
  final bool active;
  final bool missing;
  final int revision;
  final VoidCallback onActivate;
  final VoidCallback onExpand;
  final VoidCallback onClear;
  final String? peerLabel;
  final Set<int> usedDisplays;
  final ValueChanged<int>? onSelectMonitor;
  final VoidCallback? onDragStart;
  final VoidCallback? onDragEnd;
  final Future<void> Function(DropDoneDetails)? onFileDrop;

  @override
  State<RemoteSplitPane> createState() => RemoteSplitPaneState();
}

class RemoteSplitPaneState extends State<RemoteSplitPane>
    with MultiWindowListener {
  final _focus = FocusNode(debugLabel: 'remote split pane');
  final _imageKey = GlobalKey();
  InputModel? _input;
  RemotePaneGeometry? _geometry;
  bool _entered = false;
  bool _dragOver = false;
  bool _pointerOver = false;
  final Set<int> _selectionPointers = {};
  double _zoom = 1;
  Offset _pan = Offset.zero;

  @override
  void initState() {
    super.initState();
    DesktopMultiWindow.addListener(this);
    _attachInput();
  }

  void _attachInput() {
    final ffi = widget.ffi;
    if (ffi == null) return;
    _input = InputModel(WeakReference(ffi))
      ..keyboardMode = ffi.inputModel.keyboardMode
      ..pointerPositionMapper = (position, clamp) {
        final box = _imageKey.currentContext?.findRenderObject() as RenderBox?;
        if (box == null || !box.attached || !box.hasSize) return null;
        return _geometry?.toRemote(box.globalToLocal(position), clamp: clamp);
      };
  }

  @override
  void didUpdateWidget(RemoteSplitPane oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (!identical(oldWidget.ffi, widget.ffi) ||
        oldWidget.target != widget.target) {
      suspendInput();
      _input = null;
      _selectionPointers.clear();
      _zoom = 1;
      _pan = Offset.zero;
      _attachInput();
    }
    if (!widget.active || widget.missing) suspendInput();
  }

  bool get _ready =>
      widget.ffi != null &&
      !widget.ffi!.closed &&
      widget.ffi!.ffiModel.pi.isSet.value &&
      !widget.ffi!.ffiModel.waitForFirstImage.value &&
      !widget.ffi!.dialogManager.hasOpenDialogs.value &&
      !widget.missing &&
      widget.target != null &&
      widget.target!.display >= 0 &&
      widget.target!.display < widget.ffi!.ffiModel.pi.displays.length;

  bool get _canSend =>
      widget.active &&
      _focus.hasFocus &&
      _entered &&
      _ready &&
      widget.ffi!.ffiModel.keyboard &&
      !widget.ffi!.ffiModel.viewOnly;

  void requestInputFocus() {
    if (!mounted || !widget.active || !_ready) return;
    _input?.keyboardMode = widget.ffi!.inputModel.keyboardMode;
    _focus.requestFocus();
  }

  void suspendInput() {
    if (_entered) {
      _input?.releasePaneInputs();
      _entered = false;
    }
    _focus.unfocus();
  }

  void _onFocus(bool focused) {
    if (focused && widget.active && _ready) {
      _input?.keyboardMode = widget.ffi!.inputModel.keyboardMode;
      _input?.enterOrLeave(true);
      _entered = true;
    } else if (_entered) {
      _input?.releasePaneInputs();
      _entered = false;
    }
  }

  void _select() {
    widget.onActivate();
    WidgetsBinding.instance.addPostFrameCallback((_) => requestInputFocus());
  }

  @override
  void dispose() {
    suspendInput();
    DesktopMultiWindow.removeListener(this);
    _input?.pointerPositionMapper = null;
    _focus.dispose();
    super.dispose();
  }

  @override
  void onWindowBlur() {
    suspendInput();
    super.onWindowBlur();
  }

  void _pointerDown(PointerDownEvent event) {
    if (!widget.active || !_focus.hasFocus) {
      _selectionPointers.add(event.pointer);
      _select();
      return;
    }
    if (!_canSend || event.kind != ui.PointerDeviceKind.mouse) return;
    _input!.isPhysicalMouse.value = true;
    _input!.onPointDownImage(event);
  }

  Widget _video() {
    final ffi = widget.ffi!;
    final displayIndex = widget.target!.display;
    final display = ffi.ffiModel.pi.displays[displayIndex];
    final factor = ffi.ffiModel.isPeerLinux ? display.scale : 1.0;
    final remoteRect = Rect.fromLTWH(
        display.x, display.y, display.width / factor, display.height / factor);
    return LayoutBuilder(builder: (context, constraints) {
      final geometry = RemotePaneGeometry(
          viewport: Offset.zero & constraints.biggest,
          display: remoteRect,
          zoom: _zoom,
          pan: _pan);
      _geometry = geometry;
      final input = _input!;
      return ClipRect(
          child: Listener(
        key: _imageKey,
        behavior: HitTestBehavior.opaque,
        onPointerDown: _pointerDown,
        onPointerUp: (event) {
          if (_selectionPointers.remove(event.pointer)) return;
          if (_canSend) input.onPointUpImage(event);
        },
        onPointerCancel: (event) {
          _selectionPointers.remove(event.pointer);
          if (_entered) input.releasePaneInputs(leave: false);
        },
        onPointerMove: (event) {
          if (_selectionPointers.contains(event.pointer)) return;
          if (_canSend) input.onPointMoveImage(event);
        },
        onPointerHover: (event) {
          if (_canSend) input.onPointHoverImage(event);
        },
        onPointerSignal: (event) {
          if (event is PointerScrollEvent &&
              HardwareKeyboard.instance.isControlPressed) {
            // Ctrl+wheel changes this pane's local zoom only.
            if (widget.active) {
              setState(() {
                _zoom = (_zoom * (event.scrollDelta.dy < 0 ? 1.1 : 1 / 1.1))
                    .clamp(1.0, 4.0);
                if (_zoom == 1) _pan = Offset.zero;
              });
            }
          } else if (_zoom > 1 &&
              event is PointerScrollEvent &&
              HardwareKeyboard.instance.isShiftPressed) {
            if (widget.active) setState(() => _pan -= event.scrollDelta);
          } else if (_canSend) {
            input.onPointerSignalImage(event);
          }
        },
        onPointerPanZoomStart: (event) {
          if (_canSend) input.onPointerPanZoomStart(event);
        },
        onPointerPanZoomUpdate: (event) {
          if (_canSend) input.onPointerPanZoomUpdate(event);
        },
        onPointerPanZoomEnd: (event) {
          if (_canSend) input.onPointerPanZoomEnd(event);
        },
        child: MouseRegion(
          onEnter: (_) {
            setState(() => _pointerOver = true);
            if (widget.active) bind.hostStopSystemKeyPropagate(stopped: false);
          },
          onExit: (_) {
            setState(() => _pointerOver = false);
            if (widget.active) bind.hostStopSystemKeyPropagate(stopped: true);
          },
          cursor: widget.active && !ffi.ffiModel.viewOnly
              ? SystemMouseCursors.basic
              : SystemMouseCursors.click,
          child: ColoredBox(
              color: const Color(0xff202124),
              child: Stack(
                fit: StackFit.expand,
                children: [
                  Positioned.fromRect(
                      rect: geometry.imageRect,
                      child: Obx(() {
                        final textureId =
                            ffi.textureModel.getTextureId(displayIndex).value;
                        // Textures are produced for all subscribed displays by the
                        // existing native renderer, including software pixel buffers.
                        final usesTexture = ffi.imageModel.useTextureRender ||
                            (ffi.textureModel.workspaceDisplays?.length ?? 0) >
                                1;
                        if (usesTexture &&
                            textureId >= 0 &&
                            ffi.textureModel.hasFrame(displayIndex)) {
                          return Texture(
                              textureId: textureId,
                              filterQuality: FilterQuality.low);
                        }
                        return AnimatedBuilder(
                            animation: ffi.imageModel,
                            builder: (_, __) => ffi.imageModel.displayIndex ==
                                        displayIndex &&
                                    ffi.imageModel.image != null
                                ? RawImage(
                                    image: ffi.imageModel.image,
                                    fit: BoxFit.fill)
                                : const Center(
                                    child: Text('화면 수신 중…',
                                        style:
                                            TextStyle(color: Colors.white70))));
                      })),
                  if (!display.cursorEmbedded)
                    IgnorePointer(
                        child: AnimatedBuilder(
                            animation: ffi.cursorModel,
                            builder: (_, __) {
                              final cursor = ffi.cursorModel;
                              final position = cursor.offset;
                              final image = cursor.image;
                              if (image == null ||
                                  !remoteRect.contains(position)) {
                                return const SizedBox.shrink();
                              }
                              final local = geometry.toLocal(position);
                              return CustomPaint(
                                  painter: _PaneCursorPainter(
                                      image,
                                      local -
                                          Offset(cursor.hotx, cursor.hoty) *
                                              geometry.scale,
                                      geometry.scale));
                            })),
                  if (!widget.active)
                    const Positioned(
                        left: 8,
                        bottom: 6,
                        child: IgnorePointer(
                            child: Text('클릭하여 선택',
                                style: TextStyle(
                                    color: Colors.white70, fontSize: 11)))),
                  if (_zoom > 1 && _pointerOver)
                    Positioned(
                        right: 6,
                        bottom: 4,
                        child: TextButton(
                            onPressed: () => setState(() {
                                  _zoom = 1;
                                  _pan = Offset.zero;
                                }),
                            child: Text('${(_zoom * 100).round()}% · 화면 맞춤'))),
                ],
              )),
        ),
      ));
    });
  }

  Widget _status(String message,
      {bool reconnect = false, bool monitorChanged = false}) {
    final pi = widget.ffi?.ffiModel.pi;
    final requested = pi?.isSupportMultiDisplay == true
        ? widget.target?.display ?? 0
        : pi?.currentDisplay ?? 0;
    final display = requested >= 0 && requested < (pi?.displays.length ?? 0)
        ? requested
        : 0;
    final canRestore = monitorChanged &&
        display < (pi?.displays.length ?? 0) &&
        !widget.usedDisplays.contains(display) &&
        widget.onSelectMonitor != null;
    return Center(
      child: SingleChildScrollView(
          child: Padding(
              padding: const EdgeInsets.all(8),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(message, textAlign: TextAlign.center),
                  const SizedBox(height: 8),
                  if (reconnect)
                    TextButton(
                        onPressed: widget.onExpand,
                        child: const Text('연결 화면 열기'))
                  else if (canRestore)
                    TextButton(
                        onPressed: () {
                          suspendInput();
                          widget.onSelectMonitor!(display);
                        },
                        child: Text('모니터 ${display + 1} 다시 표시'))
                  else
                    Text(
                        monitorChanged
                            ? '모니터 번호를 다시 선택하거나 단독 보기로 확인하세요.'
                            : '상단 PC 탭이나 화면 제목줄을 끌어 놓으세요.',
                        textAlign: TextAlign.center),
                ],
              ))),
    );
  }

  @override
  Widget build(BuildContext context) {
    final ffi = widget.ffi;
    final border = widget.active
        ? Theme.of(context).colorScheme.primary
        : Theme.of(context).dividerColor;
    final body = ffi == null || widget.target == null
        ? _status('빈 화면')
        : AnimatedBuilder(
            animation: ffi.ffiModel,
            builder: (_, __) => Obx(() {
                  if (!ffi.ffiModel.pi.isSet.value ||
                      ffi.ffiModel.waitForFirstImage.value ||
                      ffi.closed) {
                    return _status('연결 확인이 필요합니다', reconnect: true);
                  }
                  if (widget.missing ||
                      widget.target!.display >=
                          ffi.ffiModel.pi.displays.length) {
                    return _status('모니터 구성이 변경되었습니다', monitorChanged: true);
                  }
                  return _video();
                }));
    final input = _input;
    return Container(
      decoration: BoxDecoration(border: Border.all(color: border, width: 2)),
      child: Column(children: [
        Material(
          color: widget.active
              ? border.withValues(alpha: 0.12)
              : Theme.of(context).colorScheme.surface,
          child: SizedBox(
              height: 32,
              child: Row(children: [
                Expanded(
                    child: RemotePaneDragSource(
                        peerId: widget.target?.peerId ?? '',
                        display: widget.target?.display,
                        enabled: widget.target != null && !widget.missing,
                        onStart: widget.onDragStart ?? suspendInput,
                        onEnd: widget.onDragEnd ?? requestInputFocus,
                        child: InkWell(
                            onTap: _select,
                            mouseCursor: widget.target == null
                                ? SystemMouseCursors.click
                                : SystemMouseCursors.grab,
                            child: Padding(
                                padding:
                                    const EdgeInsets.symmetric(horizontal: 6),
                                child: Align(
                                    alignment: Alignment.centerLeft,
                                    child: Text(
                                        widget.target == null
                                            ? '빈 화면'
                                            : '${widget.peerLabel ?? widget.target!.peerId} · 모니터 ${widget.target!.display + 1}',
                                        maxLines: 1,
                                        overflow: TextOverflow.ellipsis)))))),
                _monitorSelector(),
                if (widget.target != null) ...[
                  _button('단독 보기 · 전체 도구', Icons.open_in_full, widget.onExpand),
                  _button('패널 비우기 (연결 유지)', Icons.close, widget.onClear),
                ],
              ])),
        ),
        Expanded(
            child: DropTarget(
          onDragEntered: (_) => setState(() => _dragOver = true),
          onDragExited: (_) => setState(() => _dragOver = false),
          onDragDone: (details) async {
            setState(() => _dragOver = false);
            if (_ready) await widget.onFileDrop?.call(details);
          },
          child: Stack(fit: StackFit.expand, children: [
            if (input != null)
              RawKeyFocusScope(
                focusNode: _focus,
                inputModel: input,
                onFocusChange: _onFocus,
                autofocus: false,
                canRequestFocus: widget.active && !widget.missing,
                child: body,
              )
            else
              body,
            if (_dragOver && _ready)
              IgnorePointer(
                  child: ColoredBox(
                      color: border.withValues(alpha: 0.25),
                      child: const Center(child: Text('이 PC의 다운로드 폴더로 복사')))),
          ]),
        )),
      ]),
    );
  }

  Widget _monitorSelector() {
    final pi = widget.ffi?.ffiModel.pi;
    final target = widget.target;
    if (target == null ||
        pi == null ||
        !pi.isSet.value ||
        !pi.isSupportMultiDisplay ||
        pi.displays.length < 2 ||
        widget.onSelectMonitor == null) {
      return const SizedBox.shrink();
    }
    return SizedBox(
        width: 42,
        height: 30,
        child: PopupMenuButton<int>(
          tooltip: '모니터 선택 (${pi.displays.length}개)',
          padding: EdgeInsets.zero,
          onOpened: widget.onDragStart ?? suspendInput,
          onCanceled: widget.onDragEnd ?? requestInputFocus,
          onSelected: (display) {
            if (display >= 0 &&
                display < pi.displays.length &&
                !widget.usedDisplays.contains(display)) {
              widget.onSelectMonitor!(display);
              (widget.onDragEnd ?? requestInputFocus)();
            }
          },
          itemBuilder: (_) => List.generate(pi.displays.length, (display) {
            final monitor = pi.displays[display];
            final used = widget.usedDisplays.contains(display);
            return PopupMenuItem<int>(
              value: display,
              enabled: !used,
              child: Row(children: [
                Icon(display == target.display ? Icons.check : Icons.monitor,
                    size: 18),
                const SizedBox(width: 8),
                Flexible(
                    child: Text(
                        '모니터 ${display + 1} · ${monitor.width.toInt()} × ${monitor.height.toInt()}${used ? ' (다른 칸에 표시 중)' : ''}')),
              ]),
            );
          }),
          child: Row(mainAxisAlignment: MainAxisAlignment.center, children: [
            Text('${target.display + 1}'),
            const Icon(Icons.arrow_drop_down, size: 16),
          ]),
        ));
  }

  Widget _button(String tooltip, IconData icon, VoidCallback action) =>
      SizedBox(
        width: 30,
        height: 30,
        child: IconButton(
            tooltip: tooltip,
            padding: EdgeInsets.zero,
            iconSize: 16,
            onPressed: () {
              suspendInput();
              action();
            },
            icon: Icon(icon)),
      );
}

class _PaneCursorPainter extends CustomPainter {
  _PaneCursorPainter(this.image, this.offset, this.scale);
  final ui.Image image;
  final Offset offset;
  final double scale;

  @override
  void paint(Canvas canvas, Size size) {
    canvas.drawImageRect(
        image,
        Rect.fromLTWH(0, 0, image.width.toDouble(), image.height.toDouble()),
        offset & Size(image.width * scale, image.height * scale),
        Paint());
  }

  @override
  bool shouldRepaint(_PaneCursorPainter old) =>
      image != old.image || offset != old.offset || scale != old.scale;
}
