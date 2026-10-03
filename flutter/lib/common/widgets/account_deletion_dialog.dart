import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:url_launcher/url_launcher.dart';

const accountDeletionEmail = 'metadtlab@gmail.com';
const accountDeletionPrivacyPolicyUrl =
    'https://www.mdesk.co.kr/privacy-policy.html';

typedef AccountDeletionTranslate = String Function(String text);
typedef AccountDeletionLauncher = Future<bool> Function(Uri uri);
typedef AccountDeletionClipboard = Future<void> Function(String text);

String _defaultTranslate(String text) => text;

Future<bool> _defaultLauncher(Uri uri) =>
    launchUrl(uri, mode: LaunchMode.externalApplication);

Future<void> _defaultClipboard(String text) =>
    Clipboard.setData(ClipboardData(text: text));

/// Creates a draft only. No account credentials or request are sent by the app.
Uri buildAccountDeletionRequestUri({
  String? accountName,
  AccountDeletionTranslate? translate,
}) {
  final text = translate ?? _defaultTranslate;
  final name = accountName?.replaceAll(RegExp(r'[\x00-\x1f\x7f]'), ' ').trim();
  final body = [
    text('Please delete my MDesk account and its associated personal data.'),
    if (name != null && name.isNotEmpty) '${text('Account name:')} $name',
    '',
    text(
        'Please let me know how to verify account ownership and complete this deletion request.'),
    '',
    text('Do not include passwords, verification codes, or access tokens.'),
  ].join('\n');

  // Non-HTTP handlers may interpret the '+' produced by queryParameters
  // literally. Percent-encode each field so spaces and non-ASCII names survive.
  final query = {
    'subject': text('MDesk account deletion request'),
    'body': body,
  }.entries.map((entry) {
    return '${Uri.encodeComponent(entry.key)}=${Uri.encodeComponent(entry.value)}';
  }).join('&');
  return Uri(scheme: 'mailto', path: accountDeletionEmail, query: query);
}

Future<void> showAccountDeletionDialog(
  BuildContext context, {
  String? accountName,
  AccountDeletionTranslate? translate,
  AccountDeletionLauncher? launcher,
  AccountDeletionClipboard? copyToClipboard,
}) async {
  await showDialog<void>(
    context: context,
    builder: (_) => AccountDeletionDialog(
      accountName: accountName,
      translate: translate,
      launcher: launcher,
      copyToClipboard: copyToClipboard,
    ),
  );
}

/// A user-initiated email request, with a copyable address if launching fails.
class AccountDeletionDialog extends StatefulWidget {
  const AccountDeletionDialog({
    super.key,
    this.accountName,
    this.translate,
    this.launcher,
    this.copyToClipboard,
  });

  final String? accountName;
  final AccountDeletionTranslate? translate;
  final AccountDeletionLauncher? launcher;
  final AccountDeletionClipboard? copyToClipboard;

  @override
  State<AccountDeletionDialog> createState() => _AccountDeletionDialogState();
}

class _AccountDeletionDialogState extends State<AccountDeletionDialog> {
  bool _busy = false;
  String? _status;
  bool _showPrivacyPolicyUrl = false;

  String _text(String text) => (widget.translate ?? _defaultTranslate)(text);

  Future<void> _open(Uri uri, String failure,
      {bool privacyPolicy = false}) async {
    setState(() {
      _busy = true;
      _status = null;
      _showPrivacyPolicyUrl = false;
    });
    var opened = false;
    try {
      opened = await (widget.launcher ?? _defaultLauncher)(uri);
    } catch (_) {
      // Missing mail/browser handlers and platform errors use the same fallback.
    }
    if (!mounted) return;
    setState(() {
      _busy = false;
      _status = opened ? null : failure;
      _showPrivacyPolicyUrl = !opened && privacyPolicy;
    });
  }

  Future<void> _copyEmail() async {
    setState(() {
      _busy = true;
      _status = null;
      _showPrivacyPolicyUrl = false;
    });
    var copied = false;
    try {
      await (widget.copyToClipboard ?? _defaultClipboard)(accountDeletionEmail);
      copied = true;
    } catch (_) {
      // The selectable address remains available even without a clipboard.
    }
    if (!mounted) return;
    setState(() {
      _busy = false;
      _status = copied
          ? 'Email address copied.'
          : 'Could not copy the address. Select and copy it manually.';
    });
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      scrollable: true,
      title: Text(_text('Request account deletion')),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(_text(
              'Request deletion of your MDesk account and associated personal data by email.')),
          const SizedBox(height: 12),
          Text(_text(
              'For MetaDataLab MDesk service accounts. For independently hosted or customer-managed accounts, contact your server administrator.')),
          const SizedBox(height: 12),
          Text(_text(
              'Opening the email draft does not send it or delete your account. Send the request from your email app. We may need to verify ownership before processing.')),
          const SizedBox(height: 12),
          Text(_text(
              'Do not include passwords, verification codes, or access tokens.')),
          const SizedBox(height: 16),
          const SelectableText(accountDeletionEmail),
          const SizedBox(height: 8),
          TextButton(
            onPressed: _busy
                ? null
                : () => _open(
                      Uri.parse(accountDeletionPrivacyPolicyUrl),
                      'Could not open the privacy policy. You can view it at:',
                      privacyPolicy: true,
                    ),
            child: Text(_text('Privacy policy')),
          ),
          if (_status != null) ...[
            const SizedBox(height: 8),
            Semantics(liveRegion: true, child: Text(_text(_status!))),
          ],
          if (_showPrivacyPolicyUrl) ...[
            const SizedBox(height: 8),
            const SelectableText(accountDeletionPrivacyPolicyUrl),
          ],
        ],
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: Text(_text('Close')),
        ),
        TextButton(
          onPressed: _busy ? null : _copyEmail,
          child: Text(_text('Copy email address')),
        ),
        ElevatedButton(
          onPressed: _busy
              ? null
              : () => _open(
                    buildAccountDeletionRequestUri(
                      accountName: widget.accountName,
                      translate: widget.translate,
                    ),
                    'No email app could be opened. Copy the email address and send your deletion request manually.',
                  ),
          child: Text(_text('Open deletion request email')),
        ),
      ],
    );
  }
}
