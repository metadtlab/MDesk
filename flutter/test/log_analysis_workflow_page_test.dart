import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_hbb/desktop/widgets/log_analysis_workflow_page.dart';
import 'package:flutter_hbb/desktop/widgets/log_analysis_result_window.dart';

void main() {
  testWidgets(
      'server history opens Markdown without starting analysis or a modal',
      (tester) async {
    var started = 0;
    await tester.pumpWidget(MaterialApp(
        home: LogAnalysisWorkflowPage(
            peerId: '123',
            onClose: () async {},
            command: (action, id) async {
              if (action == 'start') started++;
              return {
                'loading': false,
                'finished': true,
                'profiles': [],
                'history': List.generate(
                    6,
                    (i) => {
                          'id': '$i',
                          'createdAt': '2026-09-21T01:00:00Z',
                          'result': {
                            'profileName': '저장 결과 $i',
                            'summary': '## 과거 분석 $i'
                          }
                        })
              };
            })));
    await tester.pumpAndSettle();
    await tester.tap(find.byTooltip('최근 결과 5개'));
    await tester.pumpAndSettle();
    expect(find.text('저장 결과 4'), findsOneWidget);
    expect(find.text('저장 결과 5'), findsNothing);
    await tester.tap(find.text('저장 결과 0'));
    await tester.pumpAndSettle();
    expect(find.byType(LogAnalysisResultPage), findsOneWidget);
    expect(find.text('과거 분석 0'), findsOneWidget);
    expect(find.byType(AlertDialog), findsNothing);
    expect(started, 0);
    await tester.pumpWidget(const SizedBox());
  });
  testWidgets('selection, progress and report use one page without any dialog',
      (tester) async {
    var started = 0;
    var phase = 'ready';
    await tester.pumpWidget(MaterialApp(
        home: LogAnalysisWorkflowPage(
      peerId: '123',
      onClose: () async {},
      command: (action, profileId) async {
        if (action == 'reload') phase = 'ready';
        if (action == 'start') {
          expect(profileId, 7);
          started++;
          phase = 'running';
        }
        return {
          'aiProvider': 'glm',
          'loading': false,
          'running': phase == 'running',
          'finished': phase == 'done',
          'message': phase == 'running' ? '분석 중' : '항목 선택',
          'profiles': [
            {'id': 7, 'name': 'DB 로그'}
          ],
          if (phase == 'done') 'result': {'summary': '## 완료\n\n분석 결과'}
        };
      },
    )));
    await tester.pumpAndSettle();
    expect(find.byType(AlertDialog), findsNothing);
    expect(find.text('DB 로그'), findsOneWidget);
    expect(find.textContaining('API 서버에서 분석합니다'), findsOneWidget);
    expect(find.textContaining('GLM'), findsNothing);
    expect(find.textContaining('OpenAI'), findsNothing);
    expect(find.textContaining('Z.ai'), findsNothing);
    await tester.tap(find.text('분석 시작'));
    await tester.pump();
    expect(find.text('분석 중'), findsOneWidget);
    expect(find.byType(AlertDialog), findsNothing);
    expect(started, 1);
    phase = 'done';
    await tester.pump(const Duration(seconds: 1));
    await tester.pumpAndSettle();
    expect(find.byType(LogAnalysisResultPage), findsOneWidget);
    expect(find.byType(AlertDialog), findsNothing);
    expect(started, 1);
    await tester.tap(find.byTooltip('새 분석'));
    await tester.pumpAndSettle();
    expect(find.byType(LogAnalysisResultPage), findsNothing);
    expect(find.text('DB 로그'), findsOneWidget);
    expect(started, 1);
    expect(find.byType(AlertDialog), findsNothing);
    await tester.pumpWidget(const SizedBox());
  });
}
