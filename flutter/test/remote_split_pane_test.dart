import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:get/get.dart';
import 'package:flutter_hbb/common.dart' show SessionID, OverlayDialogManager;
import 'package:flutter_hbb/models/model.dart';
import 'package:flutter_hbb/models/input_model.dart';
import 'package:flutter_hbb/models/desktop_render_texture.dart';
import 'package:flutter_hbb/desktop/models/remote_layout_model.dart';
import 'package:flutter_hbb/desktop/widgets/remote_split_pane.dart';
import 'package:flutter_hbb/desktop/widgets/remote_workspace.dart';
import 'package:flutter_hbb/desktop/widgets/tabbar_widget.dart';

void main() {
  testWidgets('removed monitor can be reselected without the PC picker',
      (tester) async {
    final ffi = _PaneSession(null);
    int? selected;
    Future<void> show(Set<int> used) => tester.pumpWidget(MaterialApp(
        home: RemoteSplitPane(
            target: const RemotePaneTarget('A', 1),
            ffi: ffi,
            active: false,
            missing: true,
            revision: 0,
            usedDisplays: used,
            onActivate: () {},
            onExpand: () {},
            onClear: () {},
            onSelectMonitor: (display) => selected = display)));
    await show({});
    expect(find.byIcon(Icons.desktop_windows_outlined), findsNothing);
    expect(find.byTooltip('PC · 모니터 선택'), findsNothing);
    await tester.tap(find.text('모니터 1 다시 표시'));
    expect(selected, 0);
    // A monitor used by a sibling pane must not be silently moved or duplicated.
    await show({0});
    expect(find.text('모니터 1 다시 표시'), findsNothing);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('named pane selects a monitor and disables duplicates',
      (tester) async {
    final ffi = _PaneSession(null);
    ffi.ffiModel.pi.displays.add(Display()
      ..width = 1920
      ..height = 1080);
    ffi.ffiModel.waitForFirstImage.value = true;
    var display = 0;
    await tester.pumpWidget(MaterialApp(
        home: StatefulBuilder(
      builder: (context, setState) => RemoteSplitPane(
        target: RemotePaneTarget('A', display),
        peerLabel: '회계(아이메딕스) (A)',
        usedDisplays: display == 1 ? {0} : {},
        ffi: ffi,
        active: false,
        missing: false,
        revision: 0,
        onActivate: () {},
        onExpand: () {},
        onClear: () {},
        onSelectMonitor: (value) => setState(() => display = value),
      ),
    )));
    expect(find.text('회계(아이메딕스) (A) · 모니터 1'), findsOneWidget);
    await tester.tap(find.byTooltip('모니터 선택 (2개)'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('모니터 2 · 1920 × 1080'));
    await tester.pumpAndSettle();
    expect(display, 1);
    expect(find.text('회계(아이메딕스) (A) · 모니터 2'), findsOneWidget);
    await tester.tap(find.byTooltip('모니터 선택 (2개)'));
    await tester.pumpAndSettle();
    final duplicate = tester.widget<PopupMenuItem<int>>(find.ancestor(
        of: find.text('모니터 1 · 100 × 100 (다른 칸에 표시 중)'),
        matching: find.byType(PopupMenuItem<int>)));
    expect(duplicate.enabled, isFalse);
    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    await tester.pumpAndSettle();
    expect(display, 1);
    await tester.tap(find.byTooltip('모니터 선택 (2개)'));
    await tester.pumpAndSettle();
    expect(find.text('다른 PC · 모니터 선택…'), findsNothing);
    expect(find.byType(PopupMenuItem<int>), findsNWidgets(2));
    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox.shrink());
  });
  testWidgets(
      'software pane ignores a retained stale texture and uses fresh frames',
      (tester) async {
    final recorder = ui.PictureRecorder();
    Canvas(recorder).drawRect(
        const Rect.fromLTWH(0, 0, 100, 100), Paint()..color = Colors.blue);
    final image = await recorder.endRecording().toImage(100, 100);
    final ffi = _PaneSession(image);
    Future<void> render(int revision) => tester.pumpWidget(MaterialApp(
            home: RemoteSplitPane(
          target: const RemotePaneTarget('A', 0),
          ffi: ffi,
          active: false,
          missing: false,
          revision: revision,
          onActivate: () {},
          onExpand: () {},
          onClear: () {},
        )));
    await render(0);
    await tester.pump();
    expect(find.byType(RawImage), findsOneWidget);
    expect(find.byType(Texture), findsNothing);
    ffi.textures.workspaceDisplays = {0, 1};
    await render(1);
    await tester.pump();
    expect(find.byType(Texture), findsOneWidget);
    expect(find.byType(RawImage), findsNothing);
    await tester.pumpWidget(const SizedBox.shrink());
    image.dispose();
    expect(tester.takeException(), isNull);
  });
  testWidgets('workspace switches all layouts without recreating its shell',
      (tester) async {
    final layout = RemoteLayoutModel()..setMode(RemoteLayoutMode.quad);
    final tabs = DesktopTabController(tabType: DesktopTabType.remoteScreen);
    await tester.pumpWidget(
        MaterialApp(home: RemoteWorkspace(tabs: tabs, layout: layout)));
    await tester.pumpAndSettle();
    expect(find.byType(RemoteSplitPane), findsNWidgets(4));
    for (final mode in [
      RemoteLayoutMode.sideBySide,
      RemoteLayoutMode.stacked,
      RemoteLayoutMode.sixWide,
      RemoteLayoutMode.sixTall,
      RemoteLayoutMode.single,
      RemoteLayoutMode.quad
    ]) {
      layout.setMode(mode);
      await tester.pumpAndSettle();
      expect(
          find.byType(RemoteSplitPane),
          mode == RemoteLayoutMode.single
              ? findsNothing
              : findsNWidgets(mode.capacity));
      expect(tester.takeException(), isNull);
    }
    await tester.pumpWidget(const SizedBox.shrink());
    layout.dispose();
    tabs.state.value.pageController.dispose();
    tabs.state.value.scrollController.dispose();
  });
  testWidgets('empty panes remain usable in a small four-way layout',
      (tester) async {
    await tester.pumpWidget(MaterialApp(
        home: Center(
            child: SizedBox(
      width: 300,
      height: 220,
      child: LayoutBuilder(builder: (context, constraints) {
        final rectangles = RemoteLayoutModel.rectangles(
            RemoteLayoutMode.quad, constraints.biggest);
        return Stack(
            children: List.generate(
                4,
                (i) => Positioned.fromRect(
                    rect: rectangles[i],
                    child: RemoteSplitPane(
                      target: null,
                      ffi: null,
                      active: i == 0,
                      missing: false,
                      revision: 0,
                      onActivate: () {},
                      onExpand: () {},
                      onClear: () {},
                    ))));
      }),
    ))));
    await tester.pumpAndSettle();
    expect(find.byType(RemoteSplitPane), findsNWidgets(4));
    expect(tester.takeException(), isNull);
    expect(find.byTooltip('PC · 모니터 선택'), findsNothing);
    expect(find.text('PC · 모니터 선택'), findsNothing);
    expect(find.text('상단 PC 탭이나 화면 제목줄을 끌어 놓으세요.'), findsNWidgets(4));
    await tester.pumpWidget(const SizedBox.shrink());
    expect(tester.takeException(), isNull);
  });
}

class _PaneSession extends Fake implements FFI {
  _PaneSession(ui.Image? image) {
    frames.image = image;
    inputModel = InputModel(WeakReference<FFI>(this));
  }
  @override
  final sessionId = SessionID('00000000-0000-4000-8000-000000000002');
  @override
  final closed = false;
  @override
  final ffiModel = _PanePeer();
  final frames = _PaneFrames();
  @override
  ImageModel get imageModel => frames;
  final textures = _PaneTextures();
  @override
  TextureModel get textureModel => textures;
  @override
  final cursorModel = _PaneCursor();
  @override
  late final InputModel inputModel;
  @override
  final dialogManager = OverlayDialogManager();
}

class _PanePeer extends ChangeNotifier implements FfiModel {
  _PanePeer() {
    pi.isSet.value = true;
    pi.isSupportMultiUiSession = true;
    pi.displays.add(Display()
      ..width = 100
      ..height = 100);
  }
  @override
  final pi = PeerInfo();
  @override
  final waitForFirstImage = false.obs;
  @override
  final isPeerLinux = false;
  @override
  final keyboard = true;
  @override
  final viewOnly = false;
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _PaneFrames extends ChangeNotifier implements ImageModel {
  @override
  ui.Image? image;
  @override
  final useTextureRender = false;
  @override
  int? displayIndex = 0;
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _PaneTextures extends Fake implements TextureModel {
  final texture = 42.obs;
  @override
  Set<int>? workspaceDisplays = {0};
  @override
  RxInt getTextureId(int display) => texture;
  @override
  bool hasFrame(int display) => true;
}

class _PaneCursor extends ChangeNotifier implements CursorModel {
  @override
  Offset get offset => Offset.zero;
  @override
  ui.Image? get image => null;
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}
