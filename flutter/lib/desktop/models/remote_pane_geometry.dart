import 'dart:math' as math;
import 'package:flutter/widgets.dart';

/// All local coordinates are logical pixels; remote coordinates include the
/// display's desktop origin (which can be negative).
@immutable
class RemotePaneGeometry {
  RemotePaneGeometry(
      {required this.viewport,
      required this.display,
      double zoom = 1,
      Offset pan = Offset.zero}) {
    scale = viewport.isEmpty || display.isEmpty
        ? 0
        : math.min(viewport.width / display.width,
                viewport.height / display.height) *
            zoom;
    final imageSize = display.size * scale;
    final overflowX = math.max(0.0, (imageSize.width - viewport.width) / 2);
    final overflowY = math.max(0.0, (imageSize.height - viewport.height) / 2);
    imageRect = Rect.fromCenter(
        center: viewport.center +
            Offset(pan.dx.clamp(-overflowX, overflowX),
                pan.dy.clamp(-overflowY, overflowY)),
        width: imageSize.width,
        height: imageSize.height);
  }

  final Rect viewport;
  final Rect display;
  late final double scale;
  late final Rect imageRect;

  Offset? toRemote(Offset point, {bool clamp = false}) {
    if (scale <= 0 || !scale.isFinite) return null;
    if (!clamp && (!viewport.contains(point) || !imageRect.contains(point))) {
      return null;
    }
    final local = (point - imageRect.topLeft) / scale;
    return display.topLeft +
        Offset(local.dx.clamp(0.0, math.max(0.0, display.width - 1)),
            local.dy.clamp(0.0, math.max(0.0, display.height - 1)));
  }

  Offset toLocal(Offset remote) =>
      imageRect.topLeft + (remote - display.topLeft) * scale;
}
