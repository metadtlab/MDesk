import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:get/get.dart';
import 'package:flutter_hbb/common.dart';
import 'package:flutter_hbb/desktop/models/remote_layout_model.dart';
import 'package:flutter_hbb/desktop/widgets/remote_transfer_progress.dart';
import 'package:flutter_hbb/desktop/widgets/remote_workspace.dart';
import 'package:flutter_hbb/desktop/widgets/tabbar_widget.dart';
import 'package:flutter_hbb/models/file_model.dart';
import 'package:flutter_hbb/models/input_model.dart';
import 'package:flutter_hbb/models/model.dart';

const panelKey = ValueKey('remote-transfer-progress-panel');

JobProgress job(int id, String name, {bool download = false}) => JobProgress()
  ..id = id
  ..type = JobType.transfer
  ..state = JobState.inProgress
  ..isRemoteDropDownload = !download
  ..isDirectDownload = download
  ..fileName = name
  ..totalSize = 1000
  ..finishedSize = 250
  ..speed = 128;

class _Jobs extends JobController {
  _Jobs()
      : super(() => SessionID('00000000-0000-4000-8000-000000000001'),
            () => null);
  final cancelled = <int>[];
  @override
  Future<void> cancelJob(int id) async {
    cancelled.add(id);
  }
}

