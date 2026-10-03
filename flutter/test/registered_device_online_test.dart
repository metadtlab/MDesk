import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_hbb/utils/device_register_service.dart';

void main() {
  test('enabled registration does not imply a reachable device', () {
    expect(RegisteredDevice.fromJson({'is_active': true}).isOnline, isFalse);
  });

  test('explicit offline status takes precedence over enabled registration',
      () {
    expect(
      RegisteredDevice.fromJson({'is_active': true, 'is_online': false})
          .isOnline,
      isFalse,
    );
    expect(
      RegisteredDevice.fromJson({'is_active': false, 'is_online': true})
          .isOnline,
      isTrue,
    );
  });

  test('online status supports the API boolean representations', () {
    for (final value in [true, 1, 'true', '1']) {
      expect(RegisteredDevice.fromJson({'is_online': value}).isOnline, isTrue);
    }
    for (final value in [false, 0, 'false', '0', null]) {
      expect(RegisteredDevice.fromJson({'is_online': value}).isOnline, isFalse);
    }
  });
}
