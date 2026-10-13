import 'dart:io';

import 'package:flutter/semantics.dart';
import 'package:flutter/widgets.dart';

const windowsStartupCompatibilityVariable = 'MDESK_WINDOWS_STARTUP_COMPAT';

bool windowsStartupCompatibilityEnabled({
  required bool isWindows,
  required Map<String, String> environment,
}) =>
    isWindows && environment[windowsStartupCompatibilityVariable] != '0';

/// Temporary default workaround for Flutter's Windows AXNode parent crash.
/// https://github.com/flutter/flutter/issues/175041
///
/// Installed shortcuts and service-launched windows need the same protection.
/// Set MDESK_WINDOWS_STARTUP_COMPAT=0 to restore screen-reader support explicitly.
/// Suppress semantics before the first frame, including later platform requests.
/// Ordinary rendering and input remain active, but screen readers cannot inspect
/// this application's controls while compatibility mode is enabled.
mixin StartupSemanticsCompatibility on SemanticsBinding {
  bool get suppressNativeSemantics;

  @override
  bool get semanticsEnabled =>
      !suppressNativeSemantics && super.semanticsEnabled;
}

class MDeskWidgetsFlutterBinding extends WidgetsFlutterBinding
    with StartupSemanticsCompatibility {
  MDeskWidgetsFlutterBinding()
      : suppressNativeSemantics = windowsStartupCompatibilityEnabled(
          isWindows: Platform.isWindows,
          environment: Platform.environment,
        );

  @override
  final bool suppressNativeSemantics;
}
