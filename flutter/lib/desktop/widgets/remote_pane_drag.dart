import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';

import '../models/remote_window_drag.dart';

class RemoteWindowDragScope extends InheritedWidget {
  const RemoteWindowDragScope(
      {super.key, required this.controller, required super.child});
  final RemoteWindowDragController? controller;

  static RemoteWindowDragController? of(BuildContext context) => context
      .dependOnInheritedWidgetOfExactType<RemoteWindowDragScope>()
      ?.controller;

  @override
  bool updateShouldNotify(RemoteWindowDragScope oldWidget) =>
      controller != oldWidget.controller;
}

@immutable
class RemotePaneDragData {
  const RemotePaneDragData(this.peerId, {this.display});
  final String peerId;
  // Tabs choose the active display at drop time; pane headers carry an exact one.
  final int? display;
}

class RemotePaneDragSource extends StatelessWidget {
  const RemotePaneDragSource(
      {super.key,
      required this.peerId,
      this.display,
      this.affinity,
      required this.enabled,
      required this.onStart,
      required this.onEnd,
      required this.child});

  final String peerId;
  final int? display;
  final Axis? affinity;
  final bool enabled;
  final VoidCallback onStart;
  final VoidCallback onEnd;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    final windowDrag = RemoteWindowDragScope.of(context);
    Future<void> finish(bool accepted) async {
      await windowDrag?.finish(acceptedLocally: accepted);
      onEnd();
    }

    return Listener(
      onPointerCancel: (_) => windowDrag?.cancel(),
      child: Draggable<RemotePaneDragData>(
        data: RemotePaneDragData(peerId, display: display),
        affinity: affinity,
        maxSimultaneousDrags: enabled ? 1 : 0,
        allowedButtonsFilter: (buttons) => buttons == kPrimaryMouseButton,
        onDragStarted: () {
          onStart();
          windowDrag?.start(peerId, display);
        },
        // Unlike onDragEnd, these run even if the source was unmounted.
        onDragCompleted: () => finish(true),
        onDraggableCanceled: (_, __) => finish(false),
        feedback: Material(
          elevation: 6,
          borderRadius: BorderRadius.circular(6),
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
            child: Row(mainAxisSize: MainAxisSize.min, children: [
              const Icon(Icons.desktop_windows_outlined, size: 18),
              const SizedBox(width: 8),
              Text(
                  '$peerId${display == null ? '' : ' · 모니터 ${display! + 1}'} · 빈 화면에 놓기'),
            ]),
          ),
        ),
        child: child,
      ),
    );
  }
}

class RemotePaneDropTarget extends StatelessWidget {
  const RemotePaneDropTarget(
      {super.key,
      required this.canAccept,
      required this.onAccept,
      this.highlighted = false,
      required this.child});

  final bool Function(RemotePaneDragData data) canAccept;
  final ValueChanged<RemotePaneDragData> onAccept;
  final Widget child;
  final bool highlighted;

  @override
  Widget build(BuildContext context) => DragTarget<RemotePaneDragData>(
        onWillAcceptWithDetails: (details) => canAccept(details.data),
        onAcceptWithDetails: (details) {
          if (canAccept(details.data)) onAccept(details.data);
        },
        builder: (context, candidates, _) => Stack(
          fit: StackFit.expand,
          children: [
            child,
            if (highlighted ||
                candidates.any((data) => data != null && canAccept(data)))
              IgnorePointer(
                child: Container(
                  decoration: BoxDecoration(
                    color: Color.alphaBlend(
                        Theme.of(context)
                            .colorScheme
                            .primary
                            .withValues(alpha: 0.12),
                        Theme.of(context).colorScheme.surface),
                    border: Border.all(
                        color: Theme.of(context).colorScheme.primary, width: 3),
                  ),
                  child: const Center(
                    child: Text('여기에 화면 놓기',
                        style: TextStyle(fontWeight: FontWeight.bold)),
                  ),
                ),
              ),
          ],
        ),
      );
}
