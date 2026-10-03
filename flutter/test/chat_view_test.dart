import 'dart:io';
import 'dart:ui' as ui;

import 'package:dash_chat_2/dash_chat_2.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_hbb/common/widgets/chat_view.dart';

void main() {
  final me = ChatUser(id: 'local-user-uuid', firstName: '나');
  final peer = ChatUser(id: '123 456 789', firstName: '지원 담당자');
  late TextEditingController controller;
  late FocusNode focus;

  setUp(() {
    controller = TextEditingController();
    focus = FocusNode();
  });
  tearDown(() {
    controller.dispose();
    focus.dispose();
  });

  Widget chat(List<ChatMessage> messages,
          {bool readOnly = false, ValueChanged<ChatMessage>? onSend}) =>
      MDeskChatView(
        currentUser: me,
        messages: messages,
        onSend: onSend ?? (_) {},
        textController: controller,
        focusNode: focus,
        inputHint: '메시지 쓰기',
        sendLabel: '보내기',
        disconnectedLabel: '연결 끊김',
        latestLabel: '최신 메시지',
        readOnly: readOnly,
      );

  Widget app(Widget child,
          {double width = 320, double height = 460, double textScale = 1}) =>
      MaterialApp(
        locale: const Locale('ko'),
        supportedLocales: const [Locale('ko')],
        localizationsDelegates: GlobalMaterialLocalizations.delegates,
        theme: ThemeData(fontFamily: 'ChatPreview'),
        home: Scaffold(
          body: Center(
            child: SizedBox(
              width: width,
              height: height,
              child: Builder(
                  builder: (context) => MediaQuery(
                        data: MediaQuery.of(context)
                            .copyWith(textScaler: TextScaler.linear(textScale)),
                        child: SelectionArea(child: child),
                      )),
            ),
          ),
        ),
      );

  testWidgets('UUID sender aligns outgoing right and times outside each bubble',
      (tester) async {
    final sent = ChatMessage(
        user: me, text: '보낸 메시지', createdAt: DateTime(2026, 10, 1, 11, 4));
    final received = ChatMessage(
        user: peer, text: '받은 메시지', createdAt: DateTime(2026, 10, 1, 11, 3));
    await tester.pumpWidget(app(chat([sent, received])));
    await tester.pumpAndSettle();
    final sentRect = tester.getRect(find.text(sent.text));
    final receivedRect = tester.getRect(find.text(received.text));
    final sentTime = tester.getRect(find.text('오전 11:04'));
    final receivedTime = tester.getRect(find.text('오전 11:03'));
    expect(sentRect.center.dx, greaterThan(receivedRect.center.dx));
    expect(sentTime.right, lessThan(sentRect.left));
    expect(receivedTime.left, greaterThan(receivedRect.right));
    expect(find.text('지원 담당자'), findsOneWidget);
    expect(find.byType(CircleAvatar), findsNothing);
    expect(find.text('2026년 10월 1일 목요일'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('narrow chat wraps long messages and large text without overflow',
      (tester) async {
    await tester.pumpWidget(app(
        chat([
          ChatMessage(
              user: me,
              text: 'A' * 180,
              createdAt: DateTime(2026, 10, 1, 11, 4)),
          ChatMessage(
              user: peer,
              text: '긴 메시지와 여러 줄을 작은 창에서도 확인합니다.\n두 번째 줄입니다.',
              createdAt: DateTime(2026, 10, 1, 11, 3)),
        ]),
        width: 250,
        textScale: 1.4));
    await tester.pumpAndSettle();
    expect(tester.getSize(find.text('A' * 180)).width, lessThan(170));
    expect(tester.takeException(), isNull);
  });

  testWidgets('send button follows controller, sends once and clears the draft',
      (tester) async {
    final sent = <ChatMessage>[];
    await tester.pumpWidget(app(chat([], onSend: sent.add)));
    await tester.pumpAndSettle();
    expect(
        tester.widget<TextButton>(find.byType(TextButton)).onPressed, isNull);
    controller.text = '   ';
    await tester.pump();
    expect(
        tester.widget<TextButton>(find.byType(TextButton)).onPressed, isNull);
    await tester.enterText(find.byType(TextField), '전송 확인');
    await tester.pump();
    await tester.tap(find.byType(TextButton));
    await tester.pump();
    expect(sent, hasLength(1));
    expect(sent.single.text, '전송 확인');
    expect(sent.single.user.id, me.id);
    expect(controller.text, isEmpty);
    expect(
        tester.widget<TextButton>(find.byType(TextButton)).onPressed, isNull);
    expect(tester.takeException(), isNull);
  });

  testWidgets('disconnected chat retains history and removes the composer',
      (tester) async {
    await tester.pumpWidget(app(chat([
      ChatMessage(user: peer, text: '이전 대화', createdAt: DateTime(2026, 10, 1)),
    ], readOnly: true)));
    await tester.pumpAndSettle();
    expect(find.text('이전 대화'), findsOneWidget);
    expect(find.text('연결 끊김'), findsOneWidget);
    expect(find.byType(TextField), findsNothing);
    expect(find.byType(TextButton), findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets('history groups same sender and separates calendar dates',
      (tester) async {
    await tester.pumpWidget(app(chat([
      ChatMessage(
          user: peer, text: '다음 날', createdAt: DateTime(2026, 10, 2, 9, 0)),
      ChatMessage(
          user: peer, text: '연속 답변', createdAt: DateTime(2026, 10, 1, 11, 3)),
      ChatMessage(
          user: peer, text: '첫 답변', createdAt: DateTime(2026, 10, 1, 11, 2)),
    ])));
    await tester.pumpAndSettle();
    expect(find.text('지원 담당자'), findsNWidgets(2));
    expect(find.text('2026년 10월 1일 목요일'), findsOneWidget);
    expect(find.text('2026년 10월 2일 금요일'), findsOneWidget);
    expect(tester.getTopLeft(find.text('첫 답변')).dy,
        lessThan(tester.getTopLeft(find.text('연속 답변')).dy));
    expect(tester.takeException(), isNull);
  });

  testWidgets('latest follows new messages but preserves reading older history',
      (tester) async {
    final messages = List.generate(
        35,
        (i) => ChatMessage(
            user: peer,
            text: 'message ${34 - i}',
            createdAt: DateTime(2026, 10, 1, 11, 34 - i)));
    late StateSetter update;
    await tester.pumpWidget(app(StatefulBuilder(builder: (context, setState) {
      update = setState;
      return chat(messages);
    })));
    await tester.pumpAndSettle();
    final listRect = tester.getRect(find.byType(ListView));
    expect(tester.getRect(find.text('message 34')).overlaps(listRect), isTrue);
    update(() => messages.insert(
        0,
        ChatMessage(
            user: me,
            text: 'latest\nwith extra lines\nthree\nfour\nfive',
            createdAt: DateTime(2026, 10, 1, 12))));
    await tester.pumpAndSettle();
    expect(tester.getRect(find.text(messages.first.text)).overlaps(listRect),
        isTrue);
    await tester.drag(find.byType(ListView), const Offset(0, 320));
    await tester.pumpAndSettle();
    final list = tester.widget<ListView>(find.byType(ListView));
    final before = list.controller!.offset;
    update(() => messages.insert(
        0,
        ChatMessage(
            user: peer,
            text: 'new while reading',
            createdAt: DateTime(2026, 10, 1, 12, 1))));
    await tester.pumpAndSettle();
    expect(list.controller!.offset, closeTo(before, 1));
    await tester.tap(find.byTooltip('최신 메시지'));
    await tester.pumpAndSettle();
    expect(tester.getRect(find.text('new while reading')).overlaps(listRect),
        isTrue);
    expect(tester.takeException(), isNull);
  });

  testWidgets('desktop popup and connection panel fit without overflow',
      (tester) async {
    // Set MDESK_CHAT_PREVIEW_DIR to export actual Flutter renders on demand.
    final previewDirectory = Platform.environment['MDESK_CHAT_PREVIEW_DIR'];
    if (previewDirectory != null) {
      if (Platform.isWindows &&
          File('C:/Windows/Fonts/malgun.ttf').existsSync()) {
        final loader = FontLoader('ChatPreview')
          ..addFont(Future.value(ByteData.sublistView(
              File('C:/Windows/Fonts/malgun.ttf').readAsBytesSync())));
        await loader.load();
      }
      final iconFont = FontLoader('MaterialIcons')
        ..addFont(rootBundle.load('fonts/MaterialIcons-Regular.otf'));
      await iconFont.load();
    }
    final messages = [
      ChatMessage(
          user: me, text: '감사합니다!', createdAt: DateTime(2026, 10, 1, 11, 4)),
      ChatMessage(
          user: peer,
          text: '설정이 완료됐습니다.\n다시 확인해 주세요.',
          createdAt: DateTime(2026, 10, 1, 11, 4)),
      ChatMessage(
          user: me,
          text: '네, 확인 부탁드려요.',
          createdAt: DateTime(2026, 10, 1, 11, 3)),
      ChatMessage(
          user: peer,
          text: '원격 지원을 시작할게요.',
          createdAt: DateTime(2026, 10, 1, 11, 2)),
    ];
    final boundaryKey = GlobalKey();
    controller.text = '네, 확인해 볼게요.';
    for (final size in [const Size(320, 460), const Size(400, 600)]) {
      await tester.pumpWidget(app(
          RepaintBoundary(
              key: boundaryKey,
              child: ClipRRect(
                borderRadius: BorderRadius.circular(12),
                child: Column(children: [
                  const MDeskChatHeader(
                      title: '지원 담당자',
                      subtitle: '123 456 789',
                      trailing: Icon(Icons.close,
                          color: MDeskChatColors.text, size: 18)),
                  Expanded(child: chat(messages)),
                ]),
              )),
          width: size.width,
          height: size.height));
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
      if (previewDirectory == null) continue;
      await tester.runAsync(() async {
        final boundary = boundaryKey.currentContext!.findRenderObject()
            as RenderRepaintBoundary;
        final image = await boundary.toImage(pixelRatio: 2);
        final bytes = await image.toByteData(format: ui.ImageByteFormat.png);
        final directory = Directory(previewDirectory);
        await directory.create(recursive: true);
        await File('${directory.path}/chat-${size.width.toInt()}.png')
            .writeAsBytes(bytes!.buffer.asUint8List());
        image.dispose();
      });
    }
  });
}
