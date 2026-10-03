import 'dart:async';
import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_hbb/common/korean_translations.dart';
import 'package:flutter_hbb/common/widgets/account_deletion_dialog.dart';
import 'package:flutter_test/flutter_test.dart';

const _emailFailure =
    'No email app could be opened. Copy the email address and send your deletion request manually.';
const _captureKey = ValueKey('account-deletion-capture');

Future<void> _showDialog(
  WidgetTester tester, {
  String? accountName,
  AccountDeletionTranslate? translate,
  AccountDeletionLauncher? launcher,
  AccountDeletionClipboard? copyToClipboard,
  double textScale = 1,
}) async {
  await tester.pumpWidget(MaterialApp(
    theme: ThemeData(fontFamily: 'NanumSquareNeo', useMaterial3: false),
    builder: (context, child) => MediaQuery(
      data: MediaQuery.of(context)
          .copyWith(textScaler: TextScaler.linear(textScale)),
      child: RepaintBoundary(key: _captureKey, child: child!),
    ),
    home: Scaffold(
      body: Builder(builder: (context) {
        return TextButton(
          onPressed: () => showAccountDeletionDialog(
            context,
            accountName: accountName,
            translate: translate,
            launcher: launcher,
            copyToClipboard: copyToClipboard,
          ),
          child: const Text('Show'),
        );
      }),
    ),
  ));
  await tester.tap(find.text('Show'));
  await tester.pumpAndSettle();
}

Future<void> _capture(WidgetTester tester, String name) async {
  final directory = Platform.environment['MDESK_ACCOUNT_DELETION_CAPTURE_DIR'];
  if (directory == null) return;
  final boundary =
      tester.renderObject<RenderRepaintBoundary>(find.byKey(_captureKey));
  await tester.runAsync(() async {
    final image = await boundary.toImage();
    final bytes = await image.toByteData(format: ui.ImageByteFormat.png);
    await Directory(directory).create(recursive: true);
    await File('$directory/$name.png')
        .writeAsBytes(bytes!.buffer.asUint8List());
    image.dispose();
  });
}

