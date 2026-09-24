import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:desktop_multi_window/desktop_multi_window.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_markdown/flutter_markdown.dart';
import 'log_analysis_workflow_page.dart';

const logAnalysisResultWindowType = 'log_analysis_result';
const _updateResult = 'logAnalysisResult.update';
const _pinChannel = MethodChannel('mdesk/log_analysis_window');
final _resultWindows = <String, int>{};

/// Results travel only through in-process window messages, never launch args,
/// files, URLs, or logs. No access/collection/API token is passed to this viewer.
Future<void> showLogAnalysisResultWindow(
    String peerId, Map<String, dynamic> result,
    {int? ownerWindowId,
    bool workflow = false,
    void Function(int)? onWindowReady}) async {
  final payload = jsonEncode({
    'peerId': peerId,
    'result': result,
    'workflow': workflow,
    'ownerWindowId': ownerWindowId,
    'revision': DateTime.now().microsecondsSinceEpoch
  });
  final previous = _resultWindows[peerId];
  if (previous != null) {
    try {
      onWindowReady?.call(previous);
      if (await DesktopMultiWindow.invokeMethod(
                  previous, _updateResult, payload)
              .timeout(const Duration(seconds: 2)) ==
          true) {
        final window = WindowController.fromWindowId(previous);
        await window.show();
        await window.focus();
        return;
      }
    } catch (_) {
      // A closed native window may already have destroyed its engine.
    }
    _resultWindows.remove(peerId);
  }

  final window = await DesktopMultiWindow.createWindow(
      jsonEncode({'type': logAnalysisResultWindowType}));
  try {
    onWindowReady?.call(window.windowId);
    await window.setTitle('MDesk · 로그 분석');
    await window.showTitleBar(true);
    Rect frame = const Rect.fromLTWH(80, 80, 600, 680);
    if (ownerWindowId != null) {
      final owner =
          await WindowController.fromWindowId(ownerWindowId).getFrame();
      if (owner.width > 320 && owner.height > 320) {
        final width = (owner.width - 48).clamp(320.0, 600.0);
        final height = (owner.height - 96).clamp(280.0, 680.0);
        frame = Rect.fromLTWH(
            owner.right - width - 24, owner.top + 48, width, height);
      }
    }
    await window.setFrame(frame);
    // createWindow returns before the new Dart engine installs its handler.
    final deadline = DateTime.now().add(const Duration(seconds: 10));
    while (true) {
      try {
        if (await DesktopMultiWindow.invokeMethod(
                    window.windowId, _updateResult, payload)
                .timeout(const Duration(seconds: 1)) ==
            true) {
          break;
        }
      } on PlatformException {
        // Wait for the viewer engine to be ready.
      } on MissingPluginException {
        // Wait for the viewer engine to be ready.
      } on TimeoutException {
        // A slow starting engine must not block the remote window indefinitely.
      }
      if (DateTime.now().isAfter(deadline)) {
        throw TimeoutException('결과 창을 열지 못했습니다. 다시 시도해주세요.');
      }
      await Future<void>.delayed(const Duration(milliseconds: 100));
    }
    _resultWindows[peerId] = window.windowId;
    await window.show();
    await window.focus();
  } catch (_) {
    await window.close();
    rethrow;
  }
}

