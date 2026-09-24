import 'dart:collection';
import 'dart:math' as math;

import 'package:flutter/foundation.dart';
import 'package:flutter/widgets.dart';

enum RemoteLayoutMode { single, sideBySide, stacked, quad, sixWide, sixTall }

extension RemoteLayoutModeInfo on RemoteLayoutMode {
  int get columns => switch (this) {
        RemoteLayoutMode.single || RemoteLayoutMode.stacked => 1,
        RemoteLayoutMode.sixWide => 3,
        _ => 2,
      };

  int get rows => switch (this) {
        RemoteLayoutMode.single || RemoteLayoutMode.sideBySide => 1,
        RemoteLayoutMode.sixTall => 3,
        _ => 2,
      };

  int get capacity => columns * rows;

  String get label => switch (this) {
        RemoteLayoutMode.single => '단일 화면',
        RemoteLayoutMode.sideBySide => '좌우 2분할',
        RemoteLayoutMode.stacked => '상하 2분할',
        RemoteLayoutMode.quad => '4분할',
        RemoteLayoutMode.sixWide => '가로 6분할 (3열 × 2행)',
        RemoteLayoutMode.sixTall => '세로 6분할 (2열 × 3행)',
      };
}

@immutable
class RemotePaneTarget {
  const RemotePaneTarget(this.peerId, this.display);

  final String peerId;
  final int display;

  @override
  bool operator ==(Object other) =>
      other is RemotePaneTarget &&
      peerId == other.peerId &&
      display == other.display;

  @override
  int get hashCode => Object.hash(peerId, display);
}

/// Window-local layout only. It never creates or closes a connection.
class RemoteLayoutModel extends ChangeNotifier {
  static const splitGap = 8.0;
  static const minimumPaneSize = Size(160, 100);

  RemoteLayoutMode _mode = RemoteLayoutMode.single;
  RemoteLayoutMode _lastSplitMode = RemoteLayoutMode.sideBySide;
  final List<RemotePaneTarget?> _slots = List.filled(6, null);
  int _activeSlot = 0;
  double _columnFraction = 0.5;
  double _rowFraction = 0.5;
  List<double> _columnThirds = List.filled(3, 1 / 3);
  List<double> _rowThirds = List.filled(3, 1 / 3);

  RemoteLayoutMode get mode => _mode;
  int get activeSlot => _activeSlot;
  bool get isSplit => _mode != RemoteLayoutMode.single;
  bool get hasColumns => _mode.columns > 1;
  bool get hasRows => _mode.rows > 1;
  double get columnFraction => _columnFraction;
  double get rowFraction => _rowFraction;
  RemotePaneTarget? get activeTarget => _slots[_activeSlot];
  UnmodifiableListView<RemotePaneTarget?> get slots =>
      UnmodifiableListView(_slots);
  List<RemotePaneTarget> get visibleTargets => isSplit
      ? _slots.take(_mode.capacity).whereType<RemotePaneTarget>().toList()
      : [];

  void setMode(RemoteLayoutMode mode, {RemotePaneTarget? initialTarget}) {
    if (mode == _mode) return;
    if (mode != RemoteLayoutMode.single) {
      _lastSplitMode = mode;
      if (_slots.every((target) => target == null)) {
        _slots[0] = initialTarget;
      }
      if (_activeSlot >= mode.capacity) {
        // Keep the active screen visible when reducing the number of panes.
        final first = _slots[0];
        _slots[0] = _slots[_activeSlot];
        _slots[_activeSlot] = first;
        _activeSlot = 0;
      }
    }
    _mode = mode;
    notifyListeners();
  }

  void restoreSplit() => setMode(_lastSplitMode);

  void activate(int slot) {
    if (slot < 0 || slot >= _mode.capacity || slot == _activeSlot) return;
    _activeSlot = slot;
    notifyListeners();
  }

  void assign(int slot, RemotePaneTarget? target) {
    if (slot < 0 || slot >= _mode.capacity) return;
    final existing = target == null ? -1 : _slots.indexOf(target);
    if (existing >= 0 && existing < _mode.capacity) {
      _activeSlot = existing;
    } else {
      if (existing >= 0) _slots[existing] = null;
      _slots[slot] = target;
      _activeSlot = slot;
    }
    notifyListeners();
  }

  void selectPeer(String peerId, int defaultDisplay) {
    if (!isSplit || activeTarget?.peerId == peerId) return;
    final visible = _slots.take(_mode.capacity).toList();
    final index = visible.indexWhere((target) => target?.peerId == peerId);
    if (index >= 0) {
      activate(index);
    } else {
      assign(_activeSlot, RemotePaneTarget(peerId, defaultDisplay));
    }
  }

