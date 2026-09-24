import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_hbb/common.dart' show SessionID;
import 'package:flutter_hbb/consts.dart';
import 'package:flutter_hbb/desktop/models/remote_pane_geometry.dart';
import 'package:flutter_hbb/models/input_model.dart';
import 'package:flutter_hbb/models/model.dart';

class _Session extends Fake implements FFI {
  @override
  final sessionId = SessionID('00000000-0000-4000-8000-000000000001');
}

void main() {
  test('two pane inputs sharing a session keep independent display transforms',
      () {
    final session = _Session();
    final leftGeometry = RemotePaneGeometry(
        viewport: const Rect.fromLTWH(0, 0, 400, 300),
        display: const Rect.fromLTWH(-1600, 0, 1600, 1200));
    final rightGeometry = RemotePaneGeometry(
        viewport: const Rect.fromLTWH(404, 0, 400, 300),
        display: const Rect.fromLTWH(0, 0, 1920, 1080));
    final left = InputModel(WeakReference<FFI>(session))
      ..pointerPositionMapper =
          (point, clamp) => leftGeometry.toRemote(point, clamp: clamp);
    final right = InputModel(WeakReference<FFI>(session))
      ..pointerPositionMapper =
          (point, clamp) => rightGeometry.toRemote(point, clamp: clamp);
    final leftPoint = left.handlePointerDevicePos(
        kPointerEventKindMouse, 200, 150, true, kMouseEventTypeDefault,
        buttons: 0)!;
    final rightPoint = right.handlePointerDevicePos(
        kPointerEventKindMouse, 604, 150, true, kMouseEventTypeDefault,
        buttons: 0)!;
    expect(left.sessionId, right.sessionId);
    expect(Offset(leftPoint.x.toDouble(), leftPoint.y.toDouble()),
        const Offset(-800, 600));
    expect(Offset(rightPoint.x.toDouble(), rightPoint.y.toDouble()),
        const Offset(960, 540));
  });

  test('hidden legacy pointer path is disabled before coordinate conversion',
      () {
    final session = _Session();
    var calls = 0;
    final input = InputModel(WeakReference<FFI>(session))
      ..pointerInputEnabled = false
      ..pointerPositionMapper = (point, clamp) {
        calls++;
        return point;
      };
    expect(
        input.handlePointerDevicePos(
            kPointerEventKindMouse, 10, 20, true, kMouseEventTypeDefault),
        isNull);
    expect(
        input.handleMouse(
            {'buttons': 0, 'type': 'mousemove'}, const Offset(10, 20)),
        isNull);
    expect(calls, 0);
  });

  test('drag and release clamp to original pane, ordinary hover does not', () {
    final session = _Session();
    final seen = <bool>[];
    final input = InputModel(WeakReference<FFI>(session))
      ..pointerPositionMapper = (point, clamp) {
        seen.add(clamp);
        return point;
      };
    input.handlePointerDevicePos(
        kPointerEventKindMouse, 10, 20, true, kMouseEventTypeDefault,
        buttons: 0);
    input.handlePointerDevicePos(
        kPointerEventKindMouse, 10, 20, true, kMouseEventTypeDefault,
        buttons: 1);
    input.handlePointerDevicePos(
        kPointerEventKindMouse, 10, 20, false, kMouseEventTypeUp,
        buttons: 2);
    expect(seen, [false, true, true]);
  });
}
