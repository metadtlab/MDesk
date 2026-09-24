import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_hbb/desktop/models/remote_layout_model.dart';
import 'package:flutter_hbb/desktop/widgets/remote_layout_button.dart';
import 'package:flutter_hbb/desktop/widgets/remote_split_pane.dart';
import 'package:flutter_hbb/desktop/widgets/remote_workspace.dart';
import 'package:flutter_hbb/desktop/widgets/tabbar_widget.dart';

void main() {
  for (final mode in [RemoteLayoutMode.sixWide, RemoteLayoutMode.sixTall]) {
    testWidgets('${mode.name} header moves a monitor into the sixth pane',
        (tester) async {
      final viewer = _Viewer(['A', 'B']);
      viewer.layout.setMode(mode);
      viewer.layout.arrange(const [
        RemotePaneTarget('A', 0),
        RemotePaneTarget('A', 1),
        RemotePaneTarget('B', 0)
      ]);
      await viewer.mount(tester);
      final owners = viewer.ownerStates;
      final drag = await tester.startGesture(
          tester.getCenter(find.text('A · 모니터 2')),
          kind: ui.PointerDeviceKind.mouse);
      await drag.moveBy(const Offset(0, 30));
      await tester.pump();
      await drag.moveTo(tester.getCenter(find.byType(RemoteSplitPane).at(5)));
      await tester.pump();
      expect(find.text('여기에 화면 놓기'), findsOneWidget);
      await drag.up();
      await tester.pumpAndSettle();
      expect(viewer.layout.slots, const [
        RemotePaneTarget('A', 0),
        null,
        RemotePaneTarget('B', 0),
        null,
        null,
        RemotePaneTarget('A', 1)
      ]);
      expect(viewer.layout.activeSlot, 5);
      final before = viewer.layout.slots.toList();
      viewer.workspace.currentState!.changeMode(RemoteLayoutMode.single);
      await tester.pumpAndSettle();
      viewer.layout.restoreSplit();
      await tester.pumpAndSettle();
      expect(viewer.layout.mode, mode);
      expect(viewer.layout.slots, before);
      expect(viewer.ownerStates, owners);
      expect(tester.takeException(), isNull);
      await viewer.close(tester);
    });
  }
  for (final mode in [
    RemoteLayoutMode.sideBySide,
    RemoteLayoutMode.stacked,
    RemoteLayoutMode.quad,
    RemoteLayoutMode.sixWide,
    RemoteLayoutMode.sixTall
  ]) {
    testWidgets('selecting ${mode.name} fills PCs with current tab first',
        (tester) async {
      final viewer = _Viewer(['A', 'B', 'C', 'D', 'E', 'F', 'G'], selected: 2);
      await viewer.mount(tester);
      final owners = viewer.ownerStates;
      await tester.tap(find.byTooltip('화면 분할'));
      await tester.pumpAndSettle();
      await tester.tap(find.text(mode.label));
      await tester.pumpAndSettle();

      expect(
          viewer.layout.visibleTargets,
          ['C', 'A', 'B', 'D', 'E', 'F']
              .take(mode.capacity)
              .map((id) => RemotePaneTarget(id, 0)));
      expect(viewer.layout.activeSlot, 0);
      expect(viewer.tabs.state.value.selectedTabInfo.key, 'C');
      expect(find.byType(RemoteSplitPane), findsNWidgets(mode.capacity));
      expect(viewer.tabs.length, 7);
      expect(viewer.ownerStates, owners);
      expect(find.byTooltip('화면 분할'), findsOneWidget);
      expect(find.byTooltip('연결된 PC 자동 배치'), findsOneWidget);
      expect(find.byTooltip('현재 PC의 모니터 자동 배치'), findsOneWidget);
      expect(find.text(mode.label), findsNothing);
      expect(tester.getTopLeft(find.byType(RemoteSplitPane).first).dy,
          tester.getTopLeft(find.byKey(viewer.workspace)).dy);
      for (final target in viewer.layout.visibleTargets) {
        expect(find.text('${target.peerId} · 모니터 1'), findsOneWidget);
      }
      expect(tester.takeException(), isNull);
      await viewer.close(tester);
    });
  }

  testWidgets(
      'expanding and reselecting split fill holes without resetting layout',
      (tester) async {
    final viewer = _Viewer(['A', 'B', 'C']);
    viewer.layout.setMode(RemoteLayoutMode.sideBySide);
    viewer.layout.arrange(
        [const RemotePaneTarget('A', 1), const RemotePaneTarget('A', 0)]);
    viewer.layout.resize(const Size(1008, 808), dividerX: 604);
    await viewer.mount(tester);
    final owners = viewer.ownerStates;
    viewer.workspace.currentState!.changeMode(RemoteLayoutMode.quad);
    await tester.pumpAndSettle();
    expect(viewer.layout.slots.take(4), const [
      RemotePaneTarget('A', 1),
      RemotePaneTarget('A', 0),
      RemotePaneTarget('B', 0),
      RemotePaneTarget('C', 0)
    ]);
    expect(viewer.layout.columnFraction, 0.6);

    viewer.layout.assign(2, null);
    await tester.pumpAndSettle();
    // Re-selecting the same split fills a deliberately vacated pane too.
    viewer.workspace.currentState!.changeMode(RemoteLayoutMode.quad);
    await tester.pumpAndSettle();
    expect(viewer.layout.slots[2], const RemotePaneTarget('B', 0));
    expect(viewer.layout.activeSlot, 2);
    expect(viewer.tabs.state.value.selectedTabInfo.key, 'B');
    expect(viewer.layout.slots.take(2),
        const [RemotePaneTarget('A', 1), RemotePaneTarget('A', 0)]);
    expect(viewer.layout.columnFraction, 0.6);
    expect(viewer.ownerStates, owners);
    expect(tester.takeException(), isNull);
    await viewer.close(tester);
  });

  testWidgets('two PCs leave two blanks in quad; one PC is never duplicated',
      (tester) async {
    for (final peers in [
      ['A'],
      ['A', 'B']
    ]) {
      final viewer = _Viewer(peers);
      await viewer.mount(tester);
      viewer.workspace.currentState!.changeMode(RemoteLayoutMode.quad);
      await tester.pumpAndSettle();
      expect(viewer.layout.visibleTargets,
          peers.map((id) => RemotePaneTarget(id, 0)));
      expect(
          viewer.layout.slots.take(4).where((target) => target == null).length,
          4 - peers.length);
      expect(tester.takeException(), isNull);
      await viewer.close(tester);
    }
  });
}

