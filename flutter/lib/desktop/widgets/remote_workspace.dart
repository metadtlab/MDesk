import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:get/get.dart';

import '../../common.dart';
import '../../consts.dart';
import '../../models/model.dart';
import '../../models/platform_model.dart';
import '../../models/state_model.dart';
import '../models/remote_layout_model.dart';
import '../pages/remote_page.dart';
import 'remote_layout_button.dart';
import 'remote_pane_drag.dart';
import 'remote_split_pane.dart';
import 'remote_split_resize_handles.dart';
import 'retained_remote_pages.dart';
import 'tabbar_widget.dart';

/// Uses each existing RemotePage as the connection owner. Split panes borrow
/// its frames, never register a second FFI or close its session.
class RemoteWorkspace extends StatefulWidget {
  const RemoteWorkspace(
      {super.key,
      required this.tabs,
      required this.layout,
      this.peerLabelGetter});

  final DesktopTabController tabs;
  final RemoteLayoutModel layout;
  final String Function(String peerId)? peerLabelGetter;

  @override
  State<RemoteWorkspace> createState() => RemoteWorkspaceState();
}

class RemoteWorkspaceState extends State<RemoteWorkspace> {
  final Map<String, _DisplayLease> _leases = {};
  final Map<String, FFI> _listened = {};
  final Map<String, int> _displayCounts = {};
  final Set<RemotePaneTarget> _missingTargets = {};
  final Map<int, GlobalKey<RemoteSplitPaneState>> _paneKeys = {};
  bool _scheduled = false;
  bool _selectingTab = false;
  int _revision = 0;
  final Map<String, String> _peerLabels = {};
  int? _windowDropSlot;

  RemoteLayoutModel get layout => widget.layout;
  List<TabInfo> get tabs => widget.tabs.state.value.tabs;
  String? get selectedPeer {
    final state = widget.tabs.state.value;
    return state.selected >= 0 && state.selected < state.tabs.length
        ? state.selectedTabInfo.key
        : null;
  }

  FFI? _ffi(String peerId) =>
      Get.isRegistered<FFI>(tag: peerId) ? Get.find<FFI>(tag: peerId) : null;

  @override
  void initState() {
    super.initState();
    layout.addListener(_onLayoutChanged);
  }

  void sessionsChanged() {
    if (!mounted) return;
    _peerLabels.clear();
    setState(() => _revision++);
    _scheduleSync();
  }

  String _peerLabel(String peerId) => _peerLabels.putIfAbsent(
      peerId,
      () =>
          widget.peerLabelGetter?.call(peerId) ??
          tabs.where((tab) => tab.key == peerId).firstOrNull?.label ??
          peerId);

  bool isLegacyVisible(String peerId) =>
      !layout.isSplit && selectedPeer == peerId;

  void onTabSelected(String peerId) {
    if (_selectingTab) return;
    final ffi = _ffi(peerId);
    final display = ffi?.ffiModel.pi.currentDisplay ?? 0;
    if (layout.isSplit) layout.selectPeer(peerId, display < 0 ? 0 : display);
    sessionsChanged();
  }

  void prepareForNewConnection(String peerId, {int? display}) {
    if (!mounted || !layout.isSplit) return;
    suspendInput();
    layout.retainPeers(tabs.map((tab) => tab.key).toSet());
    final initialDisplay = display ??
        _leases[peerId]?.restoreDisplay ??
        _ffi(peerId)?.ffiModel.pi.currentDisplay ??
        0;
    layout.placeNewPeer(peerId, initialDisplay);
    // The caller adds/selects the tab synchronously next. Reserving first also
    // prevents its selection callback from overwriting the previously active pane.
  }

  void prepareForWindowTransfer(String peerId) {
    suspendInput();
    final lease = _leases.remove(peerId);
    final target =
        layout.visibleTargets.where((t) => t.peerId == peerId).firstOrNull;
    if (lease != null) {
      if (target != null) lease.restoreDisplay = target.display;
      lease.restore();
    }
    // The original transfer handler owns moving/closing the UI session.
    layout.retainPeers(
        tabs.map((tab) => tab.key).where((key) => key != peerId).toSet());
  }

