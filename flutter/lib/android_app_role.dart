const String kAndroidAppRoleHost = 'host';
const String kAndroidAppRoleRemote = 'remote';
const String kAndroidAppRoleCombined = 'combined';
const String kAndroidAppRoleFromEnvironment = String.fromEnvironment(
    'ANDROID_APP_ROLE',
    defaultValue: kAndroidAppRoleCombined);

String androidAppRole =
    _normalizeAndroidAppRole(kAndroidAppRoleFromEnvironment);

bool get isAndroidHostApp => androidAppRole == kAndroidAppRoleHost;
bool get isAndroidRemoteApp => androidAppRole == kAndroidAppRoleRemote;

void setAndroidAppRole(String? role) {
  androidAppRole = _normalizeAndroidAppRole(role);
}

String _normalizeAndroidAppRole(String? role) {
  switch (role) {
    case kAndroidAppRoleHost:
    case kAndroidAppRoleRemote:
      return role!;
    default:
      return kAndroidAppRoleCombined;
  }
}

String get androidAppRoleConfigToken {
  switch (androidAppRole) {
    case kAndroidAppRoleHost:
      return 'android-app-role=host';
    case kAndroidAppRoleRemote:
      return 'android-app-role=remote';
    default:
      return '';
  }
}
