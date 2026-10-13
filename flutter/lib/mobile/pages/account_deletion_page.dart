import 'package:flutter/material.dart';
import 'package:url_launcher/url_launcher.dart';

typedef AccountDeletionLinkLauncher = Future<bool> Function(
  Uri uri,
  LaunchMode mode,
);

/// Opens the owner's direct request page; never submits a deletion request or
/// transfers MDesk credentials to the browser. Apple subscriptions are separate.
class AccountDeletionPage extends StatefulWidget {
  const AccountDeletionPage({super.key, this.launcher});

  final AccountDeletionLinkLauncher? launcher;

  @override
  State<AccountDeletionPage> createState() => _AccountDeletionPageState();
}

class _AccountDeletionPageState extends State<AccountDeletionPage> {
  static final _requestUri = Uri.parse('https://admin.787.kr/account-deletion');
  static final _subscriptionsUri =
      Uri.parse('https://apps.apple.com/account/subscriptions');
  static const _openError = '페이지를 열지 못했습니다. 잠시 후 다시 시도해 주세요.';

  bool _opening = false;
  String? _error;

  static Future<bool> _launchExternal(Uri uri, LaunchMode mode) =>
      launchUrl(uri, mode: mode);

  Future<void> _open(Uri uri) async {
    if (_opening || !mounted) return;
    setState(() {
      _opening = true;
      _error = null;
    });
    try {
      final opened = await (widget.launcher ?? _launchExternal)(
        uri,
        LaunchMode.externalApplication,
      );
      if (mounted && !opened) setState(() => _error = _openError);
    } catch (_) {
      // Platform exceptions may contain private details; show fixed text only.
      if (mounted) setState(() => _error = _openError);
    } finally {
      if (mounted) setState(() => _opening = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('계정 삭제 요청')),
      body: SafeArea(
        child: Center(
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 640),
            child: ListView(
              padding: const EdgeInsets.all(20),
              children: [
                const Text(
                  '신청 페이지에서 MDesk 계정으로 본인 확인을 한 뒤 계정 삭제 요청을 제출하세요.',
                ),
                const SizedBox(height: 8),
                const Text(
                  '이 화면에서는 삭제 요청을 자동 제출하지 않습니다. 삭제 대상 및 보관 정보와 처리 절차는 신청 페이지의 안내를 확인하세요.',
                ),
                const SizedBox(height: 16),
                ElevatedButton(
                  key: const ValueKey('account-deletion-open'),
                  onPressed: _opening ? null : () => _open(_requestUri),
                  child: const Text('신청 페이지 열기'),
                ),
                const SizedBox(height: 24),
                const Text(
                  '계정 삭제 후에도 Apple 구독은 자동 취소되지 않습니다. 구독 중이면 Apple 구독 관리에서 별도로 해지하세요.',
                ),
                const SizedBox(height: 12),
                OutlinedButton(
                  key: const ValueKey('account-deletion-manage-subscription'),
                  onPressed: _opening ? null : () => _open(_subscriptionsUri),
                  child: const Text('Apple 구독 관리·해지'),
                ),
                if (_opening) ...[
                  const SizedBox(height: 16),
                  const LinearProgressIndicator(
                    key: ValueKey('account-deletion-opening'),
                  ),
                ],
                if (_error != null) ...[
                  const SizedBox(height: 16),
                  Semantics(
                    liveRegion: true,
                    child: Text(
                      _error!,
                      key: const ValueKey('account-deletion-link-error'),
                      style: TextStyle(
                        color: Theme.of(context).colorScheme.error,
                      ),
                    ),
                  ),
                ],
              ],
            ),
          ),
        ),
      ),
    );
  }
}
