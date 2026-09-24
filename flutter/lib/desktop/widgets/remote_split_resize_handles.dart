import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';

import '../models/remote_layout_model.dart';

/// Hit-tests only the divider strips. All other pointer events reach the panes.
class RemoteSplitResizeHandles extends StatelessWidget {
  const RemoteSplitResizeHandles(
      {super.key,
      required this.layout,
      required this.onResizeStart,
      required this.onResizeEnd});

  final RemoteLayoutModel layout;
  final VoidCallback onResizeStart;
  final VoidCallback onResizeEnd;

  @override
  Widget build(BuildContext context) => LayoutBuilder(
        builder: (context, constraints) => ListenableBuilder(
          listenable: layout,
          builder: (context, _) {
            if (!layout.isSplit) return const SizedBox.shrink();
            final size = constraints.biggest;
            final rects = layout.paneRects(size);
            final gapX =
                layout.hasColumns ? rects[1].left - rects[0].right : 0.0;
            final gapY = layout.hasRows
                ? rects[layout.mode.columns].top - rects[0].bottom
                : 0.0;
            final columns = List.generate(
                layout.mode.columns - 1, (i) => rects[i].right + gapX / 2);
            final rows = List.generate(layout.mode.rows - 1,
                (i) => rects[i * layout.mode.columns].bottom + gapY / 2);

            Widget handle(Rect rect, _ResizeAxis axis,
                {int column = 0, int row = 0}) {
              final suffix = column == 0 && row == 0 ? '' : '-$column-$row';
              final key = 'split-resize-${axis.name}$suffix';
              return Positioned.fromRect(
                key: ValueKey('position-$key'),
                rect: rect,
                child: _ResizeHandle(
                  key: ValueKey(key),
                  axis: axis,
                  divider: Offset(columns.isEmpty ? 0 : columns[column],
                      rows.isEmpty ? 0 : rows[row]),
                  onStart: onResizeStart,
                  onEnd: onResizeEnd,
                  onMove: (position) => layout.resize(size,
                      columnDivider: column,
                      rowDivider: row,
                      dividerX: axis != _ResizeAxis.rows ? position.dx : null,
                      dividerY:
                          axis != _ResizeAxis.columns ? position.dy : null),
                  onReset: () => layout.resetSizes(
                      columns: axis != _ResizeAxis.rows,
                      rows: axis != _ResizeAxis.columns),
                ),
              );
            }

            return Stack(children: [
              for (var c = 0; c < columns.length; c++)
                handle(
                    Rect.fromLTWH(columns[c] - gapX / 2, 0, gapX, size.height),
                    _ResizeAxis.columns,
                    column: c),
              for (var r = 0; r < rows.length; r++)
                handle(Rect.fromLTWH(0, rows[r] - gapY / 2, size.width, gapY),
                    _ResizeAxis.rows,
                    row: r),
              for (var c = 0; c < columns.length; c++)
                for (var r = 0; r < rows.length; r++)
                  handle(
                      Rect.fromCenter(
                          center: Offset(columns[c], rows[r]),
                          width: 16,
                          height: 16),
                      _ResizeAxis.both,
                      column: c,
                      row: r),
            ]);
          },
        ),
      );
}

enum _ResizeAxis { columns, rows, both }

class _ResizeHandle extends StatefulWidget {
  const _ResizeHandle(
      {super.key,
      required this.axis,
      required this.divider,
      required this.onStart,
      required this.onEnd,
      required this.onMove,
      required this.onReset});

  final _ResizeAxis axis;
  final Offset divider;
  final VoidCallback onStart;
  final VoidCallback onEnd;
  final ValueChanged<Offset> onMove;
  final VoidCallback onReset;

  @override
  State<_ResizeHandle> createState() => _ResizeHandleState();
}

class _ResizeHandleState extends State<_ResizeHandle> {
  bool _hovered = false;
  int? _pointer;
  Offset _startPosition = Offset.zero;
  Offset _startDivider = Offset.zero;

  void _start(PointerDownEvent event) {
    if (_pointer != null || event.buttons != kPrimaryMouseButton) return;
    _startPosition = event.position;
    _startDivider = widget.divider;
    setState(() => _pointer = event.pointer);
    // Release remote keys/buttons before dragging can cross another pane.
    widget.onStart();
  }

  void _end(PointerEvent event) {
    if (event.pointer != _pointer) return;
    setState(() => _pointer = null);
    widget.onEnd();
  }

  @override
  void dispose() {
    if (_pointer != null) widget.onEnd();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final columns = widget.axis == _ResizeAxis.columns;
    final both = widget.axis == _ResizeAxis.both;
    final color = _hovered || _pointer != null
        ? Theme.of(context).colorScheme.primary
        : Theme.of(context).dividerColor;
    return MouseRegion(
      cursor: both
          ? SystemMouseCursors.move
          : columns
              ? SystemMouseCursors.resizeLeftRight
              : SystemMouseCursors.resizeUpDown,
      onEnter: (_) => setState(() => _hovered = true),
      onExit: (_) => setState(() => _hovered = false),
      child: Tooltip(
        message:
            '${both ? '가로·세로' : columns ? '좌우' : '상하'} 크기 조절 · 더블클릭으로 균등 분할',
        child: GestureDetector(
          onDoubleTap: widget.onReset,
          child: Listener(
            behavior: HitTestBehavior.opaque,
            onPointerDown: _start,
            onPointerMove: (event) {
              if (event.pointer == _pointer) {
                // Global deltas stay stable while this handle itself moves.
                widget.onMove(_startDivider + event.position - _startPosition);
              }
            },
            onPointerUp: _end,
            onPointerCancel: _end,
            child: ColoredBox(
              color: Theme.of(context).colorScheme.surface,
              child: Center(
                child: Container(
                  width: both
                      ? 12
                      : columns
                          ? 3
                          : 28,
                  height: both
                      ? 12
                      : columns
                          ? 28
                          : 3,
                  decoration: BoxDecoration(
                      color: color, borderRadius: BorderRadius.circular(3)),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}
