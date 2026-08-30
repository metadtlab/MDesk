const int mdeskUpdateGraceDays = 10;

/// Returns the local midnight immediately after the 10th grace day.
///
/// For example, a release at any time on August 19 is enforced at
/// August 30 00:00 in the device's local time zone.
DateTime calculateMDeskAutomaticUpdateAt(
  DateTime releasedAt, {
  int graceDays = mdeskUpdateGraceDays,
}) {
  final localRelease = releasedAt.toLocal();
  return DateTime(
    localRelease.year,
    localRelease.month,
    localRelease.day + graceDays + 1,
  );
}

bool isMDeskAutomaticUpdateDue(
  DateTime updateAt, {
  DateTime? now,
}) {
  return !(now ?? DateTime.now()).isBefore(updateAt);
}