void main() {
  testWidgets('updates live progress and hides completed or unrelated jobs',
      (tester) async {
    final jobs = _Jobs();
    await tester.pumpWidget(MaterialApp(
        home: Stack(children: [
      RemoteTransferProgress(sources: [RemoteTransferProgressSource(jobs)]),
    ])));
    expect(find.byKey(panelKey), findsNothing);
    jobs.jobTable.addAll([
      job(1, 'archive.zip'),
      job(2, 'ordinary-file-transfer.txt')..isRemoteDropDownload = false,
      job(3, 'already-done.txt')..state = JobState.done,
    ]);
    await tester.pump();
    expect(find.text('archive.zip'), findsOneWidget);
    expect(find.text('ordinary-file-transfer.txt'), findsNothing);
    expect(find.text('already-done.txt'), findsNothing);
    expect(find.text('25%'), findsOneWidget);
    jobs.tryUpdateJobProgress(
        {'id': '1', 'file_num': '0', 'speed': '256', 'finished_size': '750'});
    await tester.pump();
    expect(
        tester
            .widget<LinearProgressIndicator>(
                find.byType(LinearProgressIndicator))
            .value,
        .75);
    expect(find.text('75%'), findsOneWidget);
    jobs.jobTable.first.state = JobState.done;
    jobs.jobTable.refresh();
    await tester.pump();
    expect(find.byKey(panelKey), findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets('deduplicates monitors and cancels only the owning PC job',
      (tester) async {
    final a = _Jobs()..jobTable.add(job(7, 'to-A.zip'));
    final b = _Jobs()..jobTable.add(job(7, 'to-B.zip'));
    var starts = 0;
    var ends = 0;
    await tester.pumpWidget(MaterialApp(
        home: Stack(children: [
      RemoteTransferProgress(
        sources: [
          RemoteTransferProgressSource(a, label: '회계 PC'),
          RemoteTransferProgressSource(b, label: '병원 PC'),
          RemoteTransferProgressSource(a, label: '회계 PC'),
        ],
        onInteractionStart: () => starts++,
        onInteractionEnd: () => ends++,
      ),
    ])));
    expect(find.text('to-A.zip'), findsOneWidget);
    expect(find.text('회계 PC'), findsOneWidget);
    expect(find.text('병원 PC'), findsOneWidget);
    final row = find
        .ancestor(of: find.text('to-B.zip'), matching: find.byType(Row))
        .first;
    await tester
        .tap(find.descendant(of: row, matching: find.byIcon(Icons.close)));
    await tester.pump();
    expect(a.cancelled, isEmpty);
    expect(b.cancelled, [7]);
    expect(a.jobTable.length, 1);
    expect(b.jobTable, isEmpty);
    expect(starts, 1);
    expect(ends, 1);
  });

  testWidgets('error dismissal leaves other transfers running', (tester) async {
    final jobs = _Jobs()
      ..jobTable.addAll([
        job(1, 'waiting.zip')..state = JobState.paused,
        job(2, 'failed.zip')
          ..state = JobState.error
          ..err = 'Access denied',
      ]);
    await tester.pumpWidget(MaterialApp(
        home: Stack(children: [
      RemoteTransferProgress(sources: [RemoteTransferProgressSource(jobs)]),
    ])));
    expect(find.text('Access denied'), findsOneWidget);
    await tester.tap(find.byIcon(Icons.close).first);
    await tester.pump();
    expect(jobs.cancelled, isEmpty);
    expect(jobs.jobTable.single.fileName, 'waiting.zip');
    await tester.tap(find.byIcon(Icons.close));
    await tester.pump();
    expect(jobs.cancelled, [1]);
    expect(find.byKey(panelKey), findsNothing);
  });

  testWidgets(
      'panel stays inside small viewer and does not absorb clicks outside it',
      (tester) async {
    final jobs = _Jobs()
      ..jobTable.addAll(
          List.generate(4, (i) => job(i, 'file-$i.zip', download: true)));
    var clicks = 0;
    await tester.pumpWidget(MaterialApp(
        home: Center(
            child: SizedBox(
      width: 280,
      height: 200,
      child: Stack(children: [
        Positioned.fill(
            child: GestureDetector(
                behavior: HitTestBehavior.opaque,
                onTap: () => clicks++,
                child: const ColoredBox(color: Colors.blue))),
        RemoteTransferProgress(sources: [RemoteTransferProgressSource(jobs)]),
      ]),
    ))));
    await tester.pump();
    expect(tester.takeException(), isNull);
    final bounds = tester.getRect(find.byType(Stack).last);
    final panel = tester.getRect(find.byKey(panelKey));
    expect(panel.left, greaterThanOrEqualTo(bounds.left + 16));
    expect(panel.top, greaterThanOrEqualTo(bounds.top + 16));
    expect(panel.right, bounds.right - 16);
    expect(panel.bottom, bounds.bottom - 16);
    expect(find.text('+1 more'), findsOneWidget);
    await tester.tapAt(bounds.topLeft + const Offset(4, 4));
    await tester.pump();
    expect(clicks, 1);
    expect(jobs.cancelled, isEmpty);
  });

  for (final mode in RemoteLayoutMode.values
      .where((mode) => mode != RemoteLayoutMode.single)) {
    testWidgets(
        '${mode.name}: inactive peer progress remains visible across split/single switches',
        (tester) async {
      final layout = RemoteLayoutModel();
      final tabs = _Tabs();
      final a = _Session();
      final b = _Session();
      Get.put<FFI>(a, tag: 'A');
      Get.put<FFI>(b, tag: 'B');
      tabs.state.value.tabs.addAll([
        TabInfo(key: 'A', label: '회계 PC', page: const Text('owner A')),
        TabInfo(key: 'B', label: '병원 PC', page: const Text('owner B')),
      ]);
      final workspace = GlobalKey<RemoteWorkspaceState>();
      await tester.pumpWidget(MaterialApp(
          home: Scaffold(
              body: RemoteWorkspace(
                  key: workspace, tabs: tabs, layout: layout))));
      await tester.pumpAndSettle();
      final jobs = b.fileModel.jobController as _Jobs;
      jobs.jobTable.add(job(42, 'inactive-PC-transfer.zip'));
      await tester.pump();
      // Single view retains the existing selected-PC-only behavior.
      expect(find.text('inactive-PC-transfer.zip'), findsNothing);
      layout.setMode(mode, initialTarget: const RemotePaneTarget('A', 0));
      // PC B need not be selected or even assigned to a pane.
      await tester.pumpAndSettle();
      expect(
          find.text('inactive-PC-transfer.zip').hitTestable(), findsOneWidget);
      expect(find.text('병원 PC'), findsOneWidget);
      expect(find.byKey(panelKey), findsOneWidget);
      expect(jobs.jobTable.single.state, JobState.inProgress);
      final jobBeforeSwitch = jobs.jobTable.single;
      tabs.state.update((state) => state!.selected = 1);
      layout.setMode(RemoteLayoutMode.single);
      await tester.pumpAndSettle();
      expect(
          find.text('inactive-PC-transfer.zip').hitTestable(), findsOneWidget);
      expect(find.byKey(panelKey), findsOneWidget);
      expect(jobs.jobTable.single, same(jobBeforeSwitch));
      expect(jobs.cancelled, isEmpty);
      await tester.tap(find.byIcon(Icons.close));
      await tester.pump();
      expect(jobs.cancelled, [42]);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox());
      layout.dispose();
      tabs.state.value.pageController.dispose();
      tabs.state.value.scrollController.dispose();
      await Get.delete<FFI>(tag: 'A');
      await Get.delete<FFI>(tag: 'B');
    });
  }
}

class _Tabs extends DesktopTabController {
  _Tabs() : super(tabType: DesktopTabType.remoteScreen);
  @override
  bool jumpToByKey(String key, {bool callOnSelected = true}) {
    final index = state.value.tabs.indexWhere((tab) => tab.key == key);
    if (index < 0) return false;
    state.update((value) => value!.selected = index);
    if (callOnSelected) onSelected?.call(key);
    return true;
  }
}

class _Session extends Fake implements FFI {
  _Session() {
    inputModel = _Input(this);
  }
  @override
  final sessionId = SessionID('00000000-0000-4000-8000-000000000002');
  @override
  final closed = false;
  @override
  final ffiModel = _Peer();
  @override
  late final InputModel inputModel;
  @override
  final fileModel = _Files();
  @override
  final dialogManager = OverlayDialogManager();
}

class _Peer extends ChangeNotifier implements FfiModel {
  @override
  final pi = PeerInfo();
  @override
  final waitForFirstImage = true.obs;
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _Files extends Fake implements FileModel {
  @override
  final jobController = _Jobs();
}

class _Input extends InputModel {
  _Input(FFI ffi) : super(WeakReference(ffi));
  @override
  void releasePaneInputs({bool leave = true}) {}
}
