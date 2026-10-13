import 'package:url_launcher/url_launcher.dart';

import '../common.dart';

/// Opens a separate website login without forwarding the application's token.
final accountPasswordLoginUrl = Uri.https('admin.787.kr', '/login', {
  'next': '/account?tab=password',
});

Future<void> openAccountPasswordChange() async {
  try {
    if (await launchUrl(accountPasswordLoginUrl,
        mode: LaunchMode.externalApplication)) {
      return;
    }
  } catch (_) {}
  showToast('브라우저를 열지 못했습니다. admin.787.kr에서 암호 변경을 이용해 주세요.');
}
