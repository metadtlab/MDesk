import 'package:flutter/material.dart';
import 'package:flutter_hbb/common/startup_compatibility.dart';
import 'package:flutter_test/flutter_test.dart';

class _CompatibilityTestBinding extends AutomatedTestWidgetsFlutterBinding
    with StartupSemanticsCompatibility {
  @override
  final bool suppressNativeSemantics = true;
}

void main() {
  // Like production, select compatibility before binding initialization.
  final binding = _CompatibilityTestBinding();

  testWidgets('compatibility suppresses semantics but retains input',
      (tester) async {
    final controller = TextEditingController();
    addTearDown(controller.dispose);
    var taps = 0;
    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
        body: Column(children: [
          TextField(controller: controller),
          TextButton(onPressed: () => taps++, child: const Text('Connect')),
        ]),
      ),
    ));
    // A platform enable request must not re-enter the crashing native path.
    binding.platformDispatcher.semanticsEnabledTestValue = true;
    final handle = binding.ensureSemantics();
    try {
      await tester.pump();
      expect(binding.semanticsEnabled, isFalse);
      expect(tester.renderObject(find.byType(TextField)).owner!.semanticsOwner,
          isNull);
      await tester.enterText(find.byType(TextField), '204866135');
      await tester.tap(find.text('Connect'));
      await tester.pump();
      expect(controller.text, '204866135');
      expect(taps, 1);
    } finally {
      handle.dispose();
      binding.platformDispatcher.clearSemanticsEnabledTestValue();
    }
  });
}
