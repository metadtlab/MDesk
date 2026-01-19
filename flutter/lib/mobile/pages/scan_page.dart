import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/foundation.dart' show kIsWeb;

import '../../common.dart';
import '../../models/platform_model.dart';
import '../widgets/dialog.dart';

// Conditional imports for non-web platforms
import 'scan_page_native.dart' if (dart.library.html) 'scan_page_web.dart'
    as scan_impl;

class ScanPage extends StatelessWidget {
  @override
  Widget build(BuildContext context) {
    return scan_impl.ScanPageImpl();
  }
}