  /// Reserve a visible pane before a new connection's authentication UI mounts.
  /// Replacing a pane changes only its presentation, never its connection.
  void placeNewPeer(String peerId, int defaultDisplay) {
    if (!isSplit || activeTarget?.peerId == peerId) return;
    final visible = _slots.take(_mode.capacity).toList();
    final existing = visible.indexWhere((target) => target?.peerId == peerId);
    if (existing >= 0) {
      activate(existing);
      return;
    }
    final empty = activeTarget == null
        ? _activeSlot
        : visible.indexWhere((target) => target == null);
    assign(empty >= 0 ? empty : 0,
        RemotePaneTarget(peerId, defaultDisplay < 0 ? 0 : defaultDisplay));
  }

  RemotePaneTarget targetForPeer(String peerId, int defaultDisplay) {
    final active = activeTarget;
    if (active?.peerId == peerId) return active!;
    for (final target in visibleTargets) {
      if (target.peerId == peerId) return target;
    }
    return RemotePaneTarget(peerId, defaultDisplay < 0 ? 0 : defaultDisplay);
  }

  /// Unlike the picker, a drop moves an existing screen into the empty slot.
  bool moveToEmpty(int slot, RemotePaneTarget target) {
    if (!isSplit ||
        slot < 0 ||
        slot >= _mode.capacity ||
        _slots[slot] != null) {
      return false;
    }
    final previous = _slots.indexOf(target);
    if (previous >= 0) _slots[previous] = null;
    _slots[slot] = target;
    _activeSlot = slot;
    notifyListeners();
    return true;
  }

  /// Acknowledged window transfer removes only this monitor, including a saved
  /// hidden slot. Other monitor bindings for the same connection survive.
  void removeTarget(RemotePaneTarget target) {
    final index = _slots.indexOf(target);
    if (index < 0) return;
    _slots[index] = null;
    notifyListeners();
  }

  void arrange(Iterable<RemotePaneTarget> targets) {
    if (!isSplit) return;
    final unique = targets.toSet().take(_mode.capacity).toList();
    for (var i = 0; i < _slots.length; i++) {
      _slots[i] = i < unique.length ? unique[i] : null;
    }
    _activeSlot = 0;
    notifyListeners();
  }

  /// Fill only vacant visible panes, at most once per additional PC. Preserve
  /// manual monitor assignments, the active pane, and hidden layout bindings.
  void fillEmptyPeers(Iterable<RemotePaneTarget> targets) {
    if (!isSplit) return;
    final peers = visibleTargets.map((target) => target.peerId).toSet();
    var changed = false;
    for (final target in targets) {
      if (peers.contains(target.peerId)) continue;
      final empty = _slots.take(_mode.capacity).toList().indexOf(null);
      if (empty < 0) break;
      // A screen saved outside the visible area moves instead of duplicating.
      final previous = _slots.indexOf(target);
      if (previous >= 0) _slots[previous] = null;
      _slots[empty] = target;
      peers.add(target.peerId);
      changed = true;
    }
    if (changed) notifyListeners();
  }

  void retainPeers(Set<String> peers) {
    var changed = false;
    for (var i = 0; i < _slots.length; i++) {
      if (_slots[i] != null && !peers.contains(_slots[i]!.peerId)) {
        _slots[i] = null;
        changed = true;
      }
    }
    if (changed) notifyListeners();
  }

  List<Rect> paneRects(Size size) => rectangles(_mode, size,
      columnFraction: _columnFraction,
      rowFraction: _rowFraction,
      columnThirds: _columnThirds,
      rowThirds: _rowThirds);

  /// Divider coordinates refer to the center of the gap in the pane area.
  /// Store ratios so window resizing and single/split transitions preserve them.
  void resize(Size size,
      {double? dividerX,
      double? dividerY,
      int columnDivider = 0,
      int rowDivider = 0}) {
    double fraction(
        double position, double extent, double minimum, double previous) {
      final available = extent - splitGap;
      if (!position.isFinite || !available.isFinite || available <= 0) {
        return previous;
      }
      return _firstExtent(
              available, (position - splitGap / 2) / available, minimum) /
          available;
    }

    // The two- and three-track ratios are separate, so changing orientation or
    // returning to a previous split restores its divider positions.
    final columns = _mode.columns == 2 && dividerX != null
        ? fraction(dividerX, size.width, minimumPaneSize.width, _columnFraction)
        : _columnFraction;
    final rows = _mode.rows == 2 && dividerY != null
        ? fraction(dividerY, size.height, minimumPaneSize.height, _rowFraction)
        : _rowFraction;
    final columnThirds = _mode.columns == 3 && dividerX != null
        ? _resizeThirds(_columnThirds, size.width, minimumPaneSize.width,
            columnDivider, dividerX)
        : _columnThirds;
    final rowThirds = _mode.rows == 3 && dividerY != null
        ? _resizeThirds(_rowThirds, size.height, minimumPaneSize.height,
            rowDivider, dividerY)
        : _rowThirds;
    if (columns == _columnFraction &&
        rows == _rowFraction &&
        listEquals(columnThirds, _columnThirds) &&
        listEquals(rowThirds, _rowThirds)) {
      return;
    }
    _columnFraction = columns;
    _rowFraction = rows;
    _columnThirds = columnThirds;
    _rowThirds = rowThirds;
    notifyListeners();
  }

