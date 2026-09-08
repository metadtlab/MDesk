import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_hbb/utils/ime_diagnostic_trace.dart';

void main() {
  test('trace limits text to sample Hangul and caps event count', () {
    final lines = <String>[];
    final trace = ImeDiagnosticTrace(lines.add);
    trace.emit('ime', '111한글입력', {});
    expect(lines.single, contains('b825'));
    expect(lines.single, isNot(contains('111')));
    trace.emit('ime', 'secret-password', {});
    expect(lines.last, contains('"redacted":true'));
    expect(lines.last, isNot(contains('secret')));
    for (var i = 0; i < 300; i++) {
      trace.emit('ack', '', {});
    }
    expect(lines.length, 256);
  });
}
