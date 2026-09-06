import 'dart:async';
import 'dart:convert';
import 'dart:io';

/// Independent of debugPrint/release logging. No credentials or API bodies.
class ConnectionDiagnostics {
  static final timeline = DiagnosticTimeline(Directory(
      '${Platform.environment['LOCALAPPDATA'] ?? Directory.systemTemp.path}'
      '${Platform.pathSeparator}MDesk${Platform.pathSeparator}diagnostics'));

  static void event(String stage,
      {String peer = '', Map<String, Object?> fields = const {}}) {
    timeline.event(stage, peer: peer, fields: fields);
  }
}

/// Serial asynchronous writes with bounded backlog, 3 x 2 MiB per run,
/// and seven-day retention. Export while running or after the app exits.
class DiagnosticTimeline {
  DiagnosticTimeline(this.directory, {this.maxBytes = 2 * 1024 * 1024});
  final Directory directory;
  final int maxBytes;
  final _clock = Stopwatch()..start();
  final _run = '${DateTime.now().millisecondsSinceEpoch}-$pid';
  Future<void> _tail = Future.value();
  File? _file;
  int _bytes = 0;
  int _pending = 0;
  int _dropped = 0;
  bool _reportedFailure = false;

  static String peerId(String value) {
    final id = value
        .split(RegExp(r'[@?/]'))
        .first
        .replaceAll(RegExp(r'[^a-zA-Z0-9-]'), '');
    return id.substring(0, id.length.clamp(0, 80));
  }

  void event(String stage,
      {String peer = '', Map<String, Object?> fields = const {}}) {
    if (_pending >= 512) {
      _dropped++;
      return;
    }
    final safe = <String, Object?>{};
    for (final entry in fields.entries) {
      if (const {
        'duration_ms',
        'status',
        'ready',
        'registered',
        'automatic',
        'attempt',
        'result',
        'has_cert',
        'in_list',
        'phase'
      }.contains(entry.key)) {
        final text = entry.value.toString();
        safe[entry.key] = text.substring(0, text.length.clamp(0, 128));
      }
    }
    final line = '${jsonEncode({
          'schema': 1,
          'epoch_ms': DateTime.now().millisecondsSinceEpoch,
          'process_ms': _clock.elapsedMilliseconds,
          'pid': pid,
          'run': _run,
          'role': 'controller_ui',
          'peer': peerId(peer),
          'stage': stage,
          'dropped': _dropped,
          ...safe,
        })}\n';
    _dropped = 0;
    _pending++;
    _tail = _tail.then((_) => _write(line)).catchError((Object error) {
      if (!_reportedFailure) {
        _reportedFailure = true;
        stderr.writeln('MDesk connection diagnostics: write failed');
      }
    }).whenComplete(() {
      _pending--;
    });
  }

  Future<void> _write(String line) async {
    if (_file == null) {
      await directory.create(recursive: true);
      final cutoff = DateTime.now().subtract(const Duration(days: 7));
      await for (final entry in directory.list(followLinks: false)) {
        if (entry is File &&
            entry.uri.pathSegments.last.startsWith('mdesk-ui-diag-') &&
            entry.path.endsWith('.jsonl')) {
          try {
            if ((await entry.stat()).modified.isBefore(cutoff)) {
              await entry.delete();
            }
          } on FileSystemException {/* Another process may have rotated it. */}
        }
      }
      _file = File(
          '${directory.path}${Platform.pathSeparator}mdesk-ui-diag-$_run.jsonl');
    }
    final bytes = utf8.encode(line);
    if (_bytes + bytes.length > maxBytes) {
      final oldest = File('${_file!.path}.2.jsonl');
      if (await oldest.exists()) await oldest.delete();
      final previous = File('${_file!.path}.1.jsonl');
      if (await previous.exists()) await previous.rename(oldest.path);
      if (await _file!.exists()) await _file!.rename(previous.path);
      _bytes = 0;
    }
    await _file!.writeAsBytes(bytes, mode: FileMode.append, flush: true);
    _bytes += bytes.length;
  }

  Future<void> flush() => _tail;
}
