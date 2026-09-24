import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_hbb/desktop/models/remote_layout_model.dart';

void main() {
  const a1 = RemotePaneTarget('A', 0);
  const a2 = RemotePaneTarget('A', 1);
  const b1 = RemotePaneTarget('B', 0);
  const c1 = RemotePaneTarget('C', 0);

  test('default is single; split starts with current connection only', () {
    final model = RemoteLayoutModel();
    expect(model.mode, RemoteLayoutMode.single);
    model.setMode(RemoteLayoutMode.quad, initialTarget: a1);
    expect(model.slots.take(4), [a1, null, null, null]);
    expect(model.activeTarget, a1);
    model.dispose();
  });

  test('different monitors of the same PC coexist with other PCs', () {
    final model = RemoteLayoutModel()..setMode(RemoteLayoutMode.quad);
    model.arrange([a1, a2, b1, c1]);
    expect(model.visibleTargets, [a1, a2, b1, c1]);
    model.assign(3, a2);
    expect(model.activeSlot, 1);
    expect(model.visibleTargets, [a1, a2, b1, c1]);
  });

  test('narrowing preserves the active screen and hidden bindings', () {
    final model = RemoteLayoutModel()..setMode(RemoteLayoutMode.quad);
    model.arrange([a1, a2, b1, c1]);
    model.activate(3);
    model.setMode(RemoteLayoutMode.sideBySide);
    expect(model.activeTarget, c1);
    expect(model.visibleTargets, [c1, a2]);
    expect(model.slots.take(4).toSet(), {a1, a2, b1, c1});
    model.setMode(RemoteLayoutMode.quad);
    expect(model.slots.take(4).toSet(), {a1, a2, b1, c1});
  });

  test('single expansion and restore preserve all four bindings', () {
    final model = RemoteLayoutModel()..setMode(RemoteLayoutMode.quad);
    model.arrange([a1, a2, b1, c1]);
    model.activate(2);
    model.setMode(RemoteLayoutMode.single);
    expect(model.activeTarget, b1);
    expect(model.visibleTargets, isEmpty);
    model.restoreSplit();
    expect(model.mode, RemoteLayoutMode.quad);
    expect(model.slots.take(4), [a1, a2, b1, c1]);
    expect(model.activeSlot, 2);
  });

  test('selecting a peer activates its pane, hidden peer replaces active slot',
      () {
    final model = RemoteLayoutModel()..setMode(RemoteLayoutMode.quad);
    model.arrange([a1, a2, b1, c1]);
    model.selectPeer('B', 0);
    expect(model.activeSlot, 2);
    model.selectPeer('D', 1);
    expect(model.slots.take(4), [a1, a2, const RemotePaneTarget('D', 1), c1]);
  });

  test('clearing a pane leaves its sibling monitor binding intact', () {
    final model = RemoteLayoutModel()..setMode(RemoteLayoutMode.sideBySide);
    model.arrange([a1, a2]);
    model.assign(0, null);
    expect(model.slots.take(4), [null, a2, null, null]);
  });

  test('closing a PC removes every monitor but leaves other PCs in place', () {
    final model = RemoteLayoutModel()..setMode(RemoteLayoutMode.quad);
    model.arrange([a1, a2, b1, c1]);
    model.retainPeers({'B', 'C'});
    expect(model.slots.take(4), [null, null, b1, c1]);
  });

  test('hidden duplicate moves into view instead of being duplicated', () {
    final model = RemoteLayoutModel()..setMode(RemoteLayoutMode.quad);
    model.arrange([a1, a2, b1, c1]);
    model.setMode(RemoteLayoutMode.sideBySide);
    model.assign(1, c1);
    expect(model.slots.take(4), [a1, c1, b1, null]);
  });

  test('automatic layout removes duplicates and caps only displayed screens',
      () {
    final model = RemoteLayoutModel()..setMode(RemoteLayoutMode.quad);
    model.arrange([a1, a1, a2, b1, c1, const RemotePaneTarget('D', 0)]);
    expect(model.visibleTargets, [a1, a2, b1, c1]);
  });

  test('auto fill preserves manual monitors and adds each missing PC once', () {
    final model = RemoteLayoutModel()..setMode(RemoteLayoutMode.quad);
    model.arrange([a2]);
    model.activate(3);
    model.fillEmptyPeers([a1, b1, const RemotePaneTarget('B', 1), c1]);
    expect(model.slots.take(4), [a2, b1, c1, null]);
    expect(model.activeSlot, 3);
    var notifications = 0;
    model.addListener(() => notifications++);
    model.fillEmptyPeers([a1, b1, c1]);
    expect(notifications, 0);
    model.setMode(RemoteLayoutMode.single);
    model.fillEmptyPeers([const RemotePaneTarget('D', 0)]);
    expect(model.slots.take(4), [a2, b1, c1, null]);
  });

  test('auto fill moves a hidden screen and stops at visible capacity', () {
    final model = RemoteLayoutModel()..setMode(RemoteLayoutMode.quad);
    model.arrange([a1, a2, b1, c1]);
    model.setMode(RemoteLayoutMode.sideBySide);
    model.assign(1, null);
    model.fillEmptyPeers([b1, c1, const RemotePaneTarget('D', 0)]);
    expect(model.slots.take(4), [a1, b1, null, c1]);
    expect(model.activeSlot, 1);
    model.setMode(RemoteLayoutMode.quad);
    model.fillEmptyPeers([a1, b1, c1, const RemotePaneTarget('D', 0)]);
    expect(model.slots.take(4), [a1, b1, const RemotePaneTarget('D', 0), c1]);
  });

  test('all layouts tile without overlaps at normal and tiny sizes', () {
    for (final mode in RemoteLayoutMode.values) {
      for (final size in [const Size(1200, 800), const Size(1, 1)]) {
        final rects = RemoteLayoutModel.rectangles(mode, size);
        expect(rects.length, mode.capacity);
        for (final rect in rects) {
          expect(rect.width, greaterThanOrEqualTo(0));
          expect(rect.height, greaterThanOrEqualTo(0));
          for (final other in rects) {
            if (rect != other) expect(rect.overlaps(other), isFalse);
          }
        }
      }
    }
  });

  test('six panes survive narrowing, rotation, expansion and restore', () {
    final model = RemoteLayoutModel()..setMode(RemoteLayoutMode.sixWide);
    final targets = [
      a1,
      a2,
      b1,
      c1,
      const RemotePaneTarget('D', 0),
      const RemotePaneTarget('E', 1)
    ];
    model.arrange(targets);
    model.activate(5);
    for (final mode in [
      RemoteLayoutMode.quad,
      RemoteLayoutMode.sideBySide,
      RemoteLayoutMode.sixTall
    ]) {
      model.setMode(mode);
      expect(model.activeTarget, targets.last);
      expect(model.slots.toSet(), targets.toSet());
    }
    final before = model.slots.toList();
    model.setMode(RemoteLayoutMode.single);
    model.restoreSplit();
    expect(model.mode, RemoteLayoutMode.sixTall);
    expect(model.slots, before);
    model.assign(5, null);
    expect(model.moveToEmpty(5, a2), isTrue);
    expect(model.slots[5], a2);
    expect(model.slots.where((target) => target == a2), hasLength(1));
    model.placeNewPeer('F', 0);
    expect(model.visibleTargets, contains(const RemotePaneTarget('F', 0)));
    expect(model.visibleTargets, hasLength(6));
    model.placeNewPeer('G', 0);
    expect(model.slots[0], const RemotePaneTarget('G', 0));
  });

  for (final mode in [RemoteLayoutMode.sixWide, RemoteLayoutMode.sixTall]) {
    test('${mode.name} resizes either boundary without shifting the other', () {
      final model = RemoteLayoutModel()..setMode(mode);
      const size = Size(1216, 916);
      final wide = mode == RemoteLayoutMode.sixWide;
      final before = model.paneRects(size);
      final axis = wide
          ? [before[0], before[1], before[2]]
          : [before[0], before[2], before[4]];
      double extent(Rect rect) => wide ? rect.width : rect.height;
      final position = (wide ? axis[1].right : axis[1].bottom) + 4 + 40;
      model.resize(size,
          columnDivider: 1,
          rowDivider: 1,
          dividerX: wide ? position : null,
          dividerY: wide ? null : position);
      final resized = model.paneRects(size);
      expect(extent(resized[0]), closeTo(extent(axis[0]), 0.001));
      expect(
          extent(resized[wide ? 1 : 2]), closeTo(extent(axis[1]) + 40, 0.001));
      expect(
          extent(resized[wide ? 2 : 4]), closeTo(extent(axis[2]) - 40, 0.001));
      model.setMode(RemoteLayoutMode.quad);
      model.setMode(mode);
      expect(model.paneRects(size), resized);
      model.resetSizes();
      expect(model.paneRects(size), before);
      model.resize(size,
          dividerX: wide ? -10000 : null, dividerY: wide ? null : -10000);
      final minimum = wide ? 160.0 : 100.0;
      expect(extent(model.paneRects(size)[0]), closeTo(minimum, 0.001));
      for (final small in [const Size(300, 180), const Size(1, 1), Size.zero]) {
        final rects = model.paneRects(small);
        expect(rects, hasLength(6));
        for (final rect in rects) {
          expect(rect.left, greaterThanOrEqualTo(0));
          expect(rect.top, greaterThanOrEqualTo(0));
          expect(rect.right, lessThanOrEqualTo(small.width));
          expect(rect.bottom, lessThanOrEqualTo(small.height));
          expect(rect.width, greaterThanOrEqualTo(0));
          expect(rect.height, greaterThanOrEqualTo(0));
        }
      }
    });
  }

  test('resize preserves bindings and ratios through window and mode changes',
      () {
    final model = RemoteLayoutModel()..setMode(RemoteLayoutMode.quad);
    model.arrange([a1, a2, b1, c1]);
    model.activate(2);
    model.resize(const Size(1008, 808), dividerX: 604, dividerY: 244);
    expect(model.columnFraction, 0.6);
    expect(model.rowFraction, 0.3);
    expect(model.paneRects(const Size(2008, 1608)).first.size,
        const Size(1200, 480));
    model.setMode(RemoteLayoutMode.single);
    model.restoreSplit();
    expect(model.paneRects(const Size(1008, 808)).first.size,
        const Size(600, 240));
    expect(model.slots.take(4), [a1, a2, b1, c1]);
    expect(model.activeSlot, 2);
    model.resetSizes(columns: false);
    expect(model.columnFraction, 0.6);
    expect(model.rowFraction, 0.5);
  });

  test('minimum pane sizes adapt to small windows without losing saved ratios',
      () {
    final model = RemoteLayoutModel()..setMode(RemoteLayoutMode.quad);
    model.resize(const Size(1008, 808), dividerX: -1000, dividerY: 5000);
    final rects = model.paneRects(const Size(1008, 808));
    expect(rects.first.width, 160);
    expect(rects.last.height, 100);
    final savedX = model.columnFraction;
    final savedY = model.rowFraction;
    for (final size in [const Size(300, 180), const Size(1, 1), Size.zero]) {
      for (final rect in model.paneRects(size)) {
        expect(rect.left, greaterThanOrEqualTo(0));
        expect(rect.top, greaterThanOrEqualTo(0));
        expect(rect.right, lessThanOrEqualTo(size.width));
        expect(rect.bottom, lessThanOrEqualTo(size.height));
      }
    }
    expect(model.columnFraction, savedX);
    expect(model.rowFraction, savedY);
    model.resize(Size.zero, dividerX: 0, dividerY: double.nan);
    expect(model.columnFraction, savedX);
    expect(model.rowFraction, savedY);
  });

  test('tab drop moves its active monitor and preserves sibling monitors', () {
    final model = RemoteLayoutModel()..setMode(RemoteLayoutMode.quad);
    model.arrange([a1, a2, b1]);
    model.activate(1);
    expect(model.targetForPeer('A', 0), a2);
    expect(model.moveToEmpty(3, model.targetForPeer('A', 0)), isTrue);
    expect(model.slots.take(4), [a1, null, b1, a2]);
    expect(model.activeSlot, 3);
    expect(model.moveToEmpty(0, b1), isFalse);
    expect(model.slots.take(4), [a1, null, b1, a2]);
    expect(model.targetForPeer('C', 1), const RemotePaneTarget('C', 1));
    model.setMode(RemoteLayoutMode.single);
    expect(model.moveToEmpty(1, c1), isFalse);
  });

  test('new connections use selected empty pane, then first empty pane', () {
    final model = RemoteLayoutModel()..setMode(RemoteLayoutMode.quad);
    model.arrange([a1]);
    model.activate(3);
    model.placeNewPeer('B', 1);
    expect(model.activeSlot, 3);
    expect(
        model.slots.take(4), [a1, null, null, const RemotePaneTarget('B', 1)]);
    model.placeNewPeer('C', -1);
    expect(model.activeSlot, 1);
    expect(model.slots.take(4), [a1, c1, null, const RemotePaneTarget('B', 1)]);
  });

  test('new connections replace first pane only when visible panes are full',
      () {
    for (final mode in [
      RemoteLayoutMode.sideBySide,
      RemoteLayoutMode.stacked,
      RemoteLayoutMode.quad
    ]) {
      final model = RemoteLayoutModel()..setMode(mode);
      model.arrange([a1, a2, b1, c1]);
      final before = model.slots.toList();
      model.activate(mode.capacity - 1);
      model.placeNewPeer('D', 0);
      expect(model.activeSlot, 0);
      expect(model.slots[0], const RemotePaneTarget('D', 0));
      expect(model.slots.skip(1), before.skip(1));
    }
  });

  test(
      'new connection requests reuse displayed monitor and preserve single view',
      () {
    final model = RemoteLayoutModel()..setMode(RemoteLayoutMode.quad);
    model.arrange([a2, b1]);
    model.activate(1);
    model.placeNewPeer('A', 0);
    expect(model.activeSlot, 0);
    expect(model.slots.take(4), [a2, b1, null, null]);
    model.setMode(RemoteLayoutMode.single);
    model.placeNewPeer('C', 0);
    expect(model.mode, RemoteLayoutMode.single);
    expect(model.slots.take(4), [a2, b1, null, null]);
  });
}
