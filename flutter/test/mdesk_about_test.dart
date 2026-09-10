import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_hbb/desktop/widgets/mdesk_about.dart';
import 'package:flutter_test/flutter_test.dart';

const _captureKey = ValueKey('about-capture');
const _sourceUrl = 'https://github.com/metadtlab/MDesk';

Widget _app({
  Brightness brightness = Brightness.light,
  double textScale = 1,
  AssetBundle? bundle,
  String version = '1.5.9',
}) {
  return DefaultAssetBundle(
    bundle: bundle ?? rootBundle,
    child: MaterialApp(
      theme: ThemeData(
        brightness: brightness,
        fontFamily: 'NanumSquareNeo',
        useMaterial3: false,
        colorScheme: ColorScheme.fromSeed(
          seedColor: const Color(0xFF2c8cff),
          brightness: brightness,
        ),
      ),
      builder: (context, child) => MediaQuery(
        data: MediaQuery.of(context)
            .copyWith(textScaler: TextScaler.linear(textScale)),
        child: child!,
      ),
      home: RepaintBoundary(
        key: _captureKey,
        child: Scaffold(
          body: SingleChildScrollView(
            padding: const EdgeInsets.all(16),
            child: Align(
              alignment: Alignment.topLeft,
              child: ConstrainedBox(
                constraints: const BoxConstraints(maxWidth: 640),
                child: MDeskAbout(
                  version: version,
                  buildDate: '2026-09-08 23:57',
                  fingerprint: List.filled(16, 'abcd').join(' '),
                ),
              ),
            ),
          ),
        ),
      ),
    ),
  );
}

