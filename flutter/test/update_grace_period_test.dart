import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_hbb/utils/update_grace_period.dart';

void main() {
  test('schedules update at midnight after the tenth grace day', () {
    final releasedAt = DateTime(2026, 8, 19, 15, 30);

    final updateAt = calculateMDeskAutomaticUpdateAt(releasedAt);

    expect(updateAt, DateTime(2026, 8, 30));
  });

  test('handles month boundaries using local calendar days', () {
    final releasedAt = DateTime(2026, 1, 27, 23, 59);

    final updateAt = calculateMDeskAutomaticUpdateAt(releasedAt);

    expect(updateAt, DateTime(2026, 2, 7));
  });

  test('supports an explicit grace period for deterministic checks', () {
    final releasedAt = DateTime(2026, 8, 19);

    final updateAt = calculateMDeskAutomaticUpdateAt(
      releasedAt,
      graceDays: 0,
    );

    expect(updateAt, DateTime(2026, 8, 20));
  });

  test('is due at the deadline or on the next app start', () {
    final deadline = DateTime(2026, 8, 30);

    expect(
      isMDeskAutomaticUpdateDue(
        deadline,
        now: DateTime(2026, 8, 29, 23, 59, 59),
      ),
      isFalse,
    );
    expect(
      isMDeskAutomaticUpdateDue(deadline, now: deadline),
      isTrue,
    );
    expect(
      isMDeskAutomaticUpdateDue(
        deadline,
        now: DateTime(2026, 8, 31, 9),
      ),
      isTrue,
    );
  });
}
