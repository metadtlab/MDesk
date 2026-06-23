import 'dart:async';
import 'dart:math';
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter_hbb/common.dart';

typedef ScreenshotPngAction = Future<void> Function(Uint8List png);
typedef ScreenshotRgbaAction = Future<void> Function(ScreenshotRgba image);

class ScreenshotRgba {
  const ScreenshotRgba({
    required this.width,
    required this.height,
    required this.rgba,
  });

  final int width;
  final int height;
  final Uint8List rgba;
}

enum _ScreenshotTool { crop, pen }

class ScreenshotEditor extends StatefulWidget {
  const ScreenshotEditor({
    Key? key,
    required this.initialPng,
    required this.onSave,
    required this.onCopy,
    required this.onClose,
  }) : super(key: key);

  final Uint8List initialPng;
  final ScreenshotPngAction onSave;
  final ScreenshotRgbaAction onCopy;
  final VoidCallback onClose;

  @override
  State<ScreenshotEditor> createState() => _ScreenshotEditorState();
}

class _ScreenshotEditorState extends State<ScreenshotEditor> {
  ui.Image? _image;
  final List<_EditorStroke> _strokes = [];
  _EditorStroke? _activeStroke;
  Rect? _cropRect;
  Offset? _dragStart;
  _ScreenshotTool _tool = _ScreenshotTool.crop;
  Color _penColor = Colors.red;
  double _penWidth = 4;
  bool _busy = false;
  String? _error;

  static const List<Color> _penColors = [
    Colors.red,
    Colors.yellow,
    Colors.blue,
    Colors.green,
    Colors.white,
    Colors.black,
  ];

  @override
  void initState() {
    super.initState();
    _load(widget.initialPng);
  }

  @override
  void dispose() {
    _image?.dispose();
    super.dispose();
  }

  Future<void> _load(Uint8List bytes) async {
    try {
      final image = await _decodeImage(bytes);
      if (!mounted) {
        image.dispose();
        return;
      }
      setState(() {
        _image?.dispose();
        _image = image;
        _strokes.clear();
        _activeStroke = null;
        _cropRect = null;
        _error = null;
      });
    } catch (e) {
      if (mounted) {
        setState(() => _error = e.toString());
      }
    }
  }

  Future<ui.Image> _decodeImage(Uint8List bytes) async {
    final codec = await ui.instantiateImageCodec(bytes);
    final frame = await codec.getNextFrame();
    return frame.image;
  }

