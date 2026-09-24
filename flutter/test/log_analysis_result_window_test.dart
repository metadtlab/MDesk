import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_markdown/flutter_markdown.dart';
import 'package:flutter_hbb/desktop/widgets/log_analysis_result_window.dart';

void main() {
  testWidgets(
      'report renders Markdown, supports pin/copy/close and narrow widths',
      (tester) async {
    tester.view.physicalSize = const Size(600, 680);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    bool? pinned;
    var closed = false;
    String? copied;
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(SystemChannels.platform, (call) async {
      if (call.method == 'Clipboard.setData') copied = call.arguments['text'];
      return null;
    });
    addTearDown(() => TestDefaultBinaryMessengerBinding
        .instance.defaultBinaryMessenger
        .setMockMethodCallHandler(SystemChannels.platform, null));
    const markdown = '## 요약\n\n**DB 연결 실패**가 확인됐습니다.\n\n'
        '## 로그 근거\n\n```text\n2026-09-20 데이터베이스 연결 실패\n```\n\n'
        '## 확인 순서\n\n1. DB 상태를 확인하세요.\n2. 네트워크를 확인하세요.\n\n'
        '![외부 이미지](https://example.invalid/pixel.png)';
    await tester.pumpWidget(MaterialApp(
        home: LogAnalysisResultPage(
      peerId: '123456789',
      result: const {
        'summary': markdown,
        'notice': '일부 로그만 분석했습니다.',
        'collectionWarnings': [
          {'path': r'C:\missing.log', 'reason': '파일 없음'}
        ]
      },
      onPin: (value) async {
        pinned = value;
      },
      onClose: () async {
        closed = true;
      },
    )));
    await tester.pumpAndSettle();
    expect(find.byType(MarkdownBody), findsOneWidget);
    expect(find.descendant(of: find.byType(LogAnalysisResultPage),
        matching: find.byType(ModalBarrier)), findsNothing);
    expect(find.byType(Image), findsNothing);
    await tester.tap(find.byTooltip('항상 위 고정 해제'));
    await tester.pumpAndSettle();
    expect(pinned, false);
    expect(find.byTooltip('항상 위에 표시'), findsOneWidget);
    await tester.tap(find.text('Markdown 복사'));
    await tester.pumpAndSettle();
    expect(copied, contains(markdown));
    expect(copied, contains('파일 없음'));
    tester.view.physicalSize = const Size(340, 480);
    await tester.pumpAndSettle();
    await tester.tap(find.byTooltip('글자 크게'));
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
    await tester.tap(find.byTooltip('닫기'));
    expect(closed, true);
  });
}
