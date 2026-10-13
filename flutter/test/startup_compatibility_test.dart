import 'package:flutter/material.dart';
import 'package:flutter_hbb/common/startup_compatibility.dart';
import 'package:flutter_test/flutter_test.dart';

class _CompatibilityTestBinding extends AutomatedTestWidgetsFlutterBinding
    with StartupSemanticsCompatibility {
  @override
  final bool suppressNativeSemantics = false;
}

void main() {
  final binding = _CompatibilityTestBinding();

  test('Windows defaults to compatibility with an explicit opt-out', () {
    for (final value in [null, '', '0', 'true', '1']) {
      final environment = <String, String>{
        if (value != null) windowsStartupCompatibilityVariable: value,
      };
      expect(
        windowsStartupCompatibilityEnabled(
          isWindows: true,
          environment: environment,
        ),
        value != '0',
      );
      expect(
        windowsStartupCompatibilityEnabled(
          isWindows: false,
          environment: environment,
        ),
        isFalse,
      );
    }
  });

  testWidgets('opting out retains screen reader semantics', (tester) async {
    await tester.pumpWidget(const MaterialApp(
      home: Scaffold(body: Text('Accessible control')),
    ));
    expect(binding.semanticsEnabled, isTrue);
    expect(tester.getSemantics(find.text('Accessible control')).label,
        'Accessible control');
  });
}