  Future<void> _run(Future<void> Function() action) async {
    if (_busy) return;
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      await action();
    } catch (e) {
      if (mounted) {
        setState(() => _error = e.toString());
      }
    } finally {
      if (mounted) {
        setState(() => _busy = false);
      }
    }
  }

  void _setTool(_ScreenshotTool tool) {
    setState(() {
      _tool = tool;
      _activeStroke = null;
    });
  }

  void _undo() {
    setState(() {
      if (_strokes.isNotEmpty) {
        _strokes.removeLast();
      } else {
        _cropRect = null;
      }
    });
  }

  void _reset() {
    _run(() => _load(widget.initialPng));
  }

  Future<void> _applyCrop() async {
    final crop = _effectiveCropRect();
    if (crop == null) return;
    await _run(() async {
      final png = await _renderPng(crop: crop);
      final image = await _decodeImage(png);
      if (!mounted) {
        image.dispose();
        return;
      }
      setState(() {
        _image?.dispose();
        _image = image;
        _strokes.clear();
        _activeStroke = null;
        _cropRect = null;
      });
    });
  }

  Future<void> _save() => _run(() async {
        final png = await _renderPng();
        await widget.onSave(png);
      });

  Future<void> _copy() => _run(() async {
        final rgba = await _renderRgba();
        await widget.onCopy(rgba);
      });

  void _onPanStart(DragStartDetails details, Size size) {
    final imagePoint = _imagePointFromLocal(details.localPosition, size);
    if (imagePoint == null) return;
    setState(() {
      if (_tool == _ScreenshotTool.crop) {
        _dragStart = imagePoint;
        _cropRect = Rect.fromPoints(imagePoint, imagePoint);
      } else {
        _activeStroke =
            _EditorStroke(color: _penColor, width: _penWidth, points: [
          imagePoint,
        ]);
        _strokes.add(_activeStroke!);
      }
    });
  }

  void _onPanUpdate(DragUpdateDetails details, Size size) {
    final imagePoint = _imagePointFromLocal(details.localPosition, size);
    if (imagePoint == null) return;
    setState(() {
      if (_tool == _ScreenshotTool.crop) {
        final start = _dragStart ?? imagePoint;
        _cropRect = _normalizeRect(Rect.fromPoints(start, imagePoint));
      } else {
        _activeStroke?.points.add(imagePoint);
      }
    });
  }

  void _onPanEnd(DragEndDetails details) {
    setState(() {
      _dragStart = null;
      _activeStroke = null;
    });
  }

  Offset? _imagePointFromLocal(Offset local, Size size) {
    final image = _image;
    if (image == null) return null;
    final imageRect = _imageRect(size, image);
    if (!imageRect.contains(local)) return null;
    final dx = ((local.dx - imageRect.left) / imageRect.width) * image.width;
    final dy = ((local.dy - imageRect.top) / imageRect.height) * image.height;
    return Offset(
      dx.clamp(0.0, image.width.toDouble()),
      dy.clamp(0.0, image.height.toDouble()),
    );
  }

  Rect? _effectiveCropRect() {
    final image = _image;
    final crop = _cropRect;
    if (image == null || crop == null) return null;
    final rect = _normalizeRect(crop);
    final left = rect.left.clamp(0.0, image.width.toDouble()).floor();
    final top = rect.top.clamp(0.0, image.height.toDouble()).floor();
    final right = rect.right.clamp(0.0, image.width.toDouble()).ceil();
    final bottom = rect.bottom.clamp(0.0, image.height.toDouble()).ceil();
    if (right - left < 2 || bottom - top < 2) return null;
    return Rect.fromLTRB(
      left.toDouble(),
      top.toDouble(),
      right.toDouble(),
      bottom.toDouble(),
    );
  }

  Rect _normalizeRect(Rect rect) {
    return Rect.fromLTRB(
      min(rect.left, rect.right),
      min(rect.top, rect.bottom),
      max(rect.left, rect.right),
      max(rect.top, rect.bottom),
    );
  }

  Future<ui.Image> _renderImage({Rect? crop}) async {
    final image = _image;
    if (image == null) throw StateError('No screenshot image');
    final recorder = ui.PictureRecorder();
    final canvas = Canvas(recorder);
    canvas.drawImage(image, Offset.zero, Paint());
    _paintStrokes(canvas, _strokes);
    final composed =
        await recorder.endRecording().toImage(image.width, image.height);

    ui.Image output = composed;
    if (crop != null) {
      final cropWidth = crop.width.round().clamp(1, image.width).toInt();
      final cropHeight = crop.height.round().clamp(1, image.height).toInt();
      final cropRecorder = ui.PictureRecorder();
      final cropCanvas = Canvas(cropRecorder);
      cropCanvas.drawImageRect(
        composed,
        crop,
        Rect.fromLTWH(0, 0, cropWidth.toDouble(), cropHeight.toDouble()),
        Paint(),
      );
      output = await cropRecorder.endRecording().toImage(cropWidth, cropHeight);
      composed.dispose();
    }

    return output;
  }

  Future<Uint8List> _renderPng({Rect? crop}) async {
    final output = await _renderImage(crop: crop);
    try {
      final bytes = await output.toByteData(format: ui.ImageByteFormat.png);
      if (bytes == null) throw StateError('Failed to encode PNG');
      return bytes.buffer.asUint8List(bytes.offsetInBytes, bytes.lengthInBytes);
    } finally {
      output.dispose();
    }
  }

  Future<ScreenshotRgba> _renderRgba() async {
    final output = await _renderImage();
    try {
      final bytes = await output.toByteData(format: ui.ImageByteFormat.rawRgba);
      if (bytes == null) throw StateError('Failed to export image');
      return ScreenshotRgba(
        width: output.width,
        height: output.height,
        rgba: bytes.buffer.asUint8List(
          bytes.offsetInBytes,
          bytes.lengthInBytes,
        ),
      );
    } finally {
      output.dispose();
    }
  }

  void _paintStrokes(Canvas canvas, List<_EditorStroke> strokes) {
    for (final stroke in strokes) {
      if (stroke.points.isEmpty) continue;
      final paint = Paint()
        ..color = stroke.color
        ..strokeWidth = stroke.width
        ..style = PaintingStyle.stroke
        ..strokeCap = StrokeCap.round
        ..strokeJoin = StrokeJoin.round;
      if (stroke.points.length == 1) {
        canvas.drawCircle(stroke.points.first, stroke.width / 2, paint);
        continue;
      }
      final path = Path()
        ..moveTo(stroke.points.first.dx, stroke.points.first.dy);
      for (final point in stroke.points.skip(1)) {
        path.lineTo(point.dx, point.dy);
      }
      canvas.drawPath(path, paint);
    }
  }

  @override
  Widget build(BuildContext context) {
    final screenSize = MediaQuery.of(context).size;
    final width =
        min(screenSize.width - 80, 980.0).clamp(420.0, 980.0).toDouble();
    final height =
        min(screenSize.height - 120, 720.0).clamp(360.0, 720.0).toDouble();
    return SizedBox(
      width: width,
      height: height,
      child: Column(
        children: [
          _buildToolbar(context),
          const SizedBox(height: 10),
          Expanded(child: _buildCanvas()),
          if (_error != null)
            Padding(
              padding: const EdgeInsets.only(top: 8),
              child: Text(
                _error!,
                style: const TextStyle(color: Colors.red),
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
              ),
            ),
          const SizedBox(height: 10),
          _buildActions(),
        ],
      ),
    );
  }

  Widget _buildToolbar(BuildContext context) {
    final canApplyCrop = _effectiveCropRect() != null;
    return Wrap(
      spacing: 10,
      runSpacing: 8,
      crossAxisAlignment: WrapCrossAlignment.center,
      children: [
        ToggleButtons(
          isSelected: [
            _tool == _ScreenshotTool.crop,
            _tool == _ScreenshotTool.pen,
          ],
          onPressed: _busy
              ? null
              : (index) => _setTool(
                    index == 0 ? _ScreenshotTool.crop : _ScreenshotTool.pen,
                  ),
          borderRadius: BorderRadius.circular(6),
          constraints: const BoxConstraints(minWidth: 42, minHeight: 36),
          children: [
            Tooltip(
              message: translate('Crop'),
              child: const Icon(Icons.crop),
            ),
            Tooltip(
              message: translate('Pen'),
              child: const Icon(Icons.brush),
            ),
          ],
        ),
        IconButton(
          tooltip: translate('Apply crop'),
          onPressed: _busy || !canApplyCrop ? null : _applyCrop,
          icon: const Icon(Icons.check),
        ),
        IconButton(
          tooltip: translate('Undo'),
          onPressed:
              _busy || (_strokes.isEmpty && _cropRect == null) ? null : _undo,
          icon: const Icon(Icons.undo),
        ),
        IconButton(
          tooltip: translate('Reset'),
          onPressed: _busy ? null : _reset,
          icon: const Icon(Icons.restart_alt),
        ),
        const SizedBox(width: 6),
        ..._penColors.map((color) => _ColorSwatch(
              color: color,
              selected: _penColor == color,
              onTap: _busy ? null : () => setState(() => _penColor = color),
            )),
        SizedBox(
          width: 150,
          child: Slider(
            min: 2,
            max: 14,
            divisions: 6,
            value: _penWidth,
            onChanged:
                _busy ? null : (value) => setState(() => _penWidth = value),
          ),
        ),
        if (_busy)
          const SizedBox(
            width: 20,
            height: 20,
            child: CircularProgressIndicator(strokeWidth: 2),
          ),
      ],
    );
  }

  Widget _buildCanvas() {
    final image = _image;
    if (image == null) {
      return const Center(child: CircularProgressIndicator());
    }
    return DecoratedBox(
      decoration: BoxDecoration(
        color: Colors.black87,
        border: Border.all(color: MyTheme.border),
      ),
      child: LayoutBuilder(
        builder: (context, constraints) {
          final size = Size(constraints.maxWidth, constraints.maxHeight);
          return MouseRegion(
            cursor: _tool == _ScreenshotTool.pen
                ? SystemMouseCursors.precise
                : SystemMouseCursors.click,
            child: GestureDetector(
              behavior: HitTestBehavior.opaque,
              onPanStart:
                  _busy ? null : (details) => _onPanStart(details, size),
              onPanUpdate:
                  _busy ? null : (details) => _onPanUpdate(details, size),
              onPanEnd: _busy ? null : _onPanEnd,
              child: CustomPaint(
                painter: _ScreenshotEditorPainter(
                  image: image,
                  strokes: _strokes,
                  cropRect: _cropRect,
                ),
                child: const SizedBox.expand(),
              ),
            ),
          );
        },
      ),
    );
  }

  Widget _buildActions() {
    return Row(
      mainAxisAlignment: MainAxisAlignment.end,
      children: [
        dialogButton(
          'Close',
          icon: const Icon(Icons.close),
          isOutline: true,
          onPressed: _busy ? null : widget.onClose,
        ),
        const SizedBox(width: 8),
        dialogButton(
          'Copy to clipboard',
          icon: const Icon(Icons.copy),
          onPressed: _busy ? null : _copy,
        ),
        const SizedBox(width: 8),
        dialogButton(
          'Save as',
          icon: const Icon(Icons.save_alt),
          onPressed: _busy ? null : _save,
        ),
      ],
    );
  }
}

