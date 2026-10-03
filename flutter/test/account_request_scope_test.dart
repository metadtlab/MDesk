import 'dart:async';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_hbb/models/account_request_scope.dart';

void main() {
  test('switching accounts invalidates loaded data and pending responses',
      () async {
    final scope = AccountRequestScope();
    scope.update('imedix', '7');
    final oldRequest = scope.generation;
    final response = Completer<List<String>>();
    var rows = <String>[];
    final pending = response.future.then((result) {
      if (scope.accepts(oldRequest, 'canonerp', '8')) rows = result;
    });
    expect(scope.update('canonerp', '8'), isTrue);
    final newRequest = scope.generation;
    rows = ['canonerp-peer'];
    response.complete(['imedix-peer']);
    await pending;
    expect(rows, ['canonerp-peer']);
    expect(scope.accepts(newRequest, 'canonerp', '8'), isTrue);
  });

  test('logout and login to the same account still reject the old request', () {
    final scope = AccountRequestScope()..update('imedix', '7');
    final request = scope.generation;
    scope.update('', '');
    expect(scope.accepts(scope.generation, '', ''), isFalse);
    scope.update('imedix', '7');
    expect(scope.accepts(request, 'imedix', '7'), isFalse);
  });

  test('a changed live user rejects a response before listeners run', () {
    final scope = AccountRequestScope()..update('imedix', '7');
    expect(scope.accepts(scope.generation, 'canonerp', '8'), isFalse);
    expect(scope.accepts(scope.generation, 'imedix', '8'), isFalse);
  });

  test('ordinary refresh of the same identity keeps current work valid', () {
    final scope = AccountRequestScope()..update('imedix', '7');
    final request = scope.generation;
    expect(scope.update('imedix', '7'), isFalse);
    expect(scope.accepts(request, 'imedix', '7'), isTrue);
  });
}
