import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_hbb/common/widgets/overlay.dart';
import 'package:flutter_hbb/desktop/widgets/retained_remote_pages.dart';

void main() {
  testWidgets('peers becoming ready while split restore their single-view body',
      (tester) async {
    final ready = [
      ValueNotifier(true),
      ValueNotifier(false),
      ValueNotifier(false)
    ];
    final keys = List.generate(3, (_) => GlobalKey<_ConnectionPageState>());
    final pages = <String, Widget>{
      for (var i = 0; i < 3; i++)
        '$i': _ConnectionPage(key: keys[i], id: '$i', ready: ready[i])
    };
    Future<void> show(String? id) async {
      await tester.pumpWidget(
          MaterialApp(home: RetainedRemotePages(pages: pages, visibleKey: id)));
      await tester.pumpAndSettle();
    }

    await show('0');
    final owners = keys.map((key) => key.currentState).toList();
    // Split panes render independently while their original pages stay hidden.
    await show(null);
    ready[1].value = true;
    ready[2].value = true;
    await tester.pumpAndSettle();
    for (var cycle = 0; cycle < 2; cycle++) {
      for (var i = 0; i < 3; i++) {
        await show('$i');
        expect(find.text('video $i').hitTestable(), findsOneWidget);
        expect(find.text('toolbar $i').hitTestable(), findsOneWidget);
        expect(keys[i].currentState, same(owners[i]));
      }
      await show(null);
    }
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox.shrink());
    for (final value in ready) {
      value.dispose();
    }
  });

  testWidgets(
      'updating an overlay body preserves its dialog and blocking state',
      (tester) async {
    final state = BlockableOverlayState();
    final controller = TextEditingController();
    var clicks = 0;
    Future<void> body(String label) async {
      await tester.pumpWidget(MaterialApp(
          home: BlockableOverlay(
              state: state,
              underlying: Material(
                  child: Align(
                      alignment: Alignment.bottomCenter,
                      child: TextButton(
                          onPressed: () => clicks++, child: Text(label)))))));
      await tester.pumpAndSettle();
    }

    await body('old frame');
    final overlay = state.key!.currentState!;
    final dialog = OverlayEntry(
        builder: (_) => Align(
            alignment: Alignment.topCenter,
            child: Material(
                child: SizedBox(
                    width: 200,
                    height: 80,
                    child: TextField(controller: controller)))));
    overlay.insert(dialog);
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextField), 'retained input');
    state.setMiddleBlocked(true);
    await body('new frame');
    expect(state.key!.currentState, same(overlay));
    expect(find.text('new frame'), findsOneWidget);
    expect(find.text('old frame'), findsNothing);
    expect(controller.text, 'retained input');
    expect(state.middleBlocked.value, isTrue);
    state.setMiddleBlocked(false);
    await tester.pumpAndSettle();
    await tester.tap(find.text('new frame'));
    expect(clicks, 1);
    dialog.remove();
    dialog.dispose();
    await tester.pumpWidget(const SizedBox.shrink());
    controller.dispose();
    expect(tester.takeException(), isNull);
  });
}

class _ConnectionPage extends StatefulWidget {
  const _ConnectionPage({super.key, required this.id, required this.ready});
  final String id;
  final ValueNotifier<bool> ready;
  @override
  State<_ConnectionPage> createState() => _ConnectionPageState();
}

class _ConnectionPageState extends State<_ConnectionPage> {
  final overlayState = BlockableOverlayState();
  @override
  Widget build(BuildContext context) => ValueListenableBuilder<bool>(
      valueListenable: widget.ready,
      builder: (_, ready, __) => ready
          ? BlockableOverlay(
              state: overlayState,
              underlying: Column(children: [
                Text('toolbar ${widget.id}'),
                Expanded(child: Center(child: Text('video ${widget.id}')))
              ]))
          : Stack(children: [
              const Center(child: Text('connecting')),
              // Same key moves from the login layer to the full body when ready.
              BlockableOverlay(
                  state: overlayState, underlying: const SizedBox.expand())
            ]));
}