void main() {
  setUpAll(() async {
    final font = FontLoader('NanumSquareNeo')
      ..addFont(rootBundle.load('assets/NanumSquareNeo-Regular.ttf'));
    await font.load();
  });

  test('email draft preserves Korean, spaces and URI punctuation', () {
    const name = '김 & user+test?=#';
    final uri = buildAccountDeletionRequestUri(accountName: name);
    expect(uri.scheme, 'mailto');
    expect(uri.path, accountDeletionEmail);
    expect(uri.queryParameters.keys, unorderedEquals(['subject', 'body']));
    expect(uri.queryParameters['subject'], 'MDesk account deletion request');
    expect(uri.queryParameters['body'], contains('Account name: $name'));
    expect(uri.queryParameters['body'], contains('associated personal data'));
    expect(uri.query, contains('%20'));
    expect(uri.query, isNot(contains(' ')));
    expect(uri.fragment, isEmpty);
  });

  test('draft omits absent account and normalizes control characters', () {
    for (final name in [null, '', '  ']) {
      final uri = buildAccountDeletionRequestUri(accountName: name);
      expect(uri.queryParameters['body'], isNot(contains('Account name:')));
    }
    final uri =
        buildAccountDeletionRequestUri(accountName: 'user\r\nname\u0000');
    expect(uri.queryParameters['body'], contains('Account name: user  name'));
  });

  testWidgets('opening dialog does nothing until explicit email action',
      (tester) async {
    final launched = <Uri>[];
    await _showDialog(tester, accountName: 'review-user',
        launcher: (uri) async {
      launched.add(uri);
      return true;
    });
    expect(launched, isEmpty);
    expect(find.byType(SelectableText), findsOneWidget);
    expect(find.textContaining('does not send it or delete your account'),
        findsOneWidget);
    expect(find.textContaining('Do not include passwords'), findsOneWidget);
    expect(find.textContaining('independently hosted or customer-managed'),
        findsOneWidget);
    await tester.tap(find.text('Open deletion request email'));
    await tester.pumpAndSettle();
    expect(launched, hasLength(1));
    expect(launched.single.scheme, 'mailto');
    expect(launched.single.queryParameters['body'], contains('review-user'));
    expect(find.text(_emailFailure), findsNothing);
  });

  for (final throws in [false, true]) {
    testWidgets(
        'mail failure shows selectable and clipboard fallback ($throws)',
        (tester) async {
      String? copied;
      await _showDialog(tester,
          launcher: (_) async {
            if (throws) throw StateError('No mail handler');
            return false;
          },
          copyToClipboard: (text) async => copied = text);
      await tester.tap(find.text('Open deletion request email'));
      await tester.pumpAndSettle();
      expect(find.text(_emailFailure), findsOneWidget);
      expect(find.widgetWithText(SelectableText, accountDeletionEmail),
          findsOneWidget);
      await tester.tap(find.text('Copy email address'));
      await tester.pumpAndSettle();
      expect(copied, accountDeletionEmail);
      expect(find.text('Email address copied.'), findsOneWidget);
      expect(tester.takeException(), isNull);
    });
  }

  testWidgets('clipboard error leaves manual selection available',
      (tester) async {
    await _showDialog(tester, copyToClipboard: (_) async {
      throw StateError('Clipboard unavailable');
    });
    await tester.tap(find.text('Copy email address'));
    await tester.pumpAndSettle();
    expect(
        find.text('Could not copy the address. Select and copy it manually.'),
        findsOneWidget);
    expect(find.widgetWithText(SelectableText, accountDeletionEmail),
        findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('privacy policy uses existing URL with readable failure fallback',
      (tester) async {
    Uri? launched;
    await _showDialog(tester, launcher: (uri) async {
      launched = uri;
      return false;
    });
    await tester.ensureVisible(find.text('Privacy policy'));
    await tester.tap(find.text('Privacy policy'));
    await tester.pumpAndSettle();
    expect(launched.toString(), accountDeletionPrivacyPolicyUrl);
    expect(find.widgetWithText(SelectableText, accountDeletionPrivacyPolicyUrl),
        findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('dismiss while awaiting launcher does not update disposed state',
      (tester) async {
    final result = Completer<bool>();
    await _showDialog(tester, launcher: (_) => result.future);
    await tester.tap(find.text('Open deletion request email'));
    await tester.pump();
    await tester.tap(find.text('Close'));
    await tester.pumpAndSettle();
    result.complete(false);
    await tester.pumpAndSettle();
    expect(find.byType(AccountDeletionDialog), findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets('narrow phone and large Korean text remain usable',
      (tester) async {
    await tester.binding.setSurfaceSize(const Size(320, 640));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    final launched = <Uri>[];
    await _showDialog(
      tester,
      textScale: 1.8,
      translate: (text) => koreanTranslations[text] ?? text,
      launcher: (uri) async {
        launched.add(uri);
        return true;
      },
    );
    expect(tester.takeException(), isNull);
    await _capture(tester, 'account-deletion-ko-large-text');
    await tester.ensureVisible(find.text('개인정보처리방침'));
    await tester.tap(find.text('개인정보처리방침'));
    await tester.pumpAndSettle();
    expect(launched.single.toString(), accountDeletionPrivacyPolicyUrl);
    await tester.ensureVisible(find.text('삭제 요청 메일 작성'));
    await tester.tap(find.text('삭제 요청 메일 작성'));
    await tester.pumpAndSettle();
    expect(launched.last.scheme, 'mailto');
    expect(tester.takeException(), isNull);
  });

  testWidgets('Korean dialog renders before and after mail launcher failure',
      (tester) async {
    await tester.binding.setSurfaceSize(const Size(390, 844));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await _showDialog(tester,
        translate: (text) => koreanTranslations[text] ?? text,
        launcher: (_) async => false);
    await _capture(tester, 'account-deletion-ko');
    await tester.tap(find.text('삭제 요청 메일 작성'));
    await tester.pumpAndSettle();
    await _capture(tester, 'account-deletion-ko-no-mail');
    expect(find.text(koreanTranslations[_emailFailure]!), findsOneWidget);
    expect(tester.takeException(), isNull);
  });
}
