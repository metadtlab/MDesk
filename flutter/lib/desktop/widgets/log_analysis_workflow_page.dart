import 'dart:async';
import 'package:flutter/material.dart';
import 'log_analysis_result_window.dart';

/// Selection, progress, errors and the report share the same native window.
class LogAnalysisWorkflowPage extends StatefulWidget {
  final String peerId;
  final Future<Map<String, dynamic>> Function(String action, int? profileId)
      command;
  final Future<void> Function(bool)? onPin;
  final Future<void> Function() onClose;
  final bool initiallyPinned;
  const LogAnalysisWorkflowPage(
      {super.key,
      required this.peerId,
      required this.command,
      required this.onClose,
      this.initiallyPinned = true,
      this.onPin});

  @override
  State<LogAnalysisWorkflowPage> createState() =>
      _LogAnalysisWorkflowPageState();
}

class _LogAnalysisWorkflowPageState extends State<LogAnalysisWorkflowPage> {
  Map<String, dynamic> _state = {'loading': true, 'message': '분석 항목을 불러오는 중…'};
  Timer? _timer;
  bool _requesting = false;
  late bool _pinned = widget.initiallyPinned;
  int? _selected;
  bool _showHistory = false;
  Map<String, dynamic>? _historicalResult;

  @override
  void initState() {
    super.initState();
    unawaited(_send('snapshot'));
  }

  @override
  void dispose() {
    _timer?.cancel();
    super.dispose();
  }

  Future<void> _send(String action) async {
    if (_requesting || !mounted) return;
    _timer?.cancel();
    setState(() => _requesting = true);
    try {
      final next =
          await widget.command(action, action == 'start' ? _selected : null);
      if (!mounted) return;
      final profiles = next['profiles'] as List? ?? [];
      setState(() {
        _state = next;
        if (!profiles.any((p) => p['id'] == _selected)) {
          _selected = profiles.isEmpty ? null : profiles.first['id'] as int;
        }
      });
      if (next['finished'] != true || next['historyLoading'] == true) {
        _timer = Timer(const Duration(seconds: 1), () => _send('snapshot'));
      }
    } catch (_) {
      if (mounted) {
        setState(() => _state = {
              'loading': false,
              'running': false,
              'finished': true,
              'message': '원격 창에 연결할 수 없습니다. 원격 연결을 확인한 후 다시 시도해주세요.'
            });
      }
    } finally {
      if (mounted) setState(() => _requesting = false);
    }
  }

  Future<void> _pin(bool value) async {
    await widget.onPin?.call(value);
    if (mounted) setState(() => _pinned = value);
  }