class _Viewer {
  _Viewer(List<String> peers, {int selected = 0}) {
    for (final peer in peers) {
      final key = GlobalKey();
      owners.add(key);
      tabs.state.value.tabs.add(TabInfo(
          key: peer,
          label: peer,
          page: StatefulBuilder(
              key: key,
              builder: (context, setState) =>
                  Center(child: Text('owner $peer')))));
    }
    tabs.state.value.selected = selected;
    tabs.onSelected = (peer) => workspace.currentState!.onTabSelected(peer);
  }

  final layout = RemoteLayoutModel();
  final tabs = _TestTabs();
  final workspace = GlobalKey<RemoteWorkspaceState>();
  final owners = <GlobalKey>[];
  List<State?> get ownerStates =>
      owners.map((key) => key.currentState).toList();

  Future<void> mount(WidgetTester tester) async {
    await tester.pumpWidget(MaterialApp(
        home: Column(children: [
      ListenableBuilder(
          listenable: layout,
          builder: (_, __) => RemoteLayoutControls(
              mode: layout.mode,
              onSelected: (mode) => workspace.currentState!.changeMode(mode),
              onArrangePeers: () => workspace.currentState!.arrange(),
              onArrangeMonitors: () =>
                  workspace.currentState!.arrange(monitors: true),
              onRestore: layout.slots.any((target) => target != null)
                  ? () => workspace.currentState!.restoreSplit()
                  : null)),
      Expanded(
          child: RemoteWorkspace(key: workspace, tabs: tabs, layout: layout))
    ])));
    await tester.pumpAndSettle();
    expect(ownerStates, everyElement(isNotNull));
  }

  Future<void> close(WidgetTester tester) async {
    await tester.pumpWidget(const SizedBox.shrink());
    layout.dispose();
    tabs.state.value.pageController.dispose();
    tabs.state.value.scrollController.dispose();
  }
}

// Exercise workspace selection callbacks without a native desktop runtime.
class _TestTabs extends DesktopTabController {
  _TestTabs() : super(tabType: DesktopTabType.remoteScreen);

  @override
  bool jumpToByKey(String key, {bool callOnSelected = true}) {
    final index = state.value.tabs.indexWhere((tab) => tab.key == key);
    if (index < 0) return false;
    state.update((value) => value!.selected = index);
    if (callOnSelected) onSelected?.call(key);
    return true;
  }
}
