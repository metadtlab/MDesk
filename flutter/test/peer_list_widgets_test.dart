import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_hbb/common/widgets/peer_list_widgets.dart';
import 'package:get/get.dart';

Widget row(
  String name, {
  bool selected = false,
  bool currentDevice = false,
  VoidCallback? onTap,
  VoidCallback? onDoubleTap,
  GestureTapDownCallback? onSecondaryTapDown,
  Widget? child,
}) =>
    PeerListRow(
      key: ValueKey(name),
      selected: selected,
      currentDevice: currentDevice,
      onTap: onTap ?? () {},
      onDoubleTap: onDoubleTap ?? () {},
      onSecondaryTapDown: onSecondaryTapDown ?? (_) {},
      child: child ??
          Row(children: [
            Expanded(flex: 5, child: Text(name)),
            const Expanded(flex: 4, child: Text('123 456 789')),
            const SizedBox(width: 50, child: Text('Online')),
          ]),
    );

Widget app(Widget child, {Brightness brightness = Brightness.light}) =>
    MaterialApp(
      theme: ThemeData(brightness: brightness),
      home: Scaffold(
          body: Align(
              alignment: Alignment.topLeft,
              child: SizedBox(width: 700, height: 300, child: child))),
    );

Color background(WidgetTester tester, String name) => tester
    .widget<Material>(
      find.descendant(
          of: find.byKey(ValueKey(name)), matching: find.byType(Material)),
    )
    .color!;

Border border(WidgetTester tester, String name) => (tester
        .widget<Container>(find.descendant(
          of: find.byKey(ValueKey(name)),
          matching: find.byType(Container),
        ))
        .decoration! as BoxDecoration)
    .border! as Border;

