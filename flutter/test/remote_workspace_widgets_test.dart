import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_hbb/desktop/models/remote_layout_model.dart';
import 'package:flutter_hbb/desktop/widgets/remote_layout_button.dart';
import 'package:flutter_hbb/desktop/widgets/retained_remote_pages.dart';

void main() {
  testWidgets('connection dialog relocates into its pane without remounting',
      (tester) async {
    final created = <String, int>{};
    final disposed = <String, int>{};
    final page = _Owner(id: 'A', created: created, disposed: disposed);
    await tester.pumpWidget(MaterialApp(
        home: RetainedRemotePages(pages: {'A': page}, visibleKey: 'A')));
    await tester.pumpWidget(MaterialApp(
        home: RetainedRemotePages(
            pages: {'A': page},
            visibleRects: const {'A': Rect.fromLTWH(400, 66, 300, 240)})));
    await tester.pump();
    expect(tester.getTopLeft(find.text('A')), const Offset(400, 66));
    expect(created, {'A': 1});
    expect(disposed, isEmpty);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox.shrink());
  });
  testWidgets('layout button exposes every mode and marks current choice',
      (tester) async {
    var mode = RemoteLayoutMode.single;
    var opened = 0;
    var closed = 0;
    await tester.pumpWidget(MaterialApp(
        home: StatefulBuilder(
            builder: (context, setState) => Scaffold(
                body: Align(
                    alignment: Alignment.topRight,
                    child: RemoteLayoutButton(
                        mode: mode,
                        onOpened: () => opened++,
                        onClosed: () => closed++,
                        onSelected: (value) =>
                            setState(() => mode = value)))))));
    await tester.tap(find.byTooltip('화면 분할'));
    await tester.pumpAndSettle();
    for (final value in RemoteLayoutMode.values) {
      expect(find.text(value.label), findsOneWidget);
    }
    expect(find.byIcon(Icons.check), findsOneWidget);
    await tester.tap(find.text('4분할'));
    await tester.pumpAndSettle();
    expect(mode, RemoteLayoutMode.quad);
    expect(opened, 1);
    expect(closed, 1);
    await tester.tap(find.byTooltip('화면 분할'));
    await tester.pumpAndSettle();
    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    await tester.pumpAndSettle();
    expect(mode, RemoteLayoutMode.quad);
    expect(closed, 2);
  });

  testWidgets(
      'connection owners survive split/expand and only removed connections dispose',
      (tester) async {
    final created = <String, int>{};
    final disposed = <String, int>{};
    final a = _Owner(id: 'A', created: created, disposed: disposed);
    final b = _Owner(id: 'B', created: created, disposed: disposed);
    Future<void> show(String? visible, Map<String, Widget> pages) async {
      await tester.pumpWidget(MaterialApp(
          home: SizedBox(
              width: 800,
              height: 600,
              child: RetainedRemotePages(pages: pages, visibleKey: visible))));
      await tester.pump();
    }

    await show('A', {'A': a, 'B': b});
    for (var i = 0; i < 10; i++) {
      await show(null, {'A': a, 'B': b});
      await show('B', {'A': a, 'B': b});
      await show('A', {'A': a, 'B': b});
    }
    expect(created, {'A': 1, 'B': 1});
    expect(disposed, isEmpty);
    await show('B', {'B': b});
    expect(disposed, {'A': 1});
    expect(created['B'], 1);
    await tester.pumpWidget(const SizedBox.shrink());
    expect(disposed, {'A': 1, 'B': 1});
  });

  testWidgets('hidden connection owners cannot steal focus or receive clicks',
      (tester) async {
    var clicksA = 0;
    var clicksB = 0;
    final focusA = FocusNode();
    final focusB = FocusNode();
    addTearDown(focusA.dispose);
    addTearDown(focusB.dispose);
    await tester.pumpWidget(MaterialApp(
        home: RetainedRemotePages(visibleKey: 'B', pages: {
      'A': Focus(
          focusNode: focusA,
          autofocus: true,
          child: ElevatedButton(
              onPressed: () => clicksA++, child: const Text('A'))),
      'B': Focus(
          focusNode: focusB,
          autofocus: true,
          child: ElevatedButton(
              onPressed: () => clicksB++, child: const Text('B'))),
    })));
    await tester.pumpAndSettle();
    focusA.requestFocus();
    await tester.pump();
    expect(focusA.hasFocus, isFalse);
    await tester.tap(find.text('B'));
    expect(clicksA, 0);
    expect(clicksB, 1);
    expect(tester.takeException(), isNull);
  });
}

class _Owner extends StatefulWidget {
  const _Owner(
      {required this.id, required this.created, required this.disposed});
  final String id;
  final Map<String, int> created;
  final Map<String, int> disposed;
  @override
  State<_Owner> createState() => _OwnerState();
}

class _OwnerState extends State<_Owner> {
  @override
  void initState() {
    super.initState();
    widget.created.update(widget.id, (v) => v + 1, ifAbsent: () => 1);
  }

  @override
  void dispose() {
    widget.disposed.update(widget.id, (v) => v + 1, ifAbsent: () => 1);
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => Text(widget.id);
}
