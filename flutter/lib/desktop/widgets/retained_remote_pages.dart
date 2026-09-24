import 'package:flutter/widgets.dart';

/// Stable connection owners: switching presentation never disposes a page.
/// Only removing its connection key from [pages] releases that page.
class RetainedRemotePages extends StatelessWidget {
  const RetainedRemotePages(
      {super.key,
      required this.pages,
      this.visibleKey,
      this.visibleRects = const {}});

  final Map<String, Widget> pages;
  final String? visibleKey;
  final Map<String, Rect> visibleRects;

  @override
  Widget build(BuildContext context) => Stack(
        fit: StackFit.expand,
        children: pages.entries.map((entry) {
          final rect = visibleRects[entry.key];
          final visible = entry.key == visibleKey || rect != null;
          return Positioned(
            key: ValueKey(entry.key),
            left: rect?.left ?? 0,
            top: rect?.top ?? 0,
            right: rect == null ? 0 : null,
            bottom: rect == null ? 0 : null,
            width: rect?.width,
            height: rect?.height,
            child: Offstage(
              offstage: !visible,
              child: ExcludeFocus(
                excluding: !visible,
                child: TickerMode(
                    enabled: visible, child: ClipRect(child: entry.value)),
              ),
            ),
          );
        }).toList(),
      );
}
