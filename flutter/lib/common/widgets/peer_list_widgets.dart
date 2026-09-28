import 'package:flutter/material.dart';

/// A tree category whose rows are built only near the scroll viewport.
class PeerListSection<T> extends StatelessWidget {
  const PeerListSection({
    super.key,
    required this.header,
    required this.expanded,
    required this.items,
    required this.itemBuilder,
    this.placeholder,
  });

  final Widget header;
  final bool expanded;
  final List<T> items;
  final Widget Function(BuildContext, T) itemBuilder;
  final Widget? placeholder;

  @override
  Widget build(BuildContext context) {
    return SliverMainAxisGroup(slivers: [
      SliverToBoxAdapter(child: header),
      if (expanded)
        if (placeholder != null)
          SliverToBoxAdapter(child: placeholder)
        else
          SliverList(
            delegate: SliverChildBuilderDelegate(
              (context, index) => itemBuilder(context, items[index]),
              childCount: items.length,
            ),
          ),
    ]);
  }
}

/// Keeps hover feedback local to one row, without rebuilding the peer tree.
class PeerListRow extends StatefulWidget {
  const PeerListRow({
    super.key,
    required this.child,
    required this.onTap,
    required this.onDoubleTap,
    required this.onSecondaryTapDown,
    this.selected = false,
    this.currentDevice = false,
  });

  final Widget child;
  final VoidCallback onTap;
  final VoidCallback onDoubleTap;
  final GestureTapDownCallback onSecondaryTapDown;
  final bool selected;
  final bool currentDevice;

  @override
  State<PeerListRow> createState() => _PeerListRowState();
}

class _PeerListRowState extends State<PeerListRow> {
  bool _hovered = false;

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final background = widget.selected
        ? (isDark ? Colors.blue.shade900 : Colors.blue.shade50)
        : widget.currentDevice
            ? (isDark ? const Color(0xFF2D4A3D) : Colors.green.shade50)
            : (isDark ? Colors.grey.shade900 : Colors.white);
    final accent = isDark ? Colors.lightBlue.shade300 : Colors.blue.shade600;

    return Semantics(
      selected: widget.selected,
      child: Material(
        animationDuration: Duration.zero,
        color: _hovered
            ? Color.alphaBlend(
                accent.withValues(alpha: isDark ? 0.2 : 0.1), background)
            : background,
        child: InkWell(
          onHover: (hovered) {
            if (_hovered != hovered) setState(() => _hovered = hovered);
          },
          hoverColor: Colors.transparent,
          onTap: widget.onTap,
          onDoubleTap: widget.onDoubleTap,
          onSecondaryTapDown: widget.onSecondaryTapDown,
          child: Container(
            // Reserve the accent border even when idle to avoid shifting text.
            padding:
                const EdgeInsets.only(left: 27, right: 8, top: 5, bottom: 5),
            decoration: BoxDecoration(
              border: Border(
                left: BorderSide(
                    color: _hovered ? accent : Colors.transparent, width: 3),
                bottom: BorderSide(
                    color: isDark ? Colors.grey.shade800 : Colors.grey.shade200,
                    width: 0.5),
              ),
            ),
            child: widget.child,
          ),
        ),
      ),
    );
  }
}
