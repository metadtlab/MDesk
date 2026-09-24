import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_hbb/desktop/models/remote_layout_model.dart';
import 'package:flutter_hbb/desktop/widgets/remote_split_pane.dart';
import 'package:flutter_hbb/desktop/widgets/remote_workspace.dart';
import 'package:flutter_hbb/desktop/widgets/tabbar_widget.dart';

void main() {
  for (final mode in [
    RemoteLayoutMode.quad,
    RemoteLayoutMode.sixWide,
    RemoteLayoutMode.sixTall
  ]) {
    for (final full in [false, true]) {
      testWidgets(
          '${mode.name}: new password UI opens in ${full ? 'first occupied' : 'selected empty'} pane',
          (tester) async {
        final layout = RemoteLayoutModel()..setMode(mode);
        final tabs = DesktopTabController(tabType: DesktopTabType.remoteScreen);
        final existing = full
            ? ['A', 'B', 'C', 'D', 'E', 'F'].take(mode.capacity).toList()
            : ['A'];
        final created = <String, int>{};
        final disposed = <String, int>{};
        for (final peer in existing) {
          tabs.state.value.tabs.add(TabInfo(
              key: peer,
              label: peer,
              page: _ConnectionOwner(
                  peer: peer, created: created, disposed: disposed)));
        }
        layout.arrange(existing.map((peer) => RemotePaneTarget(peer, 0)));
        layout.activate(mode.capacity - 1);
        if (full) tabs.state.value.selected = mode.capacity - 1;
        final workspace = GlobalKey<RemoteWorkspaceState>();
        await tester.pumpWidget(MaterialApp(
            home: RemoteWorkspace(key: workspace, tabs: tabs, layout: layout)));
        await tester.pumpAndSettle();
        final newOwner = GlobalKey<_ConnectionOwnerState>();

        // Same ordering as kWindowEventNewRemoteDesktop: reserve, then add/select.
        workspace.currentState!.prepareForNewConnection('NEW');
        tabs.state.update((state) {
          state!.tabs.add(TabInfo(
              key: 'NEW',
              label: 'NEW',
              page: _ConnectionOwner(
                  key: newOwner,
                  peer: 'NEW',
                  passwordRequired: true,
                  created: created,
                  disposed: disposed)));
          state.selected = state.tabs.length - 1;
        });
        // Builds that invoke the selection callback immediately must not move it.
        workspace.currentState!.onTabSelected('NEW');
        await tester.pumpAndSettle();
        final slot = full ? 0 : mode.capacity - 1;
        expect(layout.activeSlot, slot);
        expect(layout.slots[slot], const RemotePaneTarget('NEW', 0));
        final pane = tester.getRect(find.byType(RemoteSplitPane).at(slot));
        final ownerRect = tester.getRect(find.byKey(newOwner));
        expect(
            ownerRect,
            Rect.fromLTWH(pane.left + 2, pane.top + 34, pane.width - 4,
                pane.height - 36));
        final password = find.byKey(const ValueKey('NEW-password'));
        final editor = tester.widget<EditableText>(
            find.descendant(of: password, matching: find.byType(EditableText)));
        expect(editor.focusNode.hasFocus, isTrue);
        await tester.enterText(password, 'test-only-password');
        expect(editor.controller.text, 'test-only-password');
        expect(disposed, isEmpty);
        for (final peer in [...existing, 'NEW']) {
          expect(created[peer], 1);
          expect(tabs.state.value.tabs.any((tab) => tab.key == peer), isTrue);
        }
        // Peer-info/frame updates must not reserve another slot or remount login.
        final stateBefore = newOwner.currentState;
        workspace.currentState!.sessionsChanged();
        await tester.pumpAndSettle();
        expect(newOwner.currentState, same(stateBefore));
        expect(layout.activeSlot, slot);
        expect(editor.controller.text, 'test-only-password');
        expect(tester.takeException(), isNull);
        await tester.pumpWidget(const SizedBox.shrink());
        layout.dispose();
        tabs.state.value.pageController.dispose();
        tabs.state.value.scrollController.dispose();
      });
    }
  }
}

class _ConnectionOwner extends StatefulWidget {
  const _ConnectionOwner(
      {super.key,
      required this.peer,
      required this.created,
      required this.disposed,
      this.passwordRequired = false});
  final String peer;
  final bool passwordRequired;
  final Map<String, int> created;
  final Map<String, int> disposed;
  @override
  State<_ConnectionOwner> createState() => _ConnectionOwnerState();
}

class _ConnectionOwnerState extends State<_ConnectionOwner> {
  @override
  void initState() {
    super.initState();
    widget.created.update(widget.peer, (value) => value + 1, ifAbsent: () => 1);
  }

  @override
  void dispose() {
    widget.disposed
        .update(widget.peer, (value) => value + 1, ifAbsent: () => 1);
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => Material(
      child: Center(
          child: widget.passwordRequired
              ? Padding(
                  padding: const EdgeInsets.all(16),
                  child: TextField(
                      key: ValueKey('${widget.peer}-password'),
                      autofocus: true,
                      obscureText: true,
                      decoration: const InputDecoration(labelText: '비밀번호')))
              : Text(widget.peer)));
}
