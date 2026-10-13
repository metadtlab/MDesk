import 'package:flutter/services.dart';
import 'package:flutter_hbb/common/account_management.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const channel = MethodChannel('plugins.flutter.io/url_launcher');

  test('account button opens separate browser login with no app credentials',
      () async {
    MethodCall? launched;
    final messenger =
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    messenger.setMockMethodCallHandler(channel, (call) async {
      launched = call;
      return true;
    });
    addTearDown(() => messenger.setMockMethodCallHandler(channel, null));

    await openAccountPasswordChange();

    expect(launched!.method, 'launch');
    final arguments = launched!.arguments as Map;
    final target = Uri.parse(arguments['url'] as String);
    expect(target.scheme, 'https');
    expect(target.host, 'admin.787.kr');
    expect(target.path, '/login');
    expect(target.userInfo, isEmpty);
    expect(target.queryParameters, {'next': '/account?tab=password'});
    expect(arguments['useSafariVC'], isFalse);
    expect(arguments['useWebView'], isFalse);
    expect(arguments['headers'], isEmpty);
  });
}
