import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:url_launcher/url_launcher_string.dart';

const mdeskAgplAsset = 'assets/AGPL-3.0.txt';
const _sourceUrl = 'https://github.com/metadtlab/MDesk';
const _copyright = 'Copyright © 2025 MetaDataLab.\n'
    'Portions Copyright © Purslane Ltd.\n'
    '기타 기여자의 저작권과 라이선스 고지는 유지됩니다.';

class MDeskAbout extends StatelessWidget {
  const MDeskAbout({
    super.key,
    required this.version,
    required this.buildDate,
    this.fingerprint,
  });

  final String version;
  final String buildDate;
  final String? fingerprint;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final bodyStyle = theme.textTheme.bodyMedium?.copyWith(height: 1.5);
    return DefaultTextStyle.merge(
      style: bodyStyle,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text('MDesk 정보', style: theme.textTheme.titleLarge),
          const SizedBox(height: 16),
          SelectableText('MDesk ${_valueOrUnknown(version)}',
              style: theme.textTheme.titleMedium),
          const SizedBox(height: 8),
          SelectableText('빌드 날짜: ${_valueOrUnknown(buildDate)}'),
          if (fingerprint != null) ...[
            const SizedBox(height: 12),
            Text('지문', style: theme.textTheme.labelLarge),
            SelectableText(_valueOrUnknown(fingerprint!)),
          ],
          const Padding(
            padding: EdgeInsets.symmetric(vertical: 16),
            child: Divider(height: 1),
          ),
          Text('오픈소스 라이선스', style: theme.textTheme.titleMedium),
          const SizedBox(height: 8),
          const SelectionArea(
            child: Text('MDesk는 RustDesk를 기반으로 수정한 원격지원 프로그램입니다.\n'
                'RustDesk 기반 저작물에는 GNU Affero General Public License v3 '
                '(AGPLv3)가 적용됩니다.'),
          ),
          const SizedBox(height: 12),
          const SelectionArea(child: Text(_copyright)),
          const SizedBox(height: 12),
          const SelectionArea(
            child: Text('라이선스 조건에 따라 이용·복사·수정·재배포할 수 있습니다. '
                '법률이나 별도 약정에서 요구하는 경우를 제외하고 보증 없이 제공됩니다.'),
          ),
          const SizedBox(height: 16),
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: [
              OutlinedButton.icon(
                onPressed: () => _openExternal(context, _sourceUrl),
                icon: const Icon(Icons.code, size: 18),
                label: const Text('소스 코드'),
              ),
              OutlinedButton.icon(
                onPressed: () => showDialog<void>(
                  context: context,
                  builder: (_) => const _AgplDialog(),
                ),
                icon: const Icon(Icons.description_outlined, size: 18),
                label: const Text('AGPL-3.0 원문'),
              ),
              TextButton.icon(
                onPressed: () => showLicensePage(
                  context: context,
                  applicationName: 'MDesk',
                  applicationVersion: version,
                  applicationLegalese: '$_copyright\n\n'
                      'Flutter에 등록된 구성 요소의 고지입니다. '
                      '네이티브 의존성 전체 목록을 대신하지 않습니다.',
                ),
                icon: const Icon(Icons.library_books_outlined, size: 18),
                label: const Text('구성 요소 라이선스'),
              ),
            ],
          ),
          const Padding(
            padding: EdgeInsets.symmetric(vertical: 16),
            child: Divider(height: 1),
          ),
          Text('소스 제공 안내', style: theme.textTheme.titleMedium),
          const SizedBox(height: 8),
          const SelectionArea(
            child: Text('공개 저장소에는 개발 중인 코드가 포함됩니다. '
                '이 실행 파일과 정확히 대응하는 소스 버전은 아직 확인되지 않았습니다. '
                '소스 제공 상태와 빌드 방법은 저장소의 안내를 확인하십시오.'),
          ),
          const SizedBox(height: 12),
          const _SourceLink(label: 'MDesk · MDeskMini 소스', url: _sourceUrl),
          const _SourceLink(
            label: '빌드·실행 및 소스 제공 안내',
            url: '$_sourceUrl#readme',
          ),
          const _SourceLink(
            label: '원본 RustDesk 프로젝트',
            url: 'https://github.com/rustdesk/rustdesk',
          ),
          const SizedBox(height: 12),
          Text('관련 프로젝트', style: theme.textTheme.titleMedium),
          const _SourceLink(
            label: 'MDesk API Server',
            url: 'https://github.com/metadtlab/MDeskAPIServer',
          ),
          const Text('API 서버 저장소는 이 클라이언트의 대응 소스를 대신하지 않습니다.'),
          const SizedBox(height: 16),
          TextButton.icon(
            onPressed: () => _openExternal(
                context, 'https://www.mdesk.co.kr/#privacy-policy'),
            icon: const Icon(Icons.privacy_tip_outlined, size: 18),
            label: const Text('개인정보 보호정책'),
          ),
        ],
      ),
    );
  }

  String _valueOrUnknown(String value) =>
      value.trim().isEmpty ? '확인할 수 없음' : value;
}

