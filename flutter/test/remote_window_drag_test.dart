import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_hbb/desktop/models/remote_layout_model.dart';
import 'package:flutter_hbb/desktop/models/remote_window_drag.dart';
import 'package:flutter_hbb/desktop/widgets/remote_pane_drag.dart';
import 'package:flutter_hbb/desktop/widgets/remote_split_pane.dart';
import 'package:flutter_hbb/desktop/widgets/remote_workspace.dart';
import 'package:flutter_hbb/desktop/widgets/tabbar_widget.dart';

const offer = RemoteWindowDragOffer(
    token: 'drag-1',
    peerId: 'A',
    display: 1,
    sessionId: 'session-A',
    paneOnly: true);

class _Platform extends RemoteWindowDragPlatform {
  final calls = <(int, String, dynamic)>[];
  Map<int, int?> hits = {2: 5};
  final drop = Completer<bool>();
  final dropped = Completer<void>();
  bool fail = false;

  @override
  Future<List<int>> windows() async => [1, 2, 3];
  @override
  Future<Offset?> cursor() async => const Offset(-900, 600);
  @override
  Future<dynamic> call(int window, String method, dynamic args) async {
    calls.add((window, method, args));
    if (method == paneDragSupported) return true;
    if (method == paneDragProbe) return hits[window];
    if (method == paneDragDrop) {
      dropped.complete();
      if (fail) throw StateError('window closed');
      return drop.future;
    }
    return null;
  }
}

