import 'package:flutter/material.dart';

/// Paints one control in the root overlay while keeping its layout position.
/// The overlay entry only hit-tests the control itself, so surrounding content
/// continues to receive pointer events normally.
class RootOverlayControl extends StatefulWidget {
  const RootOverlayControl({
    super.key,
    required this.size,
    required this.child,
  });

  final Size size;
  final Widget child;

  @override
  State<RootOverlayControl> createState() => _RootOverlayControlState();
}

class _RootOverlayControlState extends State<RootOverlayControl>
    with WidgetsBindingObserver {
  final GlobalKey _targetKey = GlobalKey();
  OverlayEntry? _entry;
  Rect? _targetRect;
  bool _syncScheduled = false;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _scheduleSync();
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _scheduleSync();
  }

  @override
  void didChangeMetrics() {
    _scheduleSync();
  }

  void _scheduleSync() {
    if (_syncScheduled) return;
    _syncScheduled = true;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _syncScheduled = false;
      _syncEntry();
    });
  }

  void _syncEntry() {
    if (!mounted) return;

    final overlay = Overlay.maybeOf(context, rootOverlay: true);
    if (overlay == null) return;

    final targetContext = _targetKey.currentContext;
    final targetBox = targetContext?.findRenderObject();
    final overlayBox = overlay.context.findRenderObject();
    if (targetBox is! RenderBox ||
        overlayBox is! RenderBox ||
        !targetBox.attached ||
        !overlayBox.attached ||
        !targetBox.hasSize) {
      return;
    }

    final topLeft = targetBox.localToGlobal(Offset.zero, ancestor: overlayBox);
    if (!topLeft.dx.isFinite || !topLeft.dy.isFinite) return;
    final nextRect = topLeft & targetBox.size;
    final positionChanged = _targetRect != nextRect;
    _targetRect = nextRect;

    if (_entry == null) {
      _entry = OverlayEntry(builder: (_) {
        final rect = _targetRect;
        if (rect == null) return const SizedBox.shrink();
        return Positioned(
          left: rect.left,
          top: rect.top,
          width: rect.width,
          height: rect.height,
          child: Material(
            type: MaterialType.transparency,
            child: widget.child,
          ),
        );
      });
      overlay.insert(_entry!);
    } else if (positionChanged) {
      _entry!.markNeedsBuild();
    }
  }

  @override
  Widget build(BuildContext context) {
    _scheduleSync();
    return SizedBox.fromSize(
      key: _targetKey,
      size: widget.size,
    );
  }

  @override
  void didUpdateWidget(covariant RootOverlayControl oldWidget) {
    super.didUpdateWidget(oldWidget);
    _entry?.markNeedsBuild();
    _scheduleSync();
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _entry?.remove();
    _entry = null;
    super.dispose();
  }
}