  @override
  Widget build(BuildContext context) {
    final result = _historicalResult ?? _state['result'];
    if (!_showHistory && result is Map) {
      return LogAnalysisResultPage(
          peerId: widget.peerId,
          result: Map<String, dynamic>.from(result),
          initiallyPinned: _pinned,
          onPin: widget.onPin == null ? null : _pin,
          onHistory: () {
            setState(() => _showHistory = true);
            _send('history');
          },
          onRestart: _requesting || _state['running'] == true
              ? null
              : () {
                  setState(() => _historicalResult = null);
                  _send('reload');
                },
          onClose: widget.onClose);
    }
    final loading = _state['loading'] == true;
    final running = _state['running'] == true;
    final finished = _state['finished'] == true;
    final profiles = _state['profiles'] as List? ?? [];
    final warnings = _state['collectionWarnings'] as List? ?? [];
    final omitted = _state['warningsOmitted'] as int? ?? 0;
    final history = _state['history'] as List? ?? [];
    if (_showHistory) {
      return Scaffold(
          appBar: AppBar(
              title: const Text('최근 결과 5개'),
              leading: IconButton(
                  tooltip: '분석 화면으로',
                  icon: const Icon(Icons.arrow_back),
                  onPressed: () => setState(() {
                        _showHistory = false;
                        _historicalResult = null;
                      })),
              actions: [
                IconButton(
                    tooltip: '최근 결과 새로고침',
                    icon: const Icon(Icons.refresh),
                    onPressed: _requesting || _state['historyLoading'] == true
                        ? null
                        : () => _send('history')),
                IconButton(
                    tooltip: '닫기',
                    icon: const Icon(Icons.close),
                    onPressed: widget.onClose)
              ]),
          body: ListView(padding: const EdgeInsets.all(24), children: [
            Text('원격 ID ${widget.peerId} · 내 계정의 저장된 분석 결과'),
            const SizedBox(height: 16),
            if (_state['historyLoading'] == true)
              const LinearProgressIndicator(),
            if ((_state['historyError'] as String? ?? '').isNotEmpty)
              Text(_state['historyError'] as String),
            if (history.isEmpty && _state['historyLoading'] != true)
              const Padding(
                  padding: EdgeInsets.symmetric(vertical: 24),
                  child: Text('저장된 분석 결과가 없습니다.')),
            for (final row in history.take(5))
              Card(
                  child: ListTile(
                      leading: const Icon(Icons.description_outlined),
                      title: Text('${row['result']['profileName'] ?? '로그 분석'}'),
                      subtitle: Text(_localTime('${row['createdAt']}')),
                      trailing: const Icon(Icons.chevron_right),
                      onTap: () => setState(() {
                            _historicalResult =
                                Map<String, dynamic>.from(row['result']);
                            _showHistory = false;
                          }))),
          ]));
    }
    return Scaffold(
      appBar: AppBar(title: const Text('로그 분석'), actions: [
        IconButton(
            tooltip: '최근 결과 5개',
            icon: const Icon(Icons.history),
            onPressed: () {
              setState(() => _showHistory = true);
              _send('history');
            }),
        if (widget.onPin != null)
          IconButton(
              tooltip: _pinned ? '항상 위 고정 해제' : '항상 위에 표시',
              icon: Icon(_pinned ? Icons.push_pin : Icons.push_pin_outlined),
              onPressed: () async {
                try {
                  await _pin(!_pinned);
                } catch (_) {
                  if (context.mounted) {
                    ScaffoldMessenger.of(context).showSnackBar(
                        const SnackBar(content: Text('창 고정 상태를 변경하지 못했습니다.')));
                  }
                }
              }),
        IconButton(
            tooltip: '닫기',
            icon: const Icon(Icons.close),
            onPressed: widget.onClose),
      ]),
      body: SingleChildScrollView(
          padding: const EdgeInsets.all(24),
          child:
              Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
            Text('원격 ID ${widget.peerId}',
                style: Theme.of(context).textTheme.labelLarge),
            const SizedBox(height: 20),
            Text(_state['message'] as String? ?? '',
                style: const TextStyle(fontSize: 16, height: 1.6)),
            if (loading || running) ...[
              const SizedBox(height: 20),
              const LinearProgressIndicator(),
            ],
            const SizedBox(height: 20),
            if (!loading && !finished && profiles.isNotEmpty) ...[
              DropdownButtonFormField<int>(
                  key: ValueKey(profiles.map((p) => p['id']).join(',')),
                  initialValue: _selected,
                  isExpanded: true,
                  decoration: const InputDecoration(
                      labelText: '분석 항목', border: OutlineInputBorder()),
                  items: profiles
                      .map((p) => DropdownMenuItem<int>(
                          value: p['id'] as int,
                          child: Text(p['name'] as String,
                              overflow: TextOverflow.ellipsis)))
                      .toList(),
                  onChanged: running
                      ? null
                      : (value) => setState(() => _selected = value)),
              const SizedBox(height: 20),
              const Text(
                  '선택한 항목의 파일 로그 또는 Windows 이벤트 로그 일부를 수집해 API 서버에서 분석합니다. '
                  '분석 결과는 서버에 저장되며 최근 결과에서 다시 볼 수 있습니다. '
                  '전송하면 안 되는 정보가 포함되지 않았는지 확인한 후 분석을 시작해주세요.',
                  style: TextStyle(height: 1.6)),
              const SizedBox(height: 20),
              FilledButton.icon(
                  onPressed: running || _requesting || _selected == null
                      ? null
                      : () => _send('start'),
                  icon: const Icon(Icons.analytics_outlined),
                  label: const Text('분석 시작')),
            ],
            if (!loading && !running && (finished || profiles.isEmpty))
              OutlinedButton(
                  onPressed: _requesting ? null : () => _send('reload'),
                  child: const Text('다시 불러오기')),
            if (warnings.isNotEmpty || omitted > 0)
              ExpansionTile(
                  title: Text('수집 제외 사유 (${warnings.length + omitted})'),
                  children: [
                    for (final warning in warnings)
                      ListTile(
                          title: SelectableText('${warning['path']}'),
                          subtitle: Text('${warning['reason']}')),
                    if (omitted > 0) Text('추가 제외 사유 $omitted건 생략'),
                  ]),
            const SizedBox(height: 24),
            Text(
                running
                    ? '분석 중에도 원격 작업을 계속할 수 있습니다. 창을 닫아도 시작한 분석은 계속되며, 로그 분석 버튼으로 다시 열 수 있습니다.'
                    : '원격 화면을 클릭하면 이 창을 열어둔 채 작업할 수 있습니다.',
                style: Theme.of(context)
                    .textTheme
                    .bodySmall
                    ?.copyWith(height: 1.6)),
          ])),
    );
  }

  String _localTime(String value) {
    final date = DateTime.tryParse(value)?.toLocal();
    if (date == null) return value;
    String two(int n) => n.toString().padLeft(2, '0');
    return '${date.year}-${two(date.month)}-${two(date.day)} ${two(date.hour)}:${two(date.minute)}';
  }
}
