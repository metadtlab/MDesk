import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_hbb/desktop/models/remote_layout_model.dart';
import 'package:flutter_hbb/desktop/widgets/remote_pane_drag.dart';
import 'package:flutter_hbb/desktop/widgets/remote_split_pane.dart';
import 'package:flutter_hbb/desktop/widgets/remote_split_resize_handles.dart';
import 'package:flutter_hbb/desktop/widgets/remote_workspace.dart';
import 'package:flutter_hbb/desktop/widgets/tabbar_widget.dart';

void main() {
  for (final mode in [RemoteLayoutMode.sixWide, RemoteLayoutMode.sixTall]) {
    testWidgets('${mode.name} second divider and junction resize independently',
        (tester) async {
      final layout = RemoteLayoutModel()..setMode(mode);
      final tabs = DesktopTabController(tabType: DesktopTabType.remoteScreen);
      await tester.pumpWidget(
          MaterialApp(home: RemoteWorkspace(tabs: tabs, layout: layout)));
      await tester.pumpAndSettle();
      final panes = find.byType(RemoteSplitPane);
      expect(panes, findsNWidgets(6));
      final wide = mode == RemoteLayoutMode.sixWide;
      final before = List.generate(6, (i) => tester.getRect(panes.at(i)));
      final handle = find.byKey(ValueKey(
          wide ? 'split-resize-columns-1-0' : 'split-resize-rows-0-1'));
      final rect = tester.getRect(handle);
      final drag = await tester.startGesture(
          wide
              ? Offset(rect.center.dx, rect.top + 40)
              : Offset(rect.left + 40, rect.center.dy),
          kind: ui.PointerDeviceKind.mouse);
      await drag.moveBy(wide ? const Offset(30, 0) : const Offset(0, 30));
      await tester.pump();
      await drag.up();
      await tester.pumpAndSettle();
      final second = tester.getRect(panes.at(wide ? 1 : 2));
      expect(tester.getRect(panes.first), before.first);
      expect(wide ? second.width : second.height,
          closeTo((wide ? before[1].width : before[2].height) + 30, 0.001));
      final junction = find.byKey(
          ValueKey(wide ? 'split-resize-both-1-0' : 'split-resize-both-0-1'));
      final junctionDrag = await tester.startGesture(tester.getCenter(junction),
          kind: ui.PointerDeviceKind.mouse);
      await junctionDrag.moveBy(const Offset(-20, -20));
      await tester.pump();
      await junctionDrag.up();
      await tester.pumpAndSettle();
      await tester.tap(junction);
      await tester.pump(const Duration(milliseconds: 80));
      await tester.tap(junction);
      await tester.pumpAndSettle();
      for (var i = 0; i < 6; i++) {
        expect(tester.getRect(panes.at(i)), before[i]);
      }
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox.shrink());
      layout.dispose();
      tabs.state.value.pageController.dispose();
      tabs.state.value.scrollController.dispose();
    });
  }
  for (final mode in [RemoteLayoutMode.sideBySide, RemoteLayoutMode.stacked]) {
    testWidgets('$mode divider resizes panes and double click resets',
        (tester) async {
      final layout = RemoteLayoutModel()..setMode(mode);
      final tabs = DesktopTabController(tabType: DesktopTabType.remoteScreen);
      await tester.pumpWidget(
          MaterialApp(home: RemoteWorkspace(tabs: tabs, layout: layout)));
      await tester.pumpAndSettle();
      final panes = find.byType(RemoteSplitPane);
      final first = tester.getRect(panes.first);
      final columns = mode == RemoteLayoutMode.sideBySide;
      final handle =
          find.byKey(ValueKey('split-resize-${columns ? 'columns' : 'rows'}'));
      final drag = await tester.startGesture(tester.getCenter(handle),
          kind: ui.PointerDeviceKind.mouse);
      await drag.moveBy(columns ? const Offset(90, 0) : const Offset(0, 65));
      await tester.pump();
      await drag.up();
      await tester.pump();
      final resized = tester.getRect(panes.first);
      expect(
          columns ? resized.width : resized.height,
          closeTo((columns ? first.width : first.height) + (columns ? 90 : 65),
              0.01));
      await tester.tap(handle);
      await tester.pump(const Duration(milliseconds: 80));
      await tester.tap(handle);
      await tester.pumpAndSettle();
      expect(tester.getRect(panes.first), first);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox.shrink());
      layout.dispose();
    });
  }

  testWidgets('quad center drags both axes and keeps connection owner mounted',
      (tester) async {
    final layout = RemoteLayoutModel()
      ..setMode(RemoteLayoutMode.quad,
          initialTarget: const RemotePaneTarget('A', 0));
    final tabs = DesktopTabController(tabType: DesktopTabType.remoteScreen);
    final ownerKey = GlobalKey<_OwnerState>();
    tabs.state.value.tabs
        .add(TabInfo(key: 'A', label: 'A', page: _Owner(key: ownerKey)));
    await tester.pumpWidget(
        MaterialApp(home: RemoteWorkspace(tabs: tabs, layout: layout)));
    await tester.pumpAndSettle();
    final owner = ownerKey.currentState;
    final before = tester.getRect(find.byType(RemoteSplitPane).first);
    final drag = await tester.startGesture(
        tester.getCenter(find.byKey(const ValueKey('split-resize-both'))),
        kind: ui.PointerDeviceKind.mouse);
    await drag.moveBy(const Offset(100, -60));
    await tester.pump();
    await drag.up();
    await tester.pumpAndSettle();
    final pane = tester.getRect(find.byType(RemoteSplitPane).first);
    expect(pane.width, before.width + 100);
    expect(pane.height, before.height - 60);
    expect(ownerKey.currentState, same(owner));
    expect(
        tester.getRect(find.byKey(ownerKey)),
        Rect.fromLTWH(
            pane.left + 2, pane.top + 34, pane.width - 4, pane.height - 36));
    expect(layout.activeTarget, const RemotePaneTarget('A', 0));
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox.shrink());
    layout.dispose();
  });

  testWidgets('divider captures pointer immediately and releases on cancel',
      (tester) async {
    final layout = RemoteLayoutModel()..setMode(RemoteLayoutMode.quad);
    var starts = 0;
    var ends = 0;
    var remoteDowns = 0;
    await tester.pumpWidget(MaterialApp(
        home: Stack(fit: StackFit.expand, children: [
      Listener(
          onPointerDown: (_) => remoteDowns++,
          behavior: HitTestBehavior.opaque),
      RemoteSplitResizeHandles(
          layout: layout,
          onResizeStart: () => starts++,
          onResizeEnd: () => ends++),
    ])));
    final gesture = await tester.startGesture(
        tester.getCenter(find.byKey(const ValueKey('split-resize-both'))),
        kind: ui.PointerDeviceKind.mouse);
    expect(starts, 1);
    expect(remoteDowns, 0);
    await gesture.moveBy(const Offset(1000, 1000));
    await tester.pump();
    final rects = layout.paneRects(const Size(800, 600));
    expect(rects.last.width, 160);
    expect(rects.last.height, closeTo(100, 0.001));
    await gesture.cancel();
    await tester.pumpAndSettle();
    expect(ends, 1);
    await tester.pumpWidget(const SizedBox.shrink());
    layout.dispose();
  });

  testWidgets(
      'dragging a tab moves its screen only when dropped on an empty pane',
      (tester) async {
    final layout = RemoteLayoutModel()
      ..setMode(RemoteLayoutMode.quad,
          initialTarget: const RemotePaneTarget('A', 1));
    final tabs = DesktopTabController(tabType: DesktopTabType.remoteScreen);
    tabs.state.value.tabs
        .add(TabInfo(key: 'A', label: 'A', page: const SizedBox.expand()));
    final workspaceKey = GlobalKey<RemoteWorkspaceState>();
    var clicks = 0;
    var parentDrags = 0;
    await tester.pumpWidget(MaterialApp(
        home: Material(
            child: Column(children: [
      SizedBox(
          height: 40,
          child: GestureDetector(
            onPanStart: (_) => parentDrags++,
            child: InkWell(
                onTap: () => clicks++,
                child: RemotePaneDragSource(
                  peerId: 'A',
                  affinity: Axis.vertical,
                  enabled: true,
                  onStart: () => workspaceKey.currentState!.suspendInput(),
                  onEnd: () => workspaceKey.currentState!.resumeInput(),
                  child: const SizedBox(
                      width: 220, child: Center(child: Text('PC A tab'))),
                )),
          )),
      Expanded(
          child:
              RemoteWorkspace(key: workspaceKey, tabs: tabs, layout: layout)),
    ]))));
    await tester.pumpAndSettle();
    final source = find.text('PC A tab');
    await tester.tap(source);
    expect(clicks, 1);
    Future<TestGesture> dragTo(int slot) async {
      final gesture = await tester.startGesture(tester.getCenter(source),
          kind: ui.PointerDeviceKind.mouse);
      await gesture.moveBy(const Offset(0, 30));
      await tester.pump();
      await gesture
          .moveTo(tester.getCenter(find.byType(RemoteSplitPane).at(slot)));
      await tester.pump();
      return gesture;
    }

    final drag = await dragTo(2);
    expect(find.text('여기에 화면 놓기'), findsOneWidget);
    await drag.up();
    await tester.pumpAndSettle();
    expect(layout.slots.take(4),
        [null, null, const RemotePaneTarget('A', 1), null]);
    expect(layout.activeSlot, 2);
    expect(clicks, 1);
    expect(parentDrags, 0);
    final occupiedDrop = await dragTo(2);
    expect(find.text('여기에 화면 놓기'), findsNothing);
    await occupiedDrop.up();
    await tester.pumpAndSettle();
    final cancelled = await dragTo(3);
    await cancelled.moveTo(const Offset(790, 10));
    await cancelled.up();
    await tester.pumpAndSettle();
    expect(layout.slots.take(4),
        [null, null, const RemotePaneTarget('A', 1), null]);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox.shrink());
    layout.dispose();
  });
  testWidgets('pane header moves its exact monitor in either direction',
      (tester) async {
    const monitor0 = RemotePaneTarget('A', 0);
    const monitor1 = RemotePaneTarget('A', 1);
    final layout = RemoteLayoutModel()..setMode(RemoteLayoutMode.quad);
    layout.arrange([monitor0, monitor1]);
    layout.activate(1);
    final tabs = DesktopTabController(tabType: DesktopTabType.remoteScreen);
    tabs.state.value.tabs
        .add(TabInfo(key: 'A', label: 'A', page: const SizedBox.expand()));
    await tester.pumpWidget(
        MaterialApp(home: RemoteWorkspace(tabs: tabs, layout: layout)));
    await tester.pumpAndSettle();
    final source = find.text('A · 모니터 1');
    await tester.tap(source);
    await tester.pump();
    expect(layout.activeSlot, 0);
    layout.activate(1);
    await tester.pump();
    Future<void> moveTo(int slot) async {
      final drag = await tester.startGesture(tester.getCenter(source),
          kind: ui.PointerDeviceKind.mouse);
      await drag
          .moveTo(tester.getCenter(find.byType(RemoteSplitPane).at(slot)));
      await tester.pump();
      expect(find.text('여기에 화면 놓기'), findsOneWidget);
      await drag.up();
      await tester.pumpAndSettle();
    }

    await moveTo(2);
    expect(layout.slots.take(4), [null, monitor1, monitor0, null]);
    await moveTo(3);
    expect(layout.slots.take(4), [null, monitor1, null, monitor0]);
    expect(layout.activeSlot, 3);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox.shrink());
    layout.dispose();
  });

  testWidgets('workspace passes the same peer label through header moves',
      (tester) async {
    final layout = RemoteLayoutModel()
      ..setMode(RemoteLayoutMode.quad,
          initialTarget: const RemotePaneTarget('A', 0));
    final tabs = DesktopTabController(tabType: DesktopTabType.remoteScreen);
    tabs.state.value.tabs
        .add(TabInfo(key: 'A', label: 'A', page: const SizedBox.expand()));
    var name = '회계(아이메딕스) (A)';
    final workspaceKey = GlobalKey<RemoteWorkspaceState>();
    await tester.pumpWidget(MaterialApp(
        home: RemoteWorkspace(
      key: workspaceKey,
      tabs: tabs,
      layout: layout,
      peerLabelGetter: (_) => name,
    )));
    await tester.pumpAndSettle();
    expect(find.text('$name · 모니터 1'), findsOneWidget);
    layout.moveToEmpty(2, const RemotePaneTarget('A', 0));
    await tester.pumpAndSettle();
    expect(find.text('$name · 모니터 1'), findsOneWidget);
    name = '새 이름 (A)';
    workspaceKey.currentState!.sessionsChanged();
    await tester.pumpAndSettle();
    expect(find.text('$name · 모니터 1'), findsOneWidget);
    await tester.pumpWidget(const SizedBox.shrink());
    layout.dispose();
  });
}

class _Owner extends StatefulWidget {
  const _Owner({super.key});
  @override
  State<_Owner> createState() => _OwnerState();
}

class _OwnerState extends State<_Owner> {
  @override
  Widget build(BuildContext context) => const SizedBox.expand();
}
