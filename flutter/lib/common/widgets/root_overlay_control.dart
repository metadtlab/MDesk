import 'package:flutter/material.dart';

/// Keeps a control above page content, but below subsequent routes and dialogs.
/// The compositor anchor also hides the control when its page is not painted.
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

class _RootOverlayControlState extends State<RootOverlayControl> {
  final LayerLink _link = LayerLink();
  final OverlayPortalController _controller = OverlayPortalController();

  @override
  void initState() {
    super.initState();
    _controller.show();
  }

  @override
  Widget build(BuildContext context) {
    // CI uses Flutter 3.24, before the overlayLocation constructor argument.
    // ignore: deprecated_member_use
    return OverlayPortal.targetsRootOverlay(
      controller: _controller,
      overlayChildBuilder: (_) => Positioned(
        left: 0,
        top: 0,
        width: widget.size.width,
        height: widget.size.height,
        child: CompositedTransformFollower(
          link: _link,
          showWhenUnlinked: false,
          child: Material(
            type: MaterialType.transparency,
            child: widget.child,
          ),
        ),
      ),
      child: CompositedTransformTarget(
        link: _link,
        child: SizedBox.fromSize(size: widget.size),
      ),
    );
  }
}