class _ColorSwatch extends StatelessWidget {
  const _ColorSwatch({
    required this.color,
    required this.selected,
    required this.onTap,
  });

  final Color color;
  final bool selected;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    return Tooltip(
      message: translate('Pen color'),
      child: InkWell(
        borderRadius: BorderRadius.circular(14),
        onTap: onTap,
        child: Container(
          width: 26,
          height: 26,
          decoration: BoxDecoration(
            color: color,
            shape: BoxShape.circle,
            border: Border.all(
              color: selected ? MyTheme.accent : MyTheme.border,
              width: selected ? 3 : 1,
            ),
          ),
        ),
      ),
    );
  }
}

class _ScreenshotEditorPainter extends CustomPainter {
  _ScreenshotEditorPainter({
    required this.image,
    required this.strokes,
    required this.cropRect,
  });

  final ui.Image image;
  final List<_EditorStroke> strokes;
  final Rect? cropRect;

  @override
  void paint(Canvas canvas, Size size) {
    final imageRect = _imageRect(size, image);
    final paint = Paint()..filterQuality = FilterQuality.medium;
    canvas.drawImageRect(
      image,
      Rect.fromLTWH(0, 0, image.width.toDouble(), image.height.toDouble()),
      imageRect,
      paint,
    );

    canvas.save();
    canvas.clipRect(imageRect);
    canvas.translate(imageRect.left, imageRect.top);
    canvas.scale(
        imageRect.width / image.width, imageRect.height / image.height);
    _paintStrokes(canvas, strokes);
    canvas.restore();

    final crop = cropRect == null ? null : _cropToCanvas(cropRect!, imageRect);
    if (crop != null && crop.width > 1 && crop.height > 1) {
      final overlay = Path()
        ..fillType = PathFillType.evenOdd
        ..addRect(imageRect)
        ..addRect(crop);
      canvas.drawPath(
        overlay,
        Paint()..color = Colors.black.withValues(alpha: 0.45),
      );
      canvas.drawRect(
        crop,
        Paint()
          ..color = MyTheme.accent
          ..style = PaintingStyle.stroke
          ..strokeWidth = 2,
      );
      canvas.drawRect(
        crop.deflate(1),
        Paint()
          ..color = Colors.white.withValues(alpha: 0.9)
          ..style = PaintingStyle.stroke
          ..strokeWidth = 1,
      );
    }
  }