void main() {
  testWidgets('hover covers name, ID, status and padding without selecting',
      (tester) async {
    var taps = 0;
    await tester.pumpWidget(app(Column(children: [
      row('PC A', onTap: () => taps++),
      row('PC B', onTap: () => taps++),
    ])));
    final initial = background(tester, 'PC A');
    final textPosition = tester.getTopLeft(find.text('PC A'));
    final rect = tester.getRect(find.byKey(const ValueKey('PC A')));
    final mouse = await tester.createGesture(kind: PointerDeviceKind.mouse);
    await mouse.addPointer(location: const Offset(750, 400));
    for (final x in [2.0, 80.0, 450.0, 660.0, 698.0]) {
      await mouse.moveTo(Offset(rect.left + x, rect.center.dy));
      await tester.pump();
      expect(background(tester, 'PC A'), isNot(initial));
      expect(border(tester, 'PC A').left.color, isNot(Colors.transparent));
      expect(background(tester, 'PC B'), initial);
      expect(tester.getTopLeft(find.text('PC A')), textPosition);
    }
    expect(taps, 0);
    await mouse.moveTo(tester.getCenter(find.byKey(const ValueKey('PC B'))));
    await tester.pump();
    expect(background(tester, 'PC A'), initial);
    expect(border(tester, 'PC A').left.color, Colors.transparent);
    expect(background(tester, 'PC B'), isNot(initial));
    await mouse.removePointer();
    await tester.pumpAndSettle();
    expect(background(tester, 'PC B'), initial);
  });

  for (final brightness in Brightness.values) {
    for (final mode in ['normal', 'selected', 'currentDevice']) {
      testWidgets('$brightness $mode restores its own color after hover',
          (tester) async {
        await tester.pumpWidget(app(
            Column(children: [
              row(
                'PC',
                selected: mode == 'selected',
                currentDevice: mode == 'currentDevice',
              )
            ]),
            brightness: brightness));
        final initial = background(tester, 'PC');
        final mouse = await tester.createGesture(kind: PointerDeviceKind.mouse);
        await mouse.addPointer(location: const Offset(750, 400));
        await mouse.moveTo(tester.getCenter(find.byKey(const ValueKey('PC'))));
        await tester.pump();
        expect(background(tester, 'PC'), isNot(initial));
        expect(tester.widget<PeerListRow>(find.byType(PeerListRow)).selected,
            mode == 'selected');
        await mouse.removePointer();
        await tester.pumpAndSettle();
        expect(background(tester, 'PC'), initial);
        expect(tester.takeException(), isNull);
      });
    }
  }

  testWidgets('single, double and secondary clicks keep separate callbacks',
      (tester) async {
    var selected = 0;
    var connected = 0;
    Offset? menuPosition;
    await tester.pumpWidget(app(Column(children: [
      row(
        'PC',
        onTap: () => selected++,
        onDoubleTap: () => connected++,
        onSecondaryTapDown: (details) => menuPosition = details.globalPosition,
      )
    ])));
    final finder = find.byKey(const ValueKey('PC'));
    await tester.tap(finder);
    // A single tap is delivered only once the double-tap timer expires.
    await tester.pump(kDoubleTapTimeout + const Duration(milliseconds: 1));
    await tester.pumpAndSettle();
    expect(selected, 1);
    expect(connected, 0);
    await tester.tap(finder);
    await tester.pump(const Duration(milliseconds: 80));
    await tester.tap(finder);
    await tester.pumpAndSettle();
    expect(selected, 1);
    expect(connected, 1);
    final position = tester.getCenter(finder);
    final mouse = await tester.startGesture(position,
        kind: PointerDeviceKind.mouse, buttons: kSecondaryMouseButton);
    await mouse.up();
    await tester.pumpAndSettle();
    expect(menuPosition, position);
    expect(selected, 1);
    expect(connected, 1);
  });

  testWidgets('hover does not rebuild the list or row contents',
      (tester) async {
    var listBuilds = 0;
    var contentBuilds = 0;
    await tester.pumpWidget(app(Builder(builder: (context) {
      listBuilds++;
      return Column(
          children: List.generate(
              5,
              (index) => row(
                    'PC $index',
                    child: Builder(builder: (context) {
                      contentBuilds++;
                      return Text('PC $index');
                    }),
                  )));
    })));
    final initialListBuilds = listBuilds;
    final initialContentBuilds = contentBuilds;
    final mouse = await tester.createGesture(kind: PointerDeviceKind.mouse);
    await mouse.addPointer(location: const Offset(750, 400));
    for (var i = 0; i < 5; i++) {
      await mouse.moveTo(tester.getCenter(find.byKey(ValueKey('PC $i'))));
      await tester.pump();
    }
    expect(listBuilds, initialListBuilds);
    expect(contentBuilds, initialContentBuilds);
    await mouse.removePointer();
    await tester.pumpAndSettle();
  });

  testWidgets('2000 peers build only near the viewport and scroll on demand',
      (tester) async {
    final built = <int>{};
    final controller = ScrollController();
    addTearDown(controller.dispose);
    await tester.pumpWidget(app(CustomScrollView(
      controller: controller,
      slivers: [
        PeerListSection<int>(
          header: const Text('My Devices (2000)'),
          expanded: true,
          items: List.generate(2000, (index) => index),
          itemBuilder: (_, index) {
            built.add(index);
            return row('PC $index');
          },
        )
      ],
    )));
    expect(find.text('PC 0'), findsOneWidget);
    expect(built.length, lessThan(40));
    expect(built, isNot(contains(1999)));
    final initialCount = built.length;
    controller.jumpTo(1800);
    await tester.pumpAndSettle();
    expect(find.text('PC 0'), findsNothing);
    expect(built.any((index) => index > 40), isTrue);
    expect(built.length, lessThan(120));
    debugPrint('Peer list: $initialCount / 2000 rows built initially; '
        '${built.length} unique rows after scrolling 1800px.');
    expect(tester.takeException(), isNull);
  });

  testWidgets(
      'collapsed and loading categories build no rows; empty can refill',
      (tester) async {
    var builds = 0;
    Future<void> show(
        {required bool expanded,
        Widget? placeholder,
        List<int> items = const [1, 2]}) async {
      await tester.pumpWidget(app(CustomScrollView(slivers: [
        PeerListSection<int>(
          header: const Text('Devices'),
          expanded: expanded,
          items: items,
          placeholder: placeholder,
          itemBuilder: (_, index) {
            builds++;
            return row('PC $index');
          },
        ),
        const SliverToBoxAdapter(child: Text('Next category')),
      ])));
    }

    await show(expanded: false);
    expect(builds, 0);
    expect(find.text('Devices'), findsOneWidget);
    expect(find.text('Next category'), findsOneWidget);
    await show(expanded: true, placeholder: const Text('Loading'));
    expect(builds, 0);
    expect(find.text('Loading'), findsOneWidget);
    await show(expanded: true, items: [], placeholder: const Text('Empty'));
    expect(builds, 0);
    expect(find.text('Empty'), findsOneWidget);
    await show(expanded: true);
    expect(find.text('PC 1'), findsOneWidget);
    expect(find.text('PC 2'), findsOneWidget);
    expect(find.text('Loading'), findsNothing);
    expect(find.text('Empty'), findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets(
      'reactive snapshots replace filtered and updated rows immediately',
      (tester) async {
    final peers = List.generate(2000, (index) => 'PC $index').obs;
    final query = ''.obs;
    await tester.pumpWidget(app(CustomScrollView(slivers: [
      Obx(() => PeerListSection<String>(
            header: const Text('Address book'),
            expanded: true,
            items: peers.where((name) => name.contains(query.value)).toList(),
            itemBuilder: (_, name) => row(name),
          )),
      const SliverToBoxAdapter(child: Text('Next category')),
    ])));
    expect(find.text('PC 0'), findsOneWidget);
    query.value = '1999';
    await tester.pumpAndSettle();
    expect(find.text('PC 0'), findsNothing);
    expect(find.text('PC 1999'), findsOneWidget);
    expect(find.text('Next category'), findsOneWidget);
    final filteredY = tester.getTopLeft(find.text('PC 1999')).dy;
    expect(filteredY, lessThan(60));
    peers[1999] = 'PC 1999 Offline';
    await tester.pumpAndSettle();
    expect(find.text('PC 1999'), findsNothing);
    expect(find.text('PC 1999 Offline'), findsOneWidget);
    query.value = 'no matches';
    await tester.pumpAndSettle();
    expect(find.byType(PeerListRow), findsNothing);
    expect(find.text('Address book'), findsOneWidget);
    expect(find.text('Next category'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });
}
