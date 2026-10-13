import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_hbb/desktop/widgets/host_password.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  late TextEditingController controller;
  late List<String> clipboardWrites;
  var refreshes = 0;
  var copies = 0;
  var settings = 0;

  setUp(() {
    controller = TextEditingController(text: 'test123');
    clipboardWrites = [];
    refreshes = copies = settings = 0;
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(SystemChannels.platform, (call) async {
      if (call.method == 'Clipboard.setData') {
        clipboardWrites.add((call.arguments as Map)['text'] as String);
      }
      return null;
    });
  });

  tearDown(() {
    controller.dispose();
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(SystemChannels.platform, null);
  });

  Future<void> pumpPassword(WidgetTester tester,
      {bool enabled = true,
      bool showOneTime = true,
      Brightness brightness = Brightness.light}) async {
    await tester.pumpWidget(MaterialApp(
      theme: ThemeData(brightness: brightness),
      home: Scaffold(
        body: Center(
          // Available width inside the existing 200px home sidebar.
          child: SizedBox(
            width: 155,
            child: HostPassword(
              controller: controller,
              enabled: enabled,
              showOneTime: showOneTime,
              onRefresh: () => refreshes++,
              onCopied: () => copies++,
              onSettings: () => settings++,
            ),
          ),
        ),
      ),
    ));
  }

  TextField field(WidgetTester tester) => tester.widget(find.byType(TextField));

  Future<void> doubleTapPassword(WidgetTester tester) async {
    await tester.tap(find.byType(TextField));
    await tester.pump(const Duration(milliseconds: 50));
    await tester.tap(find.byType(TextField));
    await tester.pumpAndSettle();
  }

  testWidgets('password is hidden by default and cannot be copied',
      (tester) async {
    final semantics = tester.ensureSemantics();
    try {
      await pumpPassword(tester);
      expect(field(tester).obscureText, isTrue);
      expect(field(tester).enableInteractiveSelection, isFalse);
      expect(tester.getSemantics(find.byType(TextField)).value,
          isNot(contains('test123')));
      await doubleTapPassword(tester);
      expect(clipboardWrites, isEmpty);
      expect(copies, 0);
      expect(tester.takeException(), isNull);
    } finally {
      semantics.dispose();
    }
  });

  testWidgets('eye toggles visibility and allows copying only while visible',
      (tester) async {
    await pumpPassword(tester);
    await tester.tap(find.byTooltip('비밀번호 표시'));
    await tester.pumpAndSettle();
    expect(field(tester).obscureText, isFalse);
    expect(field(tester).enableInteractiveSelection, isTrue);
    await doubleTapPassword(tester);
    expect(clipboardWrites, ['test123']);
    expect(copies, 1);
    await tester.tap(find.byTooltip('비밀번호 숨기기'));
    await tester.pumpAndSettle();
    expect(field(tester).obscureText, isTrue);
    expect(controller.text, 'test123');
  });

  testWidgets('disabled support hides password and disables reveal and refresh',
      (tester) async {
    await pumpPassword(tester);
    await tester.tap(find.byTooltip('비밀번호 표시'));
    await tester.pumpAndSettle();
    await pumpPassword(tester, enabled: false);
    expect(field(tester).obscureText, isTrue);
    final eye = tester.widget<IconButton>(
        find.widgetWithIcon(IconButton, Icons.visibility_off_outlined));
    expect(eye.onPressed, isNull);
    await tester.tap(find.byIcon(Icons.refresh), warnIfMissed: false);
    await doubleTapPassword(tester);
    expect(refreshes, 0);
    expect(clipboardWrites, isEmpty);
    await tester.tap(find.byIcon(Icons.edit));
    expect(settings, 1);
    await pumpPassword(tester);
    expect(field(tester).obscureText, isTrue);
  });

  testWidgets('password regeneration and external changes reset visibility',
      (tester) async {
    await pumpPassword(tester);
    await tester.tap(find.byTooltip('비밀번호 표시'));
    await tester.pumpAndSettle();
    await tester.tap(find.byIcon(Icons.refresh));
    await tester.pumpAndSettle();
    expect(refreshes, 1);
    expect(field(tester).obscureText, isTrue);
    await tester.tap(find.byTooltip('비밀번호 표시'));
    await tester.pumpAndSettle();
    controller.text = 'new123';
    await tester.pumpAndSettle();
    expect(field(tester).obscureText, isTrue);
  });

  testWidgets('password-disabled mode shows a placeholder without eye/refresh',
      (tester) async {
    controller.text = '-';
    await pumpPassword(tester, showOneTime: false);
    expect(find.byIcon(Icons.visibility_off_outlined), findsNothing);
    expect(find.byIcon(Icons.refresh), findsNothing);
    expect(field(tester).obscureText, isFalse);
    expect(field(tester).enableInteractiveSelection, isFalse);
    expect(find.text('-'), findsOneWidget);
  });

  testWidgets('narrow sidebar handles long passwords in light and dark themes',
      (tester) async {
    controller.text = 'test12345678';
    for (final brightness in [Brightness.light, Brightness.dark]) {
      await pumpPassword(tester, brightness: brightness);
      await tester.tap(find.byTooltip('비밀번호 표시'));
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
      await tester.tap(find.byTooltip('비밀번호 숨기기'));
      await tester.pumpAndSettle();
    }
  });
}
