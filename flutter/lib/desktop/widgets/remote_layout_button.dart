import 'package:flutter/material.dart';
import '../models/remote_layout_model.dart';

/// The same compact controls are shown in the title bar, or as a fallback when
/// fullscreen hides it. The workspace itself needs no extra toolbar row.
class RemoteLayoutControls extends StatelessWidget {
  const RemoteLayoutControls(
      {super.key,
      required this.mode,
      required this.onSelected,
      required this.onArrangePeers,
      required this.onArrangeMonitors,
      this.onRestore,
      this.onOpened,
      this.onClosed});

  final RemoteLayoutMode mode;
  final ValueChanged<RemoteLayoutMode> onSelected;
  final VoidCallback onArrangePeers;
  final VoidCallback onArrangeMonitors;
  final VoidCallback? onRestore;
  final VoidCallback? onOpened;
  final VoidCallback? onClosed;

  Widget _action(String tooltip, IconData icon, VoidCallback onPressed) =>
      SizedBox(
          width: 30,
          height: 30,
          child: IconButton(
              tooltip: tooltip,
              padding: EdgeInsets.zero,
              iconSize: 18,
              onPressed: () {
                onOpened?.call();
                onPressed();
                onClosed?.call();
              },
              icon: Icon(icon)));

  @override
  Widget build(BuildContext context) =>
      Row(mainAxisSize: MainAxisSize.min, children: [
        if (mode != RemoteLayoutMode.single) ...[
          _action('연결된 PC 자동 배치', Icons.computer, onArrangePeers),
          _action('현재 PC의 모니터 자동 배치', Icons.monitor, onArrangeMonitors),
        ] else if (onRestore != null)
          _action('분할로 복귀', Icons.restore, onRestore!),
        SizedBox(
            width: 30,
            height: 30,
            child: RemoteLayoutButton(
                mode: mode,
                onSelected: onSelected,
                onOpened: onOpened,
                onClosed: onClosed)),
      ]);
}

class RemoteLayoutButton extends StatelessWidget {
  const RemoteLayoutButton(
      {super.key,
      required this.mode,
      required this.onSelected,
      this.onOpened,
      this.onClosed});

  final RemoteLayoutMode mode;
  final ValueChanged<RemoteLayoutMode> onSelected;
  final VoidCallback? onOpened;
  final VoidCallback? onClosed;

  static IconData iconFor(RemoteLayoutMode mode) => switch (mode) {
        RemoteLayoutMode.single => Icons.crop_square,
        RemoteLayoutMode.sideBySide => Icons.vertical_split_outlined,
        RemoteLayoutMode.stacked => Icons.horizontal_split_outlined,
        RemoteLayoutMode.quad => Icons.grid_view_outlined,
        RemoteLayoutMode.sixWide => Icons.view_module_outlined,
        RemoteLayoutMode.sixTall => Icons.view_comfy_outlined,
      };

  @override
  Widget build(BuildContext context) => PopupMenuButton<RemoteLayoutMode>(
        tooltip: '화면 분할',
        padding: EdgeInsets.zero,
        iconSize: 18,
        constraints: const BoxConstraints(minWidth: 240),
        icon: Icon(iconFor(mode),
            color: mode == RemoteLayoutMode.single
                ? null
                : Theme.of(context).colorScheme.primary),
        onOpened: onOpened,
        onCanceled: onClosed,
        onSelected: (value) {
          onSelected(value);
          onClosed?.call();
        },
        itemBuilder: (_) => RemoteLayoutMode.values
            .map((value) => PopupMenuItem(
                  value: value,
                  child: Row(children: [
                    Icon(iconFor(value), size: 18),
                    const SizedBox(width: 10),
                    Expanded(child: Text(value.label)),
                    if (value == mode) const Icon(Icons.check, size: 18),
                  ]),
                ))
            .toList(),
      );
}
