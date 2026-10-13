import 'dart:convert';

import '../consts.dart';

/// Change incoming access without installing/uninstalling the OS service.
/// The single-option stop-service API also manages the installed service and
/// restarts the app; the bulk API only updates its live configuration.
Future<void> setRemoteSupportEnabled({
  required bool enabled,
  required Future<String> Function() readOptions,
  required Future<void> Function(String) writeOptions,
}) async {
  final options = Map<String, dynamic>.from(jsonDecode(await readOptions()));
  // An explicit N also overrides custom clients whose default is stopped.
  options[kOptionStopService] = enabled ? 'N' : 'Y';
  await writeOptions(jsonEncode(options));
}