  void suspendInput() {
    if (!layout.isSplit && selectedPeer != null) {
      _ffi(selectedPeer!)?.inputModel.releasePaneInputs();
    }
    for (final key in _paneKeys.values) {
      key.currentState?.suspendInput();
    }
    FocusManager.instance.primaryFocus?.unfocus();
  }

  void resumeInput() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted && layout.isSplit) {
        _paneKeys[layout.activeSlot]?.currentState?.requestInputFocus();
      }
    });
  }

  void changeMode(RemoteLayoutMode mode) {
    suspendInput();
    final peer = selectedPeer;
    final ffi = peer == null ? null : _ffi(peer);
    final display = ffi?.ffiModel.pi.currentDisplay ?? 0;
    if (mode == RemoteLayoutMode.single && layout.isSplit) {
      _expand(layout.activeTarget);
    } else {
      final peers = tabs.map((tab) => tab.key).toSet();
      layout.retainPeers(peers);
      layout.setMode(mode,
          initialTarget: peer == null
              ? null
              : RemotePaneTarget(peer, display < 0 ? 0 : display));
      if (layout.isSplit && peers.length > 1) {
        // Seed the current PC first, then fill vacant panes in tab order.
        // Existing manual monitor assignments and split ratios stay intact.
        final ordered = {if (peer != null) peer, ...peers};
        layout.fillEmptyPeers(ordered.map((id) {
          final saved = _leases[id]?.restoreDisplay ??
              _ffi(id)?.ffiModel.pi.currentDisplay ??
              0;
          return RemotePaneTarget(id, saved < 0 ? 0 : saved);
        }));
      }
    }
  }

  void _expand(RemotePaneTarget? target) {
    suspendInput();
    if (target != null) {
      final lease = _leases[target.peerId];
      // Restore the selected monitor into the existing full-featured page.
      if (lease != null) lease.restoreDisplay = target.display;
      _selectingTab = true;
      widget.tabs.jumpToByKey(target.peerId);
      _selectingTab = false;
    }
    layout.setMode(RemoteLayoutMode.single);
  }

  void _onLayoutChanged() {
    for (final ffi in _listened.values) {
      ffi.inputModel.pointerInputEnabled = !layout.isSplit;
    }
    // Release the old pane before any other pane can acquire native input.
    for (final entry in _paneKeys.entries) {
      if (!layout.isSplit || entry.key != layout.activeSlot) {
        entry.value.currentState?.suspendInput();
      }
    }
    final target = layout.activeTarget;
    if (layout.isSplit && target != null && selectedPeer != target.peerId) {
      _selectingTab = true;
      widget.tabs.jumpToByKey(target.peerId);
      _selectingTab = false;
    }
    if (mounted) setState(() {});
    _scheduleSync();
  }

  void _scheduleSync() {
    if (_scheduled) return;
    _scheduled = true;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _scheduled = false;
      if (mounted) _syncSessions();
    });
  }

  void _syncSessions() {
    final peers = tabs.map((tab) => tab.key).toSet();
    layout.retainPeers(peers);
    for (final peer in _listened.keys.toList()) {
      if (!peers.contains(peer) || !identical(_ffi(peer), _listened[peer])) {
        _listened.remove(peer)?.ffiModel.removeListener(sessionsChanged);
        _leases.remove(peer); // The connection owner is already closing.
        _displayCounts.remove(peer);
        _peerLabels.remove(peer);
        _missingTargets.removeWhere((target) => target.peerId == peer);
      }
    }
    for (final peer in peers) {
      final ffi = _ffi(peer);
      if (ffi == null || ffi.closed) continue;
      ffi.inputModel.pointerInputEnabled = !layout.isSplit;
      if (!_listened.containsKey(peer)) {
        _listened[peer] = ffi;
        ffi.ffiModel.addListener(sessionsChanged);
        setState(() => _revision++);
      }
      final pi = ffi.ffiModel.pi;
      if (!pi.isSet.value || pi.displays.isEmpty) continue;
      final oldCount = _displayCounts[peer];
      _displayCounts[peer] = pi.displays.length;
      if (oldCount != null && oldCount != pi.displays.length) {
        // Indices can be reused after unplugging a monitor. Require reselection
        // instead of silently controlling a different physical screen.
        _missingTargets.addAll(layout.slots
            .whereType<RemotePaneTarget>()
            .where((target) => target.peerId == peer));
        setState(() {});
      }
      if (!layout.isSplit) {
        _leases.remove(peer)?.restore();
        continue;
      }
      final wanted = layout.visibleTargets
          .where((target) =>
              target.peerId == peer &&
              !_missingTargets.contains(target) &&
              target.display >= 0 &&
              target.display < pi.displays.length)
          .map((target) => target.display)
          .toSet();
      if (wanted.isEmpty) continue;
      final lease = _leases.putIfAbsent(peer, () => _DisplayLease(ffi));
      lease.show(wanted);
    }
  }

  void _assign(int slot, RemotePaneTarget target) {
    suspendInput();
    _missingTargets.remove(target);
    layout.assign(slot, target);
  }

  bool _canDropPeer(int slot, RemotePaneDragData data) =>
      layout.isSplit &&
      slot < layout.mode.capacity &&
      layout.slots[slot] == null &&
      tabs.any((tab) => tab.key == data.peerId) &&
      (data.display == null ||
          layout.visibleTargets
              .contains(RemotePaneTarget(data.peerId, data.display!)));

  void _dropPeer(int slot, RemotePaneDragData data) {
    if (!_canDropPeer(slot, data)) return;
    suspendInput();
    final peerId = data.peerId;
    final display = _leases[peerId]?.restoreDisplay ??
        _ffi(peerId)?.ffiModel.pi.currentDisplay ??
        0;
    // Resolve at drop time so a tab closed during dragging cannot be resurrected.
    layout.moveToEmpty(
        slot,
        data.display == null
            ? layout.targetForPeer(peerId, display)
            : RemotePaneTarget(peerId, data.display!));
  }

  RemotePaneTarget? windowDragTarget(String peerId, int? display) {
    final ffi = _ffi(peerId);
    if (!layout.isSplit ||
        ffi == null ||
        ffi.closed ||
        !tabs.any((tab) => tab.key == peerId) ||
        !ffi.ffiModel.pi.isSet.value ||
        ffi.ffiModel.waitForFirstImage.value) {
      return null;
    }
    final target = display == null
        ? layout.targetForPeer(peerId,
            _leases[peerId]?.restoreDisplay ?? ffi.ffiModel.pi.currentDisplay)
        : RemotePaneTarget(peerId, display);
    if (_missingTargets.contains(target) ||
        target.display < 0 ||
        target.display >= ffi.ffiModel.pi.displays.length ||
        (display != null && !layout.visibleTargets.contains(target))) {
      return null;
    }
    return target;
  }

  int? emptyPaneAt(Offset globalPosition) {
    if (!mounted || !layout.isSplit) return null;
    final box = context.findRenderObject();
    if (box is! RenderBox || !box.hasSize) return null;
    final position = box.globalToLocal(globalPosition);
    final rects = layout.paneRects(box.size);
    for (var slot = 0; slot < rects.length; slot++) {
      if (layout.slots[slot] == null && rects[slot].contains(position)) {
        return slot;
      }
    }
    return null;
  }

  bool canReceiveWindowTarget(int slot, RemotePaneTarget target) =>
      mounted &&
      layout.isSplit &&
      slot >= 0 &&
      slot < layout.mode.capacity &&
      layout.slots[slot] == null &&
      !layout.slots.contains(target);

  void showWindowDropSlot(int? slot) {
    if (mounted && _windowDropSlot != slot) {
      setState(() => _windowDropSlot = slot);
    }
  }

  bool receiveWindowTarget(int slot, RemotePaneTarget target) {
    if (!canReceiveWindowTarget(slot, target)) return false;
    suspendInput();
    _missingTargets.remove(target);
    return layout.moveToEmpty(slot, target);
  }

  void completeWindowTransfer(RemotePaneTarget target) {
    suspendInput();
    layout.removeTarget(target);
    if (!layout.slots.any((other) => other?.peerId == target.peerId)) {
      // Destination owns a separate UI session on the same live connection.
      // Closing this UI normally releases only its own native session handler.
      _leases.remove(target.peerId);
      widget.tabs.closeBy(target.peerId);
    }
    resumeInput();
  }

  void restoreSplit() {
    suspendInput();
    layout.restoreSplit();
  }

  void arrange({bool monitors = false}) {
    if (!layout.isSplit) return;
    suspendInput();
    final peer = layout.activeTarget?.peerId ?? selectedPeer;
    final targets = <RemotePaneTarget>[];
    if (monitors && peer != null) {
      final pi = _ffi(peer)?.ffiModel.pi;
      if (pi != null && pi.isSet.value) {
        if (pi.isSupportMultiDisplay) {
          targets.addAll(List.generate(
              pi.displays.length, (i) => RemotePaneTarget(peer, i)));
        } else {
          targets.add(RemotePaneTarget(
              peer, pi.currentDisplay < 0 ? 0 : pi.currentDisplay));
        }
      }
    } else {
      for (final tab in tabs) {
        final saved = _leases[tab.key]?.restoreDisplay;
        final display = saved ?? _ffi(tab.key)?.ffiModel.pi.currentDisplay ?? 0;
        targets.add(RemotePaneTarget(tab.key, display < 0 ? 0 : display));
      }
    }
    if (targets.isNotEmpty) {
      _missingTargets.removeAll(targets);
      layout.arrange(targets);
    }
  }

  @override
  void dispose() {
    layout.removeListener(_onLayoutChanged);
    for (final ffi in _listened.values) {
      ffi.ffiModel.removeListener(sessionsChanged);
      ffi.inputModel.pointerInputEnabled = true;
    }
    // RemotePage owns shutdown; do not issue new subscriptions during teardown.
    for (final lease in _leases.values) {
      lease.ffi.textureModel.workspaceDisplays = null;
    }
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    _scheduleSync();
    return LayoutBuilder(
        builder: (context, workspaceConstraints) => Obx(() {
              final pages = <String, Widget>{
                for (final tab in widget.tabs.state.value.tabs)
                  tab.key: tab.page,
              };
              final selected = selectedPeer;
              final showSplit = layout.isSplit;
              final paneRects = layout.paneRects(workspaceConstraints.biggest);
              final dialogRects = <String, Rect>{};
              if (showSplit) {
                for (var i = 0; i < layout.mode.capacity; i++) {
                  final target = layout.slots[i];
                  if (target == null ||
                      dialogRects.containsKey(target.peerId)) {
                    continue;
                  }
                  final ffi = _ffi(target.peerId);
                  final needsConnectionUi = ffi == null ||
                      !ffi.ffiModel.pi.isSet.value ||
                      ffi.ffiModel.waitForFirstImage.value ||
                      ffi.dialogManager.hasOpenDialogs.value;
                  if (needsConnectionUi) {
                    WidgetsBinding.instance.addPostFrameCallback((_) {
                      if (mounted) _paneKeys[i]?.currentState?.suspendInput();
                    });
                    final rect = paneRects[i];
                    // Keep one existing authorization/error overlay per connection in
                    // its pane. Other live panes continue rendering and controlling.
                    dialogRects[target.peerId] = Rect.fromLTWH(
                        rect.left + 2,
                        rect.top + 34,
                        (rect.width - 4).clamp(0.0, double.infinity),
                        (rect.height - 36).clamp(0.0, double.infinity));
                  }
                }
              }
              return Stack(fit: StackFit.expand, children: [
                if (showSplit)
                  Stack(
                      children: List.generate(layout.mode.capacity, (index) {
                    final target = layout.slots[index];
                    final ffi = target == null ? null : _ffi(target.peerId);
                    final page = target == null
                        ? null
                        : widget.tabs.widget(target.peerId);
                    return Positioned.fromRect(
                        rect: paneRects[index],
                        child: RemotePaneDropTarget(
                            highlighted:
                                _windowDropSlot == index && target == null,
                            canAccept: (peerId) => _canDropPeer(index, peerId),
                            onAccept: (peerId) => _dropPeer(index, peerId),
                            child: RemoteSplitPane(
                              key: _paneKeys.putIfAbsent(index,
                                  () => GlobalKey<RemoteSplitPaneState>()),
                              target: target,
                              peerLabel: target == null
                                  ? null
                                  : _peerLabel(target.peerId),
                              usedDisplays: layout.visibleTargets
                                  .where((other) =>
                                      other.peerId == target?.peerId &&
                                      other != target)
                                  .map((other) => other.display)
                                  .toSet(),
                              ffi: ffi,
                              revision: _revision,
                              active: layout.activeSlot == index,
                              missing: target != null &&
                                  _missingTargets.contains(target),
                              onActivate: () => layout.activate(index),
                              onDragStart: suspendInput,
                              onDragEnd: resumeInput,
                              onSelectMonitor: target == null
                                  ? null
                                  : (display) {
                                      _assign(
                                          index,
                                          RemotePaneTarget(
                                              target.peerId, display));
                                    },
                              onExpand: () => _expand(target),
                              onClear: () {
                                suspendInput();
                                layout.assign(index, null);
                              },
                              onFileDrop: page is RemotePage
                                  ? page.handleWorkspaceFileDrop
                                  : null,
                            )));
                  })),
                RetainedRemotePages(
                    key: const ValueKey('connection-owners'),
                    pages: pages,
                    visibleKey: showSplit ? null : selected,
                    visibleRects: dialogRects),
                if (showSplit)
                  Positioned.fill(
                      child: RemoteSplitResizeHandles(
                          layout: layout,
                          onResizeStart: suspendInput,
                          onResizeEnd: resumeInput)),
                if (!stateGlobal.showTabBar.value)
                  Positioned(
                      right: 4,
                      bottom: 4,
                      child: Material(
                        elevation: 2,
                        borderRadius: BorderRadius.circular(4),
                        child: RemoteLayoutControls(
                            mode: layout.mode,
                            onSelected: changeMode,
                            onArrangePeers: arrange,
                            onArrangeMonitors: () => arrange(monitors: true),
                            onRestore:
                                layout.slots.any((target) => target != null)
                                    ? restoreSplit
                                    : null,
                            onOpened: suspendInput,
                            onClosed: resumeInput),
                      )),
              ]);
            }));
  }
}