Future<void> runLogAnalysisResultWindow(int windowId) async {
  final data = ValueNotifier<Map<String, dynamic>>({});
  var pinned = true;
  Future<void> setPinned(bool value) async {
    await _pinChannel.invokeMethod<void>('setAlwaysOnTop', value);
    pinned = value;
  }

  if (Platform.isWindows) {
    await _pinChannel.invokeMethod<void>('setAlwaysOnTop', true);
  }
  runApp(MaterialApp(
    debugShowCheckedModeBanner: false,
    title: 'MDesk · 로그 분석 결과',
    locale: const Locale('ko'),
    supportedLocales: const [Locale('ko'), Locale('en')],
    localizationsDelegates: GlobalMaterialLocalizations.delegates,
    theme:
        ThemeData(useMaterial3: true, colorSchemeSeed: const Color(0xff2563eb)),
    darkTheme: ThemeData(
        useMaterial3: true,
        brightness: Brightness.dark,
        colorSchemeSeed: const Color(0xff2563eb)),
    home: ValueListenableBuilder<Map<String, dynamic>>(
      valueListenable: data,
      builder: (context, value, _) => value['workflow'] == true
          ? LogAnalysisWorkflowPage(
              key: ValueKey(value['revision']),
              peerId: value['peerId'] as String,
              initiallyPinned: pinned,
              command: (action, profileId) async {
                final response = await DesktopMultiWindow.invokeMethod(
                    value['ownerWindowId'] as int,
                    'logAnalysis.command',
                    jsonEncode({
                      'peerId': value['peerId'],
                      'action': action,
                      if (profileId != null) 'profileId': profileId
                    })).timeout(const Duration(seconds: 5));
                return Map<String, dynamic>.from(response as Map);
              },
              onPin: Platform.isWindows ? setPinned : null,
              onClose: () => WindowController.fromWindowId(windowId).close(),
            )
          : LogAnalysisResultPage(
              peerId: value['peerId'] as String? ?? '',
              initiallyPinned: pinned,
              result: Map<String, dynamic>.from(value['result'] as Map? ?? {}),
              onPin: Platform.isWindows ? setPinned : null,
              onClose: () => WindowController.fromWindowId(windowId).close(),
            ),
    ),
  ));
  DesktopMultiWindow.setMethodHandler((call, fromWindowId) async {
    if (call.method != _updateResult) return null;
    data.value =
        Map<String, dynamic>.from(jsonDecode(call.arguments as String));
    return true;
  });
}

class LogAnalysisResultPage extends StatefulWidget {
  final String peerId;
  final Map<String, dynamic> result;
  final Future<void> Function(bool)? onPin;
  final Future<void> Function() onClose;
  final bool initiallyPinned;
  final VoidCallback? onRestart;
  final VoidCallback? onHistory;

  const LogAnalysisResultPage(
      {super.key,
      required this.peerId,
      required this.result,
      required this.onClose,
      this.initiallyPinned = true,
      this.onRestart,
      this.onHistory,
      this.onPin});

  @override
  State<LogAnalysisResultPage> createState() => _LogAnalysisResultPageState();
}

class _LogAnalysisResultPageState extends State<LogAnalysisResultPage> {
  late bool _pinned = widget.initiallyPinned;
  double _fontSize = 15;
  final _scroll = ScrollController();