  void resetSizes({bool columns = true, bool rows = true}) {
    final nextColumns = columns && _mode.columns == 2 ? 0.5 : _columnFraction;
    final nextRows = rows && _mode.rows == 2 ? 0.5 : _rowFraction;
    final columnThirds = columns && _mode.columns == 3
        ? List<double>.filled(3, 1 / 3)
        : _columnThirds;
    final rowThirds =
        rows && _mode.rows == 3 ? List<double>.filled(3, 1 / 3) : _rowThirds;
    if (nextColumns == _columnFraction &&
        nextRows == _rowFraction &&
        listEquals(columnThirds, _columnThirds) &&
        listEquals(rowThirds, _rowThirds)) {
      return;
    }
    _columnFraction = nextColumns;
    _rowFraction = nextRows;
    _columnThirds = columnThirds;
    _rowThirds = rowThirds;
    notifyListeners();
  }

  static double _firstExtent(
      double available, double fraction, double minimum) {
    final limit = math.min(minimum, available / 2);
    return (available * fraction).clamp(limit, available - limit);
  }

  static List<double> _thirdExtents(
      double available, List<double> weights, double minimum) {
    final limit = math.min(minimum, available / 3);
    final result = List<double>.filled(3, 0);
    final pending = {0, 1, 2};
    var remaining = available;
    while (pending.isNotEmpty) {
      final total = pending.fold<double>(0, (sum, i) => sum + weights[i]);
      final limited =
          pending.where((i) => remaining * weights[i] / total < limit).toList();
      if (limited.isEmpty) {
        for (final i in pending) {
          result[i] = remaining * weights[i] / total;
        }
        break;
      }
      for (final i in limited) {
        result[i] = limit;
        remaining -= limit;
        pending.remove(i);
      }
    }
    return result;
  }

  static List<double> _resizeThirds(List<double> weights, double extent,
      double minimum, int divider, double position) {
    final available = extent - 2 * splitGap;
    if (!position.isFinite ||
        !available.isFinite ||
        available <= 3 * minimum ||
        divider < 0 ||
        divider > 1) {
      return weights;
    }
    final sizes = _thirdExtents(available, weights, minimum);
    final start = divider == 0 ? 0.0 : sizes[0] + splitGap;
    final pair = sizes[divider] + sizes[divider + 1];
    sizes[divider] =
        (position - start - splitGap / 2).clamp(minimum, pair - minimum);
    sizes[divider + 1] = pair - sizes[divider];
    return sizes.map((value) => value / available).toList();
  }

  static List<Rect> rectangles(RemoteLayoutMode mode, Size size,
      {double gap = splitGap,
      double columnFraction = 0.5,
      double rowFraction = 0.5,
      List<double> columnThirds = const [1 / 3, 1 / 3, 1 / 3],
      List<double> rowThirds = const [1 / 3, 1 / 3, 1 / 3]}) {
    final columns = mode.columns;
    final rows = mode.rows;
    final gapX = columns > 1 ? math.min(gap, size.width / (columns - 1)) : 0.0;
    final gapY = rows > 1 ? math.min(gap, size.height / (rows - 1)) : 0.0;
    final availableWidth = math.max(0.0, size.width - gapX * (columns - 1));
    final availableHeight = math.max(0.0, size.height - gapY * (rows - 1));
    List<double> extents(int count, double available, double fraction,
        List<double> thirds, double minimum) {
      if (count == 1) return [available];
      if (count == 3) return _thirdExtents(available, thirds, minimum);
      final first = _firstExtent(available, fraction, minimum);
      return [first, available - first];
    }

    final widths = extents(columns, availableWidth, columnFraction,
        columnThirds, minimumPaneSize.width);
    final heights = extents(
        rows, availableHeight, rowFraction, rowThirds, minimumPaneSize.height);
    return List.generate(mode.capacity, (i) {
      final column = i % columns;
      final row = i ~/ columns;
      final left =
          widths.take(column).fold<double>(0, (a, b) => a + b) + gapX * column;
      final top =
          heights.take(row).fold<double>(0, (a, b) => a + b) + gapY * row;
      return Rect.fromLTWH(
          left,
          top,
          column == columns - 1
              ? math.max(0, size.width - left)
              : widths[column],
          row == rows - 1 ? math.max(0, size.height - top) : heights[row]);
    });
  }
}