class _DisplayLease {
  _DisplayLease(this.ffi) : restoreDisplay = ffi.ffiModel.pi.currentDisplay;
  final FFI ffi;
  int restoreDisplay;
  Set<int> _subscribed = {};

  void show(Set<int> requested) {
    final pi = ffi.ffiModel.pi;
    if (!pi.isSupportMultiDisplay) return;
    // Retain already subscribed displays until leaving split view, preserving
    // recording and avoiding asynchronous texture destroy/create races.
    final wanted = {..._subscribed, ...requested};
    if (restoreDisplay == kAllDisplayValue) {
      wanted.addAll(List.generate(pi.displays.length, (i) => i));
    } else if (restoreDisplay >= 0 && restoreDisplay < pi.displays.length) {
      wanted.add(restoreDisplay);
    }
    wanted.removeWhere((i) => i < 0 || i >= pi.displays.length);
    if (setEquals(wanted, _subscribed) &&
        pi.currentDisplay == kAllDisplayValue) {
      return;
    }
    _subscribed = wanted;
    ffi.textureModel.workspaceDisplays = wanted;
    ffi.textureModel.updateCurrentDisplay(kAllDisplayValue);
    ffi.ffiModel.switchToNewDisplay(kAllDisplayValue, ffi.sessionId, ffi.id);
    bind.sessionSwitchDisplay(
        isDesktop: true,
        sessionId: ffi.sessionId,
        value: Int32List.fromList(wanted.toList()..sort()));
  }

  void restore() {
    ffi.textureModel.workspaceDisplays = null;
    if (ffi.closed || !ffi.ffiModel.pi.isSet.value) return;
    final pi = ffi.ffiModel.pi;
    if (pi.displays.isEmpty) return;
    final display = restoreDisplay == kAllDisplayValue
        ? restoreDisplay
        : restoreDisplay.clamp(0, pi.displays.length - 1);
    openMonitorInTheSameTab(display, ffi, pi, updateCursorPos: false);
    ffi.textureModel.updateCurrentDisplay(display);
  }
}
