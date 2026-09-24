import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_hbb/desktop/models/remote_pane_geometry.dart';

void main() {
  test('letterbox bars never forward clicks to the remote desktop', () {
    final geometry = RemotePaneGeometry(
        viewport: const Rect.fromLTWH(0, 0, 400, 400),
        display: const Rect.fromLTWH(0, 0, 1920, 1080));
    expect(geometry.imageRect, const Rect.fromLTWH(0, 87.5, 400, 225));
    expect(geometry.toRemote(const Offset(200, 20)), isNull);
    expect(geometry.toRemote(const Offset(200, 200)), const Offset(960, 540));
  });

  test('right/bottom panes and negative remote origins map independently', () {
    final geometry = RemotePaneGeometry(
        viewport: const Rect.fromLTWH(604, 404, 600, 400),
        display: const Rect.fromLTWH(-1920, -1080, 1920, 1080));
    expect(
        geometry.toRemote(geometry.imageRect.center), const Offset(-960, -540));
    expect(geometry.toRemote(geometry.imageRect.topLeft),
        const Offset(-1920, -1080));
    final nearBottomRight =
        geometry.toRemote(geometry.imageRect.bottomRight, clamp: true)!;
    expect(nearBottomRight, const Offset(-1, -1));
  });

  test('button releases outside the pane clamp to the original monitor', () {
    final geometry = RemotePaneGeometry(
        viewport: const Rect.fromLTWH(0, 0, 800, 600),
        display: const Rect.fromLTWH(1920, 0, 1600, 1200));
    expect(geometry.toRemote(const Offset(1200, 100)), isNull);
    expect(geometry.toRemote(const Offset(1200, 100), clamp: true),
        const Offset(3519, 200));
  });

  test('DPI changes alter logical viewport size, not remote coordinates', () {
    for (final dpi in [1.0, 1.25, 1.5, 2.0]) {
      final geometry = RemotePaneGeometry(
          viewport: Rect.fromLTWH(0, 0, 1200 / dpi, 800 / dpi),
          display: const Rect.fromLTWH(0, 0, 1920, 1080));
      expect(
          geometry.toRemote(geometry.imageRect.center), const Offset(960, 540));
    }
  });

  test('zoom and pan retain an invertible per-pane coordinate transform', () {
    final geometry = RemotePaneGeometry(
        viewport: const Rect.fromLTWH(0, 0, 800, 600),
        display: const Rect.fromLTWH(-100, 50, 1600, 1200),
        zoom: 2,
        pan: const Offset(100, -50));
    const remote = Offset(700, 650);
    expect(geometry.toRemote(geometry.toLocal(remote)), remote);
    final clamped = RemotePaneGeometry(
        viewport: geometry.viewport,
        display: geometry.display,
        zoom: 2,
        pan: const Offset(99999, 99999));
    expect(clamped.imageRect.left, 0);
    expect(clamped.imageRect.top, 0);
  });

  test('hidden or unavailable displays cannot emit coordinates', () {
    final geometry = RemotePaneGeometry(
        viewport: Rect.zero, display: const Rect.fromLTWH(0, 0, 1920, 1080));
    expect(geometry.toRemote(Offset.zero, clamp: true), isNull);
  });
}
