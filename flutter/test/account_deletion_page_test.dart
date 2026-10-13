import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_hbb/mobile/pages/account_deletion_page.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:url_launcher/url_launcher.dart';

const _privateDetail = 'private-token-account-and-password';
const _openError = '페이지를 열지 못했습니다. 잠시 후 다시 시도해 주세요.';

Widget _app(AccountDeletionLinkLauncher launcher, {double textScale = 1}) {
  return MaterialApp(
    builder: (context, child) => MediaQuery(
      data: MediaQuery.of(context)
          .copyWith(textScaler: TextScaler.linear(textScale)),
      child: child!,
    ),
    home: AccountDeletionPage(launcher: launcher),
  );
}

Future<void> _tap(WidgetTester tester, String key) async {
  final button = find.byKey(ValueKey(key));
  if (button.evaluate().isEmpty) {
    await tester.scrollUntilVisible(button, 200, maxScrolls: 30);
  }
  await tester.ensureVisible(button);
  await tester.tap(button);
  await tester.pump();
}

void main() {
  testWidgets('explains direct request and separate Apple cancellation',
      (tester) async {
    var calls = 0;
    await tester.pumpWidget(_app((_, __) async {
      calls++;
      return true;
    }));
    expect(find.text('신청 페이지 열기'), findsOneWidget);
    expect(find.textContaining('본인 확인'), findsOneWidget);
    expect(find.textContaining('자동 제출하지 않습니다'), findsOneWidget);
    expect(find.textContaining('Apple 구독은 자동 취소되지 않습니다'), findsOneWidget);
    expect(calls, 0);
  });

  for (final (key, expectedUrl) in [
    ('account-deletion-open', 'https://admin.787.kr/account-deletion'),
    (
      'account-deletion-manage-subscription',
      'https://apps.apple.com/account/subscriptions',
    ),
  ]) {
    testWidgets('$key opens only the fixed HTTPS URL externally',
        (tester) async {
      final calls = <(Uri, LaunchMode)>[];
      await tester.pumpWidget(_app((uri, mode) async {
        calls.add((uri, mode));
        return true;
      }));
      await _tap(tester, key);
      await tester.pumpAndSettle();
      expect(calls, [(Uri.parse(expectedUrl), LaunchMode.externalApplication)]);
      final uri = calls.single.$1;
      expect(uri.scheme, 'https');
      expect(uri.userInfo, isEmpty);
      expect(uri.hasQuery, isFalse);
      expect(uri.hasFragment, isFalse);
      expect(find.byKey(const ValueKey('account-deletion-link-error')),
          findsNothing);
    });
  }

  testWidgets('launch false shows a fixed safe error and allows retry',
      (tester) async {
    var calls = 0;
    await tester.pumpWidget(_app((_, __) async => ++calls > 1));
    await _tap(tester, 'account-deletion-open');
    await tester.pumpAndSettle();
    expect(find.text(_openError), findsOneWidget);
    await _tap(tester, 'account-deletion-open');
    await tester.pumpAndSettle();
    expect(calls, 2);
    expect(find.text(_openError), findsNothing);
  });

  testWidgets('launch exception never exposes platform private details',
      (tester) async {
    await tester.pumpWidget(_app((_, __) async {
      throw PlatformException(
        code: _privateDetail,
        message: _privateDetail,
        details: {'credentials': _privateDetail},
      );
    }));
    await _tap(tester, 'account-deletion-open');
    await tester.pumpAndSettle();
    expect(find.text(_openError), findsOneWidget);
    expect(find.textContaining(_privateDetail), findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets('repeated taps share one pending launch and disable both links',
      (tester) async {
    final result = Completer<bool>();
    var calls = 0;
    await tester.pumpWidget(_app((_, __) {
      calls++;
      return result.future;
    }));
    final button = find.byKey(const ValueKey('account-deletion-open'));
    await tester.ensureVisible(button);
    await tester.tap(button);
    await tester.tap(button);
    await tester.pump();
    expect(calls, 1);
    expect(tester.widget<ElevatedButton>(button).onPressed, isNull);
    expect(
      tester
          .widget<OutlinedButton>(find
              .byKey(const ValueKey('account-deletion-manage-subscription')))
          .onPressed,
      isNull,
    );
    result.complete(true);
    await tester.pumpAndSettle();
    expect(tester.widget<ElevatedButton>(button).onPressed, isNotNull);
  });

  for (final throwOnCompletion in [false, true]) {
    testWidgets('disposed page ignores late launch result ($throwOnCompletion)',
        (tester) async {
      final result = Completer<bool>();
      await tester.pumpWidget(_app((_, __) => result.future));
      await _tap(tester, 'account-deletion-open');
      await tester.pumpWidget(const MaterialApp(home: SizedBox()));
      if (throwOnCompletion) {
        result.completeError(StateError(_privateDetail));
      } else {
        result.complete(false);
      }
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
      expect(find.text(_openError), findsNothing);
    });
  }

  testWidgets('large text remains scrollable without layout errors',
      (tester) async {
    await tester.pumpWidget(_app((_, __) async => true, textScale: 2));
    await _tap(tester, 'account-deletion-manage-subscription');
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
  });
}