class _DelayedPlatform extends _Platform {
  final discovered = Completer<List<int>>();
  final captured = Completer<void>();
  Offset position = const Offset(-700, 250);
  @override
  Future<List<int>> windows() => discovered.future;
  @override
  Future<Offset?> cursor() async {
    if (!captured.isCompleted) captured.complete();
    return position;
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test(
      'source monitor is removed only after destination acknowledges readiness',
      () async {
    final platform = _Platform();
    final source = RemoteLayoutModel()..setMode(RemoteLayoutMode.quad);
    source.arrange(const [RemotePaneTarget('A', 0), RemotePaneTarget('A', 1)]);
    final controller = RemoteWindowDragController(
        windowId: 1,
        platform: platform,
        createOffer: (_, __) => offer,
        isValid: (_) => true,
        onMoved: (_) => source.removeTarget(const RemotePaneTarget('A', 1)),
        onFailure: () => fail('unexpected failure'));
    controller.start('A', 1);
    final completion = controller.finish(acceptedLocally: false);
    await platform.dropped.future;
    expect(source.visibleTargets.length, 2);
    expect(controller.validates(offer.toMap()), isTrue);
    platform.drop.complete(true);
    await completion;
    expect(source.slots[0], const RemotePaneTarget('A', 0));
    expect(source.slots[1], isNull);
    expect(platform.calls.any((call) => call.$1 == 1), isFalse);
    final request = platform.calls.singleWhere((c) => c.$2 == paneDragDrop).$3;
    expect(request['slot'], 5);
    expect(request['display'], 1);
    expect(request.containsKey('password'), isFalse);
    expect(platform.calls.where((c) => c.$2 == paneDragClear).length, 2);
    expect(controller.validates(offer.toMap()), isFalse);
    controller.dispose();
    source.dispose();
  });

  for (final scenario in [
    'reject',
    'closed',
    'cancel',
    'local',
    'stale',
    'covered',
    'ambiguous'
  ]) {
    test('$scenario keeps source intact and clears hover', () async {
      final platform = _Platform();
      var moves = 0;
      var failures = 0;
      if (scenario == 'covered') platform.hits = {};
      if (scenario == 'ambiguous') platform.hits[3] = 0;
      if (scenario == 'closed') platform.fail = true;
      platform.drop.complete(false);
      final controller = RemoteWindowDragController(
          windowId: 1,
          platform: platform,
          createOffer: (_, __) => offer,
          isValid: (_) => scenario != 'stale',
          onMoved: (_) => moves++,
          onFailure: () => failures++);
      controller.start('A', 1);
      if (scenario == 'cancel') controller.cancel();
      await controller.finish(acceptedLocally: scenario == 'local');
      expect(moves, 0);
      expect(failures, ['reject', 'closed'].contains(scenario) ? 1 : 0);
      expect(platform.calls.where((c) => c.$2 == paneDragClear).length, 2);
      controller.dispose();
    });
  }

  test('stale acknowledgement cannot remove a reconnected source', () async {
    final platform = _Platform();
    var valid = true;
    var moved = false;
    final controller = RemoteWindowDragController(
        windowId: 1,
        platform: platform,
        createOffer: (_, __) => offer,
        isValid: (_) => valid,
        onMoved: (_) => moved = true,
        onFailure: () {});
    controller.start('A', 1);
    final completion = controller.finish(acceptedLocally: false);
    await platform.dropped.future;
    valid = false;
    platform.drop.complete(true);
    await completion;
    expect(moved, isFalse);
    controller.dispose();
  });

  test(
      'release position survives delayed window discovery and later mouse movement',
      () async {
    final platform = _DelayedPlatform();
    final controller = RemoteWindowDragController(
        windowId: 1,
        platform: platform,
        createOffer: (_, __) => offer,
        isValid: (_) => true,
        onMoved: (_) {},
        onFailure: () => fail('unexpected failure'));
    controller.start('A', 1);
    final finished = controller.finish(acceptedLocally: false);
    await platform.captured.future;
    platform.position = const Offset(1500, 600);
    platform.discovered.complete([1, 2]);
    await platform.dropped.future;
    final probe = platform.calls.singleWhere((c) => c.$2 == paneDragProbe).$3;
    expect(probe['x'], -700);
    expect(probe['y'], 250);
    platform.drop.complete(true);
    await finished;
    controller.dispose();
  });

  for (final scenario in [
    'success',
    'invalid source',
    'occupied',
    'timeout',
    'closed',
    'source changed'
  ]) {
    test('destination transaction: $scenario', () async {
      var reserved = false;
      var rollbacks = 0;
      var validations = 0;
      final accepted = await receiveRemoteWindowPane(validateSource: () async {
        validations++;
        return scenario != 'invalid source' &&
            !(scenario == 'source changed' && validations > 1);
      }, reserve: () {
        if (scenario == 'occupied') return false;
        reserved = true;
        return true;
      }, waitUntilReady: () async {
        if (scenario == 'closed') throw StateError('closed');
        return scenario != 'timeout';
      }, rollback: () {
        rollbacks++;
        reserved = false;
      });
      expect(accepted, scenario == 'success');
      expect(reserved, scenario == 'success');
      expect(rollbacks,
          ['timeout', 'closed', 'source changed'].contains(scenario) ? 1 : 0);
    });
  }

  testWidgets('drag cleanup still runs when its source widget disappears',
      (tester) async {
    final platform = _Platform()..hits = {};
    var ends = 0;
    final controller = RemoteWindowDragController(
        windowId: 1,
        platform: platform,
        createOffer: (_, __) => offer,
        isValid: (_) => true,
        onMoved: (_) => fail('must not move'),
        onFailure: () => fail('unexpected failure'));
    Widget tree(bool visible) => MaterialApp(
        home: RemoteWindowDragScope(
            controller: controller,
            child: Scaffold(
                body: visible
                    ? RemotePaneDragSource(
                        peerId: 'A',
                        display: 1,
                        enabled: true,
                        onStart: () {},
                        onEnd: () => ends++,
                        child: const SizedBox(
                            width: 200, height: 40, child: Text('drag header')))
                    : const SizedBox())));
    await tester.pumpWidget(tree(true));
    final drag =
        await tester.startGesture(tester.getCenter(find.text('drag header')));
    await drag.moveBy(const Offset(30, 40));
    await tester.pump();
    expect(controller.validates(offer.toMap()), isTrue);
    await tester.pumpWidget(tree(false));
    await drag.up();
    await tester.pumpAndSettle();
    expect(ends, 1);
    expect(controller.validates(offer.toMap()), isFalse);
    controller.dispose();
  });

  test(
      'native hit coordinates use target DPI and preserve negative desktop coordinates',
      () async {
    final messenger =
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    final calls = <MethodCall>[];
    messenger.setMockMethodCallHandler(RemoteWindowDragPlatform.channel,
        (call) async {
      calls.add(call);
      return call.method == 'cursor'
          ? {'x': -1800, 'y': 700}
          : {'x': 600, 'y': 450};
    });
    final platform = RemoteWindowDragPlatform();
    expect(await platform.cursor(), const Offset(-1800, 700));
    expect(await platform.hitTest(const Offset(-1800, 700), 1.5),
        const Offset(400, 300));
    expect(calls.last.arguments, {'x': -1800, 'y': 700});
    messenger.setMockMethodCallHandler(
        RemoteWindowDragPlatform.channel, (_) async => null);
    expect(await platform.hitTest(Offset.zero, 2), isNull);
    messenger.setMockMethodCallHandler(RemoteWindowDragPlatform.channel, null);
  });

  testWidgets(
      'empty-pane hit testing respects resized six-grid gaps and existing monitors',
      (tester) async {
    final layout = RemoteLayoutModel()..setMode(RemoteLayoutMode.sixTall);
    layout.arrange(const [RemotePaneTarget('A', 0), RemotePaneTarget('A', 1)]);
    layout.resize(const Size(800, 550),
        dividerX: 510, dividerY: 340, rowDivider: 1);
    final tabs = _Tabs();
    tabs.state.value.tabs
        .add(TabInfo(key: 'A', label: 'A', page: const SizedBox()));
    final key = GlobalKey<RemoteWorkspaceState>();
    await tester.pumpWidget(MaterialApp(
        home: Scaffold(
            body: Padding(
                padding: const EdgeInsets.only(top: 50),
                child:
                    RemoteWorkspace(key: key, tabs: tabs, layout: layout)))));
    await tester.pumpAndSettle();
    final panes = find.byType(RemoteSplitPane);
    final state = key.currentState!;
    expect(state.emptyPaneAt(tester.getCenter(panes.at(0))), isNull);
    expect(state.emptyPaneAt(tester.getCenter(panes.at(5))), 5);
    final fourth = tester.getRect(panes.at(3));
    expect(
        state.emptyPaneAt(Offset(fourth.left - 4, fourth.center.dy)), isNull);
    expect(state.emptyPaneAt(const Offset(0, 10)), isNull);
    expect(state.canReceiveWindowTarget(5, const RemotePaneTarget('A', 1)),
        isFalse);
    expect(state.canReceiveWindowTarget(5, const RemotePaneTarget('A', 2)),
        isTrue);
    state.showWindowDropSlot(5);
    await tester.pump();
    expect(find.text('여기에 화면 놓기'), findsOneWidget);
    state.completeWindowTransfer(const RemotePaneTarget('A', 1));
    await tester.pumpAndSettle();
    expect(tabs.closed, isEmpty);
    expect(layout.slots[0], const RemotePaneTarget('A', 0));
    state.completeWindowTransfer(const RemotePaneTarget('A', 0));
    await tester.pumpAndSettle();
    expect(tabs.closed, ['A']);
    await tester.pumpWidget(const SizedBox());
    layout.dispose();
    tabs.state.value.pageController.dispose();
    tabs.state.value.scrollController.dispose();
  });
}

class _Tabs extends DesktopTabController {
  _Tabs() : super(tabType: DesktopTabType.remoteScreen);
  final closed = <String>[];
  @override
  void closeBy(String? key) {
    if (key != null) closed.add(key);
  }
}
