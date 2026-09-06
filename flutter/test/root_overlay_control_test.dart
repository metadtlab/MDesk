import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_hbb/common/widgets/root_overlay_control.dart';

void main() {
  testWidgets(
      'background control stays below a dialog and works after dismissal',
      (tester) async {
    var clicks = 0;
    late BuildContext pageContext;
    await tester.pumpWidget(MaterialApp(
      home: Builder(builder: (context) {
        pageContext = context;
        return Scaffold(
          body: Center(
            child: RootOverlayControl(
              size: const Size(100, 40),
              child: ElevatedButton(
                onPressed: () => clicks++,
                child: const Text('background login'),
              ),
            ),
          ),
        );
      }),
    ));
    await tester.pumpAndSettle();
    final button = find.text('background login');
    await tester.tap(button);
    expect(clicks, 1);

    showDialog<void>(
      context: pageContext,
      barrierDismissible: false,
      builder: (context) => const AlertDialog(
        content: SizedBox(width: 300, height: 200, child: Text('registration')),
      ),
    );
    await tester.pumpAndSettle();
    expect(button.hitTestable(), findsNothing);
    await tester.tapAt(const Offset(400, 300));
    expect(clicks, 1);
    Navigator.of(pageContext).pop();
    await tester.pumpAndSettle();
    await tester.tap(button);
    expect(clicks, 2);
    expect(tester.takeException(), isNull);
  });

  testWidgets('kept-alive page does not leak login onto settings or its dialog',
      (tester) async {
    final pages = PageController();
    addTearDown(pages.dispose);
    var clicks = 0;
    late BuildContext pageContext;
    await tester.pumpWidget(MaterialApp(
      home: Builder(builder: (context) {
        pageContext = context;
        return Scaffold(
          body: PageView(
            controller: pages,
            children: [
              _RetainedPage(
                  child: Center(
                      child: RootOverlayControl(
                size: const Size(100, 40),
                child: ElevatedButton(
                  onPressed: () => clicks++,
                  child: const Text('background login'),
                ),
              ))),
              const Center(child: Text('settings')),
            ],
          ),
        );
      }),
    ));
    await tester.pumpAndSettle();
    await tester.tap(find.text('background login'));
    expect(clicks, 1);
    pages.jumpToPage(1);
    await tester.pumpAndSettle();
    expect(find.text('settings').hitTestable(), findsOneWidget);
    expect(find.text('background login').hitTestable(), findsNothing);
    await tester.tapAt(const Offset(400, 300));
    expect(clicks, 1);

    showDialog<void>(
        context: pageContext,
        builder: (_) => const AlertDialog(
              content: Text('registration'),
            ));
    await tester.pumpAndSettle();
    expect(find.text('background login').hitTestable(), findsNothing);
    Navigator.of(pageContext).pop();
    await tester.pumpAndSettle();
    pages.jumpToPage(0);
    await tester.pumpAndSettle();
    await tester.tap(find.text('background login'));
    expect(clicks, 2);
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
  });
}

class _RetainedPage extends StatefulWidget {
  const _RetainedPage({required this.child});
  final Widget child;

  @override
  State<_RetainedPage> createState() => _RetainedPageState();
}

class _RetainedPageState extends State<_RetainedPage>
    with AutomaticKeepAliveClientMixin {
  @override
  bool get wantKeepAlive => true;

  @override
  Widget build(BuildContext context) {
    super.build(context);
    return widget.child;
  }
}
