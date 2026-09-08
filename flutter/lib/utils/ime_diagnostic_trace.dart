import 'dart:convert';

/// Opt-in trace for the fixed Korean test phrase, not a general key logger.
class ImeDiagnosticTrace {
  ImeDiagnosticTrace(this.write);

  final void Function(String) write;
  final Stopwatch _clock = Stopwatch();
  int _events = 0;
  static final _sampleRunes =
      'ㅎ하한ㄱ그글ㅇ이입ㄴㄹ리러려력ㄷㄸㄲㅣㆍᆞᆢㅏㅓㅕㅑㅡㅂㅍㅜㅗㅛㅠㅔㅐㅖㅒ '.runes.toSet();

  void emit(String stage, String text, Map<String, Object> fields) {
    if (!_clock.isRunning) _clock.start();
    if (_events >= 256 || _clock.elapsed > const Duration(minutes: 2)) return;
    final sample = text.replaceFirst(RegExp(r'^1+'), '');
    final allowed =
        sample.length <= 32 && sample.runes.every(_sampleRunes.contains);
    write('[MDeskIme] ${jsonEncode({
          'n': ++_events,
          'ms': _clock.elapsedMilliseconds,
          'stage': stage,
          ...fields,
          'length': sample.length,
          if (allowed)
            'codepoints': sample.runes.map((r) => r.toRadixString(16)).toList()
          else
            'redacted': true,
        })}');
  }
}
