import 'dart:convert';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_hbb/desktop/widgets/whiteboard_overlay.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final start = DateTime(2026, 10, 3);

  DrawingStroke stroke({
    WhiteboardTool tool = WhiteboardTool.pen,
    DateTime? completedAt,
    bool eraser = false,
  }) =>
      DrawingStroke(
        points: const [Offset(16, 32), Offset(48, 32)],
        color: eraser ? Colors.transparent : Colors.red,
        strokeWidth: 8,
        tool: tool,
        isEraser: eraser,
        completedAt: completedAt ?? start,
      );

  String message(Map<String, dynamic> data) =>
      '$kWhiteboardPrefix${jsonEncode(data)}';

  String strokeMessage() => message({
        'type': 'stroke',
        ...stroke().toJson(),
      });

  Future<int> centerAlpha(CustomPainter painter) async {
    final recorder = ui.PictureRecorder();
    painter.paint(Canvas(recorder), const Size(64, 64));
    final picture = recorder.endRecording();
    final image = await picture.toImage(64, 64);
    final pixels = await image.toByteData(format: ui.ImageByteFormat.rawRgba);
    final alpha = pixels!.getUint8((32 * 64 + 32) * 4 + 3);
    image.dispose();
    picture.dispose();
    return alpha;
  }

  WhiteboardPainter senderPainter(List<DrawingStroke> strokes, DateTime time,
          {List<Offset> currentPoints = const []}) =>
      WhiteboardPainter(
        strokes: strokes,
        fadeTime: time,
        currentPoints: currentPoints,
        currentColor: Colors.red,
        currentStrokeWidth: 8,
        currentTool: WhiteboardTool.pen,
      );

  test('completed strokes fade linearly and keep wire format unchanged', () {
    final line = stroke();
    expect(line.opacityAt(start), 1);
    expect(line.opacityAt(start.add(const Duration(milliseconds: 1500))), 0.5);
    expect(line.opacityAt(start.add(kWhiteboardStrokeFadeDuration)), 0);
    expect(line.opacityAt(start.add(const Duration(seconds: 10))), 0);
    expect(line.opacityAt(start.subtract(const Duration(seconds: 1))), 1);
    expect(
        line.toJson().keys,
        unorderedEquals(
            ['points', 'color', 'strokeWidth', 'tool', 'isEraser']));
  });

  testWidgets('fade starts on release and each stroke expires independently',
      (tester) async {
    final controller = WhiteboardController(now: tester.binding.clock.now);
    addTearDown(controller.onClose);
    controller.startStroke(const Offset(16, 32));
    controller.addPoint(const Offset(48, 32));
    await tester.pump(const Duration(seconds: 5));
    expect(controller.strokes, isEmpty);
    expect(controller.currentPoints, hasLength(2));

    controller.endStroke();
    final first = controller.strokes.single;
    expect(first.opacityAt(controller.fadeTime.value), 1);
    await tester.pump(const Duration(milliseconds: 1500));
    expect(first.opacityAt(controller.fadeTime.value), closeTo(0.5, 0.02));
    controller.startStroke(const Offset(16, 40));
    controller.endStroke();
    final second = controller.strokes.last;
    await tester.pump(const Duration(milliseconds: 1550));
    expect(controller.strokes, [second]);
    expect(second.opacityAt(controller.fadeTime.value), closeTo(0.5, 0.03));
    await tester.pump(const Duration(milliseconds: 1500));
    expect(controller.strokes, isEmpty);

    final stoppedAt = controller.fadeTime.value;
    await tester.pump(const Duration(seconds: 1));
    expect(controller.fadeTime.value, stoppedAt);
  });

  testWidgets('undo, clear, resize, disable and disposal stop sender timer',
      (tester) async {
    final controller = WhiteboardController(now: tester.binding.clock.now);
    addTearDown(controller.onClose);
    Future<void> expectStopped() async {
      final stoppedAt = controller.fadeTime.value;
      await tester.pump(const Duration(milliseconds: 100));
      expect(controller.fadeTime.value, stoppedAt);
    }

    void draw() {
      controller.startStroke(const Offset(16, 32));
      controller.endStroke();
    }

    draw();
    controller.undo();
    expect(controller.strokes, isEmpty);
    await expectStopped();
    draw();
    controller.clear();
    expect(controller.strokes, isEmpty);
    await expectStopped();
    draw();
    controller.clearLocalOnly();
    expect(controller.strokes, isEmpty);
    await expectStopped();
    controller.toggle();
    draw();
    controller.toggle();
    expect(controller.isEnabled.value, isFalse);
    expect(controller.strokes, isEmpty);
    await expectStopped();
    draw();
    controller.onClose();
    await expectStopped();
  });

  testWidgets('receiver fades incoming strokes and cancels timers on commands',
      (tester) async {
    final controller =
        WhiteboardReceiverController(now: tester.binding.clock.now);
    addTearDown(controller.onClose);
    controller.setCanvasSize(const Size(64, 64));
    controller.handleMessage(message({'type': 'state', 'enabled': true}));
    controller.handleMessage(strokeMessage());
    await tester.pump(const Duration(milliseconds: 1500));
    expect(controller.strokes.single.opacityAt(controller.fadeTime.value),
        closeTo(0.5, 0.02));
    await tester.pump(const Duration(milliseconds: 1550));
    expect(controller.strokes, isEmpty);

    for (final command in [
      {'type': 'undo'},
      {'type': 'clear'},
      {'type': 'state', 'enabled': false},
    ]) {
      controller.handleMessage(strokeMessage());
      controller.handleMessage(message(command));
      expect(controller.strokes, isEmpty);
      final stoppedAt = controller.fadeTime.value;
      await tester.pump(const Duration(milliseconds: 100));
      expect(controller.fadeTime.value, stoppedAt);
    }
    controller.handleMessage(strokeMessage());
    controller.clear();
    expect(controller.strokes, isEmpty);
    expect(controller.isEnabled.value, isFalse);
    controller.handleMessage(strokeMessage());
    controller.onClose();
    final stoppedAt = controller.fadeTime.value;
    await tester.pump(const Duration(milliseconds: 100));
    expect(controller.fadeTime.value, stoppedAt);
  });

  for (final tool in [WhiteboardTool.pen, WhiteboardTool.highlighter]) {
    test('both painters fade $tool pixels to transparent', () async {
      final lines = [stroke(tool: tool)];
      for (final receiver in [false, true]) {
        CustomPainter painter(DateTime time) => receiver
            ? WhiteboardReceiverPainter(strokes: lines, fadeTime: time)
            : senderPainter(lines, time);
        final initial = await centerAlpha(painter(start));
        final halfway = await centerAlpha(
            painter(start.add(const Duration(milliseconds: 1500))));
        final expired = await centerAlpha(
            painter(start.add(kWhiteboardStrokeFadeDuration)));
        expect(initial, tool == WhiteboardTool.pen ? 255 : closeTo(102, 1));
        expect(halfway, closeTo(initial / 2, 1));
        expect(expired, 0);
      }
    });
  }

  test('active preview stays visible and fading erasers keep lines erased',
      () async {
    final now = start.add(const Duration(seconds: 2));
    expect(
        await centerAlpha(senderPainter([], now,
            currentPoints: const [Offset(16, 32), Offset(48, 32)])),
        255);
    final lines = [
      stroke(),
      stroke(
          tool: WhiteboardTool.eraser,
          eraser: true,
          completedAt: start.add(const Duration(seconds: 1))),
    ];
    expect(await centerAlpha(senderPainter(lines, now)), 0);
    expect(
        await centerAlpha(
            WhiteboardReceiverPainter(strokes: lines, fadeTime: now)),
        0);
  });

  test('painters repaint when only fade time changes', () {
    final lines = [stroke()];
    final next = start.add(const Duration(milliseconds: 33));
    expect(
        senderPainter(lines, next).shouldRepaint(senderPainter(lines, start)),
        isTrue);
    expect(
        WhiteboardReceiverPainter(strokes: lines, fadeTime: next).shouldRepaint(
            WhiteboardReceiverPainter(strokes: lines, fadeTime: start)),
        isTrue);
  });
}
