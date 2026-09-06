import 'dart:convert';
import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_hbb/utils/connection_diagnostics.dart';

void main() {
  test('persists ordered JSONL without credentials or ID URL suffixes',
      () async {
    final dir =
        await Directory.systemTemp.createTemp('mdesk-diagnostics-test-');
    try {
      final log = DiagnosticTimeline(dir);
      log.event('connect.clicked', peer: '123/r@host?key=SECRET', fields: {
        'password': 'SECRET',
        'token': 'SECRET',
        'body': 'SECRET',
        'ready': 'waiting',
        'automatic': false,
      });
      log.event('connect.dispatched', peer: '123');
      await log.flush();
      final file = (await dir.list().toList()).whereType<File>().single;
      final text = await file.readAsString();
      expect(text, isNot(contains('SECRET')));
      final records =
          const LineSplitter().convert(text).map(jsonDecode).toList();
      expect(records.map((e) => e['stage']),
          ['connect.clicked', 'connect.dispatched']);
      expect(records.first['peer'], '123');
      expect(records.first['ready'], 'waiting');
      expect(records.first['automatic'], 'false');
      // A new writer/process lifecycle doesn't truncate the first run.
      await Future<void>.delayed(const Duration(milliseconds: 2));
      final next = DiagnosticTimeline(dir);
      next.event('restart');
      await next.flush();
      expect(await file.readAsString(), text);
    } finally {
      await dir.delete(recursive: true);
    }
  });

  test('rotates at the byte limit and prunes only expired diagnostic files',
      () async {
    final dir =
        await Directory.systemTemp.createTemp('mdesk-diagnostics-test-');
    try {
      final old = File('${dir.path}/mdesk-ui-diag-old.jsonl');
      await old.writeAsString('old');
      await old
          .setLastModified(DateTime.now().subtract(const Duration(days: 8)));
      final unrelated = File('${dir.path}/keep.txt');
      await unrelated.writeAsString('keep');
      await unrelated
          .setLastModified(DateTime.now().subtract(const Duration(days: 8)));
      final log = DiagnosticTimeline(dir, maxBytes: 350);
      for (var i = 0; i < 10; i++) {
        log.event('event$i');
      }
      await log.flush();
      expect(await old.exists(), false);
      expect(await unrelated.exists(), true);
      final files = (await dir.list().toList())
          .whereType<File>()
          .where((e) => e.path.endsWith('.jsonl'))
          .toList();
      expect(files.length, 3);
      final stages = <String>[];
      for (final file in files) {
        expect(await file.length(), lessThanOrEqualTo(350));
        stages.addAll((await file.readAsLines())
            .map((line) => jsonDecode(line)['stage'] as String));
      }
      expect(stages, contains('event9'));
      expect(stages, isNot(contains('event0')));
    } finally {
      await dir.delete(recursive: true);
    }
  });
}