  Rect _cropToCanvas(Rect crop, Rect imageRect) {
    final sx = imageRect.width / image.width;
    final sy = imageRect.height / image.height;
    return Rect.fromLTRB(
      imageRect.left + crop.left * sx,
      imageRect.top + crop.top * sy,
      imageRect.left + crop.right * sx,
      imageRect.top + crop.bottom * sy,
    );
  }

  void _paintStrokes(Canvas canvas, List<_EditorStroke> strokes) {
    for (final stroke in strokes) {
      if (stroke.points.isEmpty) continue;
      final paint = Paint()
        ..color = stroke.color
        ..strokeWidth = stroke.width
        ..style = PaintingStyle.stroke
        ..strokeCap = StrokeCap.round
        ..strokeJoin = StrokeJoin.round;
      if (stroke.points.length == 1) {
        canvas.drawCircle(stroke.points.first, stroke.width / 2, paint);
        continue;
      }
      final path = Path()
        ..moveTo(stroke.points.first.dx, stroke.points.first.dy);
      for (final point in stroke.points.skip(1)) {
        path.lineTo(point.dx, point.dy);
      }
      canvas.drawPath(path, paint);
    }
  }

  @override
  bool shouldRepaint(covariant _ScreenshotEditorPainter oldDelegate) {
    return true;
  }
}

class _EditorStroke {
  _EditorStroke({
    required this.color,
    required this.width,
    required this.points,
  });

  final Color color;
  final double width;
  final List<Offset> points;
}

Rect _imageRect(Size size, ui.Image image) {
  final imageWidth = image.width.toDouble();
  final imageHeight = image.height.toDouble();
  final scale = min(size.width / imageWidth, size.height / imageHeight);
  final width = imageWidth * scale;
  final height = imageHeight * scale;
  return Rect.fromLTWH(
    (size.width - width) / 2,
    (size.height - height) / 2,
    width,
    height,
  );
}
