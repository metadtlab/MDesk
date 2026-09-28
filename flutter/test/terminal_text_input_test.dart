import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:xterm/xterm.dart';

void main() {
  testWidgets('terminal registers its view and sends text plus Enter once',
      (tester) async {
    final sent = <String>[];
    final terminal = Terminal()..onOutput = sent.add;
    await tester.pumpWidget(MaterialApp(
      home: Scaffold(body: TerminalView(terminal, autofocus: true)),
    ));
    await tester.pump();

    final attach = tester.testTextInput.log.lastWhere(
      (call) => call.method == 'TextInput.setClient',
    );
    final config = (attach.arguments as List)[1] as Map;
    expect(config['viewId'], tester.view.viewId);
    expect(tester.testTextInput.hasAnyClients, isTrue);

    tester.testTextInput.enterText('dir');
    await tester.pump();
    await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    expect(sent, ['dir', '\r']);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('terminal preserves Hangul composition until commit',
      (tester) async {
    final sent = <String>[];
    final terminal = Terminal()..onOutput = sent.add;
    await tester.pumpWidget(MaterialApp(
      home: Scaffold(body: TerminalView(terminal, autofocus: true)),
    ));
    await tester.pump();

    for (final text in ['ㅎ', '하', '한']) {
      tester.testTextInput.updateEditingValue(TextEditingValue(
        text: text,
        selection: const TextSelection.collapsed(offset: 1),
        composing: const TextRange(start: 0, end: 1),
      ));
      await tester.pump();
    }
    expect(sent, isEmpty);
    tester.testTextInput.updateEditingValue(const TextEditingValue(
      text: '한',
      selection: TextSelection.collapsed(offset: 1),
    ));
    await tester.pump();
    expect(sent, ['한']);
    await tester.pumpWidget(const SizedBox.shrink());
  });
}