Future<void> _capture(WidgetTester tester, String name) async {
  final directory = Platform.environment['MDESK_ABOUT_CAPTURE_DIR'];
  if (directory == null) return;
  final boundary =
      tester.renderObject<RenderRepaintBoundary>(find.byKey(_captureKey));
  await tester.runAsync(() async {
    final image = await boundary.toImage();
    final bytes = await image.toByteData(format: ui.ImageByteFormat.png);
    await Directory(directory).create(recursive: true);
    await File('$directory/$name.png')
        .writeAsBytes(bytes!.buffer.asUint8List());
    image.dispose();
  });
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const channel = MethodChannel('plugins.flutter.io/url_launcher');
  final calls = <MethodCall>[];

  setUpAll(() async {
    final font = FontLoader('NanumSquareNeo')
      ..addFont(rootBundle.load('assets/NanumSquareNeo-Regular.ttf'));
    await font.load();
    final icons = FontLoader('MaterialIcons')
      ..addFont(rootBundle.load('fonts/MaterialIcons-Regular.otf'));
    await icons.load();
  });

  setUp(() {
    calls.clear();
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (call) async {
      calls.add(call);
      return true;
    });
  });

  tearDown(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, null);
  });

  test('bundled AGPL is an unchanged copy of the canonical license', () {
    expect(File(mdeskAgplAsset).readAsBytesSync(),
        File('../LICENCE').readAsBytesSync());
  });

  for (final brightness in Brightness.values) {
    for (final width in [340.0, 640.0, 1000.0]) {
      testWidgets('About fits $width px in ${brightness.name}', (tester) async {
        await tester.binding.setSurfaceSize(Size(width, 900));
        addTearDown(() => tester.binding.setSurfaceSize(null));
        await tester.pumpWidget(_app(brightness: brightness));
        await tester.pumpAndSettle();
        expect(find.text('MDesk 1.5.9'), findsOneWidget);
        expect(find.textContaining('1.4.0'), findsNothing);
        expect(find.textContaining('Rust 1.75.0'), findsNothing);
        expect(find.textContaining('complete corresponding'), findsNothing);
        expect(tester.takeException(), isNull);
        await _capture(tester, 'about-${brightness.name}-${width.toInt()}');
        await tester.ensureVisible(find.text('개인정보 보호정책'));
        await tester.pumpAndSettle();
        expect(tester.takeException(), isNull);
        expect(find.text('개인정보 보호정책').hitTestable(), findsOneWidget);
      });
    }
  }

  testWidgets('large text and license dialog fit a narrow window',
      (tester) async {
    await tester.binding.setSurfaceSize(const Size(340, 740));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await tester.pumpWidget(_app(textScale: 2));
    await tester.pumpAndSettle();
    await tester.ensureVisible(find.text('AGPL-3.0 원문'));
    await tester.tap(find.text('AGPL-3.0 원문'));
    await tester.pumpAndSettle();
    expect(find.byType(Dialog), findsOneWidget);
    expect(find.textContaining('END OF TERMS AND CONDITIONS'), findsOneWidget);
    expect(tester.takeException(), isNull);
    await tester.tap(find.byTooltip('닫기'));
    await tester.pumpAndSettle();
    expect(find.byType(Dialog), findsNothing);
    expect(find.byType(MDeskAbout), findsOneWidget);
    expect(calls, isEmpty);
  });

  testWidgets('source and API links use the correct external URLs',
      (tester) async {
    await tester.pumpWidget(_app());
    await tester.pumpAndSettle();
    await tester.ensureVisible(find.text('소스 코드'));
    await tester.tap(find.text('소스 코드'));
    await tester.pumpAndSettle();
    expect(calls.last.arguments['url'], _sourceUrl);
    expect(calls.last.arguments['useWebView'], false);
    await tester.ensureVisible(find.byTooltip('MDesk API Server 열기'));
    await tester.tap(find.byTooltip('MDesk API Server 열기'));
    await tester.pumpAndSettle();
    expect(calls.last.arguments['url'],
        'https://github.com/metadtlab/MDeskAPIServer');
    expect(tester.takeException(), isNull);
  });

  testWidgets('browser failure displays a copyable fallback', (tester) async {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (_) async => false);
    await tester.pumpWidget(_app());
    await tester.pumpAndSettle();
    await tester.ensureVisible(find.text('소스 코드'));
    await tester.tap(find.text('소스 코드'));
    await tester.pumpAndSettle();
    expect(find.textContaining('브라우저를 열지 못했습니다.'), findsOneWidget);
    expect(find.text('주소 복사'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('missing license asset can be retried', (tester) async {
    await tester.pumpWidget(_app(bundle: _RetryBundle()));
    await tester.pumpAndSettle();
    await tester.ensureVisible(find.text('AGPL-3.0 원문'));
    await tester.tap(find.text('AGPL-3.0 원문'));
    await tester.pumpAndSettle();
    expect(find.text('라이선스 원문을 불러오지 못했습니다.'), findsOneWidget);
    await tester.tap(find.text('다시 시도'));
    await tester.pumpAndSettle();
    expect(find.text('Recovered AGPL license'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('component notices open separately and return to About',
      (tester) async {
    await tester.pumpWidget(_app());
    await tester.pumpAndSettle();
    await tester.ensureVisible(find.text('구성 요소 라이선스'));
    await tester.tap(find.text('구성 요소 라이선스'));
    await tester.pumpAndSettle();
    expect(find.byType(LicensePage), findsOneWidget);
    await tester.pageBack();
    await tester.pumpAndSettle();
    expect(find.byType(MDeskAbout), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('unknown version is not replaced with a hard-coded version',
      (tester) async {
    await tester.pumpWidget(_app(version: ''));
    await tester.pumpAndSettle();
    expect(find.text('MDesk 확인할 수 없음'), findsOneWidget);
  });
}

class _RetryBundle extends CachingAssetBundle {
  bool failedOnce = false;

  @override
  Future<ByteData> load(String key) => rootBundle.load(key);

  @override
  Future<String> loadString(String key, {bool cache = true}) async {
    if (key != mdeskAgplAsset) return rootBundle.loadString(key);
    if (!failedOnce) {
      failedOnce = true;
      throw StateError('Missing test asset');
    }
    return 'Recovered AGPL license';
  }
}