Future<void> _openExternal(BuildContext context, String url) async {
  try {
    if (await launchUrlString(url, mode: LaunchMode.externalApplication)) {
      return;
    }
  } catch (_) {
    // Keep a failed browser launch from interrupting the settings page.
  }
  if (!context.mounted) return;
  ScaffoldMessenger.of(context).showSnackBar(SnackBar(
    content: Text('브라우저를 열지 못했습니다. $url'),
    action: SnackBarAction(
      label: '주소 복사',
      onPressed: () => Clipboard.setData(ClipboardData(text: url)),
    ),
  ));
}

class _SourceLink extends StatelessWidget {
  const _SourceLink({required this.label, required this.url});

  final String label;
  final String url;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 8),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(label, style: Theme.of(context).textTheme.labelLarge),
                SelectableText(url),
              ],
            ),
          ),
          IconButton(
            tooltip: '$label 열기',
            onPressed: () => _openExternal(context, url),
            icon: const Icon(Icons.open_in_new, size: 20),
          ),
        ],
      ),
    );
  }
}

class _AgplDialog extends StatefulWidget {
  const _AgplDialog();

  @override
  State<_AgplDialog> createState() => _AgplDialogState();
}

class _AgplDialogState extends State<_AgplDialog> {
  final _scrollController = ScrollController();
  late Future<String> _license;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _license = DefaultAssetBundle.of(context).loadString(mdeskAgplAsset);
  }

  @override
  void dispose() {
    _scrollController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Dialog(
      insetPadding: const EdgeInsets.all(16),
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
      child: SizedBox(
        width: 760,
        height: MediaQuery.sizeOf(context).height * 0.8,
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: Column(
            children: [
              Row(children: [
                Expanded(
                  child: Text('GNU AGPL v3.0',
                      style: Theme.of(context).textTheme.titleLarge),
                ),
                IconButton(
                  tooltip: '닫기',
                  onPressed: () => Navigator.of(context).pop(),
                  icon: const Icon(Icons.close),
                ),
              ]),
              const Divider(),
              Expanded(
                child: FutureBuilder<String>(
                  future: _license,
                  builder: (context, snapshot) {
                    if (snapshot.hasError) {
                      return Center(
                        child: Column(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            const Text('라이선스 원문을 불러오지 못했습니다.'),
                            TextButton.icon(
                              onPressed: () => setState(() {
                                _license = DefaultAssetBundle.of(context)
                                    .loadString(mdeskAgplAsset);
                              }),
                              icon: const Icon(Icons.refresh),
                              label: const Text('다시 시도'),
                            ),
                          ],
                        ),
                      );
                    }
                    if (!snapshot.hasData) {
                      return const Center(child: CircularProgressIndicator());
                    }
                    return Scrollbar(
                      controller: _scrollController,
                      thumbVisibility: true,
                      child: SingleChildScrollView(
                        controller: _scrollController,
                        padding: const EdgeInsets.only(right: 16),
                        child: SelectionArea(
                          child: Text(snapshot.data!,
                              style: Theme.of(context)
                                  .textTheme
                                  .bodyMedium
                                  ?.copyWith(height: 1.5)),
                        ),
                      ),
                    );
                  },
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
