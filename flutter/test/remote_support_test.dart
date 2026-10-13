import 'dart:async';
import 'dart:convert';

import 'package:flutter_hbb/common/remote_support.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('disabling and re-enabling incoming access preserves other options',
      () async {
    var options = <String, dynamic>{
      'custom-rendezvous-server': 'example.invalid',
      'verification-method': 'use-both-passwords',
      'enable-keyboard': 'N',
    };
    final original = Map<String, dynamic>.from(options);
    for (final enabled in [false, true]) {
      await setRemoteSupportEnabled(
        enabled: enabled,
        readOptions: () async => jsonEncode(options),
        writeOptions: (json) async => options = jsonDecode(json),
      );
      expect(options['stop-service'], enabled ? 'N' : 'Y');
      expect(Map.of(options)..remove('stop-service'), original);
    }
  });

  test('waits for the native write before completing', () async {
    final writeStarted = Completer<void>();
    final writeFinished = Completer<void>();
    var completed = false;
    final change = setRemoteSupportEnabled(
      enabled: false,
      readOptions: () async => '{}',
      writeOptions: (_) {
        writeStarted.complete();
        return writeFinished.future;
      },
    ).then((_) => completed = true);
    await writeStarted.future;
    expect(completed, isFalse);
    writeFinished.complete();
    await change;
    expect(completed, isTrue);
  });

  test('invalid settings never overwrite configuration', () async {
    var wrote = false;
    await expectLater(
      setRemoteSupportEnabled(
        enabled: false,
        readOptions: () async => 'invalid',
        writeOptions: (_) async => wrote = true,
      ),
      throwsFormatException,
    );
    expect(wrote, isFalse);
  });

  test('native write errors propagate to the caller', () async {
    await expectLater(
      setRemoteSupportEnabled(
        enabled: true,
        readOptions: () async => '{"stop-service":"Y"}',
        writeOptions: (_) async => throw StateError('write failed'),
      ),
      throwsStateError,
    );
  });
}