  @override
  void didUpdateWidget(covariant LogAnalysisResultPage oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.result['summary'] != widget.result['summary'] &&
        _scroll.hasClients) {
      _scroll.jumpTo(0);
    }
  }

  @override
  void dispose() {
    _scroll.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final result = widget.result;
    final summary = result['summary'] as String? ?? '';
    final notice = result['notice'] as String? ?? '';
    final warnings = result['collectionWarnings'] as List? ?? [];
    final omitted = result['warningsOmitted'] as int? ?? 0;
    return Scaffold(
      appBar: AppBar(
        title: const Text('로그 분석 결과',
            style: TextStyle(fontSize: 20, fontWeight: FontWeight.bold)),
        actions: [
          if (widget.onHistory != null)
            IconButton(
                tooltip: '최근 결과 5개',
                onPressed: widget.onHistory,
                icon: const Icon(Icons.history)),
          if (widget.onRestart != null)
            IconButton(
                tooltip: '새 분석',
                onPressed: widget.onRestart,
                icon: const Icon(Icons.refresh)),
          if (widget.onPin != null)
            IconButton(
              tooltip: _pinned ? '항상 위 고정 해제' : '항상 위에 표시',
              icon: Icon(_pinned ? Icons.push_pin : Icons.push_pin_outlined),
              onPressed: () async {
                try {
                  await widget.onPin!(!_pinned);
                  if (mounted) setState(() => _pinned = !_pinned);
                } catch (_) {
                  if (context.mounted) {
                    ScaffoldMessenger.of(context).showSnackBar(
                        const SnackBar(content: Text('창 고정 상태를 변경하지 못했습니다.')));
                  }
                }
              },
            ),
          IconButton(
              tooltip: '닫기',
              onPressed: widget.onClose,
              icon: const Icon(Icons.close)),
        ],
      ),
      body: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        Padding(
            padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 8),
            child: Text(
                '${result['profileName'] ?? '로그 분석'} · 원격 ID ${widget.peerId}',
                style: theme.textTheme.labelLarge)),
        Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16),
            child: Wrap(
              crossAxisAlignment: WrapCrossAlignment.center,
              spacing: 4,
              children: [
                TextButton.icon(
                    icon: const Icon(Icons.copy, size: 18),
                    label: const Text('Markdown 복사'),
                    onPressed: summary.isEmpty
                        ? null
                        : () async {
                            final details = warnings
                                .map((w) => '${w['path']}: ${w['reason']}')
                                .join('\n');
                            await Clipboard.setData(ClipboardData(
                                text: [
                              summary,
                              notice,
                              details,
                              if (omitted > 0) '추가 제외 사유 $omitted건 생략'
                            ].where((s) => s.isNotEmpty).join('\n\n')));
                            if (context.mounted) {
                              ScaffoldMessenger.of(context).showSnackBar(
                                  const SnackBar(
                                      content: Text('분석 결과를 복사했습니다.')));
                            }
                          }),
                IconButton(
                    tooltip: '글자 작게',
                    onPressed: _fontSize <= 13
                        ? null
                        : () => setState(() => _fontSize--),
                    icon: const Icon(Icons.text_decrease)),
                IconButton(
                    tooltip: '글자 크게',
                    onPressed: _fontSize >= 22
                        ? null
                        : () => setState(() => _fontSize++),
                    icon: const Icon(Icons.text_increase)),
                Text('원격 화면을 클릭하면 작업을 계속할 수 있습니다.',
                    style: theme.textTheme.bodySmall),
              ],
            )),
        const Divider(height: 1),
        Expanded(
            child: Scrollbar(
          controller: _scroll,
          thumbVisibility: true,
          child: SingleChildScrollView(
            controller: _scroll,
            padding: const EdgeInsets.all(24),
            child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  if (result['storageWarning'] is String)
                    Padding(
                        padding: const EdgeInsets.only(bottom: 16),
                        child: Text(result['storageWarning'] as String,
                            style: TextStyle(
                                color: theme.colorScheme.error,
                                fontWeight: FontWeight.bold))),
                  MarkdownBody(
                    data: summary,
                    selectable: true,
                    // Never fetch model-generated image URLs or activate links.
                    sizedImageBuilder: (config) => Text(config.alt ?? '이미지 생략'),
                    onTapLink: (text, href, title) {},
                    styleSheet: MarkdownStyleSheet.fromTheme(theme).copyWith(
                      p: theme.textTheme.bodyMedium
                          ?.copyWith(fontSize: _fontSize, height: 1.7),
                      h2: theme.textTheme.titleLarge?.copyWith(
                          fontSize: _fontSize + 5,
                          height: 1.5,
                          fontWeight: FontWeight.bold),
                      h2Padding: const EdgeInsets.only(top: 20, bottom: 8),
                      listBullet: TextStyle(fontSize: _fontSize, height: 1.7),
                      blockSpacing: 14,
                      code: TextStyle(
                          fontFamily: 'monospace',
                          fontSize: _fontSize - 1,
                          height: 1.6),
                      codeblockPadding: const EdgeInsets.all(16),
                      codeblockDecoration: BoxDecoration(
                          color: theme.colorScheme.surfaceContainerHighest,
                          borderRadius: BorderRadius.circular(8)),
                    ),
                  ),
                  if (notice.isNotEmpty) ...[
                    const SizedBox(height: 24),
                    Container(
                        padding: const EdgeInsets.all(16),
                        decoration: BoxDecoration(
                            color: theme.colorScheme.surfaceContainerHighest,
                            borderRadius: BorderRadius.circular(8)),
                        child: Text(notice,
                            style: theme.textTheme.bodySmall
                                ?.copyWith(height: 1.6))),
                  ],
                  if (warnings.isNotEmpty || omitted > 0)
                    ExpansionTile(
                      tilePadding: EdgeInsets.zero,
                      title: Text('수집 제외 사유 (${warnings.length + omitted})'),
                      children: [
                        for (final warning in warnings)
                          ListTile(
                            title: SelectableText('${warning['path']}'),
                            subtitle: Text('${warning['reason']}'),
                          ),
                        if (omitted > 0)
                          Text('추가 제외 사유 $omitted건은 표시를 생략했습니다.'),
                      ],
                    ),
                ]),
          ),
        )),
      ]),
    );
  }
}
