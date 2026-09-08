import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_hbb/utils/soft_keyboard_input.dart';

void main() {
  test('vowel-only replacement of hidden padding never deletes remote content',
      () async {
    final sent = <String>[];
    final input = SoftKeyboardInput(
      sendBackspace: () async {
        sent.add('<back>');
      },
      sendText: (value) async {
        sent.add(value);
      },
      onError: (error, _) => fail('$error'),
    );
    input.reset('1' * 1024);
    input.update('ㆍ', composingStart: 0, composingEnd: 1);
    await input.pending;
    expect(sent, isEmpty);
    input.update('ㅏ', composingStart: 0, composingEnd: 1);
    await input.pending;
    expect(sent, ['ㅏ']);
  });
  test('actual Samsung trace never sends transient vowel dots or over-deletes',
      () async {
    var remote = '';
    final operations = <String>[];
    final input = SoftKeyboardInput(
      sendBackspace: () async {
        operations.add('<back>');
        remote = remote.substring(0, remote.length - 1);
      },
      sendText: (value) async {
        operations.add(value);
        remote += value;
      },
      onError: (error, _) => fail('$error'),
    );
    final padding = '1' * 1024;
    input.reset(padding);
    // Values and composing ranges captured from the user's actual phone.
    for (final value in [
      '한글입',
      '한글입ㄴ',
      '한글입ㄹ',
      '한글입ㄹㆍ',
      '한글입ㄹᆢ',
      '한글입려',
      '한글입력'
    ]) {
      input.update('$padding$value',
          composingStart: 963, composingEnd: padding.length + value.length);
    }
    await input.pending;
    expect(remote, '한글입력');
    expect(
        operations, ['한글입', 'ㄴ', '<back>', 'ㄹ', '<back>', '려', '<back>', '력']);
  });

  test('dot cancellation and composition-only commit keep sent text consistent',
      () async {
    var remote = '';
    final input = SoftKeyboardInput(
      sendBackspace: () async {
        remote = remote.substring(0, remote.length - 1);
      },
      sendText: (value) async {
        remote += value;
      },
      onError: (error, _) => fail('$error'),
    );
    input.update('ㄹ', composingStart: 0, composingEnd: 1);
    input.update('ㄹㆍ', composingStart: 0, composingEnd: 2);
    input.update('ㄹ', composingStart: 0, composingEnd: 1); // Cancel vowel dot.
    await input.pending;
    expect(remote, 'ㄹ');
    input.update('ㄹᆞ', composingStart: 0, composingEnd: 2);
    await input.pending;
    expect(remote, 'ㄹ');
    input.update(
        'ㄹᆞ'); // Same text, but composing range cleared: deliberate archaic text.
    await input.pending;
    expect(remote, 'ㄹᆞ');
    input.update('ㄹ');
    await input.pending;
    expect(remote, 'ㄹ');
  });

  test('only temporary glyphs inside the composing range are filtered',
      () async {
    final sent = <String>[];
    final input = SoftKeyboardInput(
      sendBackspace: () async {
        sent.add('<back>');
      },
      sendText: (value) async {
        sent.add(value);
      },
      onError: (error, _) => fail('$error'),
    );
    input.update('ㆍㄹᆢ', composingStart: 1, composingEnd: 3);
    await input.pending;
    expect(sent, ['ㆍㄹ']);
  });

  test('rapid Hangul edits wait for native deletion and insertion completion',
      () async {
    final operations = <String>[];
    final gates = <Completer<void>>[];
    var remote = '';
    Future<void> submit(String value) async {
      operations.add(value);
      final gate = Completer<void>();
      gates.add(gate);
      await gate.future;
      remote = value == '<back>'
          ? remote.substring(0, remote.length - 1)
          : remote + value;
    }

    final input = SoftKeyboardInput(
      sendBackspace: () => submit('<back>'),
      sendText: submit,
      onError: (error, _) => fail('$error'),
    );
    input.reset('111');
    for (final value in ['ㄴ', 'ㄹ', '리', '러', '려', '력']) {
      input.update('111$value');
    }
    const expected = [
      'ㄴ',
      '<back>',
      'ㄹ',
      '<back>',
      '리',
      '<back>',
      '러',
      '<back>',
      '려',
      '<back>',
      '력'
    ];
    for (var i = 0; i < expected.length; i++) {
      await Future<void>.delayed(Duration.zero);
      expect(operations, expected.take(i + 1).toList());
      gates[i].complete();
    }
    await input.pending;
    expect(remote, '력');
    input.update(
        '111력'); // Identical notifications cannot duplicate the syllable.
    await input.pending;
    expect(operations, expected);
  });

  test('word composition, English edits and external paste preserve text',
      () async {
    var remote = '';
    final input = SoftKeyboardInput(
      sendBackspace: () async {
        remote = remote.substring(0, remote.length - 1);
      },
      sendText: (value) async {
        remote += value;
      },
      onError: (error, _) => fail('$error'),
    );
    input.reset('111');
    for (final value in [
      'ㅎ',
      '하',
      '한',
      '한ㄱ',
      '한그',
      '한글',
      '한글ㅇ',
      '한글이',
      '한글입',
      '한글입ㄴ',
      '한글입ㄹ',
      '한글입리',
      '한글입러',
      '한글입려',
      '한글입력'
    ]) {
      input.update('111$value');
    }
    await input.pending;
    expect(remote, '한글입력');
    for (final value in [' a', ' ab', ' abc', ' ab', ' aB']) {
      input.update('111한글입력$value');
    }
    await input.pending;
    expect(remote, '한글입력 aB');
    input.reset('111');
    input.update('붙여넣기');
    await input.pending;
    expect(remote, '한글입력 aB붙여넣기');
  });

  test('closing session drops queued replacements after in-flight call',
      () async {
    final gate = Completer<void>();
    final sent = <String>[];
    final input = SoftKeyboardInput(
      sendBackspace: () async {
        sent.add('<back>');
      },
      sendText: (value) async {
        sent.add(value);
        await gate.future;
      },
      onError: (error, _) => fail('$error'),
    );
    input.update('ㄹ');
    input.update('력');
    await Future<void>.delayed(Duration.zero);
    input.dispose();
    gate.complete();
    await input.pending;
    expect(sent, ['ㄹ']);
  });

  test('failed edit does not replay text or send later destructive diffs',
      () async {
    final sent = <String>[];
    final errors = <Object>[];
    final input = SoftKeyboardInput(
      sendBackspace: () async {
        sent.add('<back>');
        throw StateError('bridge failed');
      },
      sendText: (value) async {
        sent.add(value);
      },
      onError: (error, _) => errors.add(error),
    );
    input.update('ㄹ');
    input.update('려');
    input.update('력');
    await input.pending;
    expect(sent, ['ㄹ', '<back>']);
    expect(errors, hasLength(1));
  });
}
