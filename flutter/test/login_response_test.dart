import 'package:flutter_hbb/common/hbbs/hbbs.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('parses access and refresh session credentials', () {
    final response = LoginResponse.fromJson({
      'access_token': 'access-token',
      'refresh_token': 'refresh-token',
      'expires_in': 7200,
      'session_expires_in': 604800,
      'type': 'access_token',
    });

    expect(response.access_token, 'access-token');
    expect(response.refresh_token, 'refresh-token');
    expect(response.expires_in, 7200);
    expect(response.session_expires_in, 604800);
    expect(response.type, 'access_token');
  });

  test('normalizes numeric expiry values to integers', () {
    final response = LoginResponse.fromJson({
      'expires_in': 7199.9,
      'session_expires_in': 604799.1,
    });

    expect(response.expires_in, 7199);
    expect(response.session_expires_in, 604799);
  });
}
