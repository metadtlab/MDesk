import 'package:flutter/material.dart';

import '../../common.dart';

/// Web stub for ScanPage - QR scanning is not supported on web
class ScanPageImpl extends StatelessWidget {
  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Scan QR'),
      ),
      body: Center(
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(
              Icons.qr_code_scanner,
              size: 80,
              color: Colors.grey,
            ),
            SizedBox(height: 20),
            Text(
              translate('QR scanning is not supported on web'),
              style: TextStyle(
                fontSize: 16,
                color: Colors.grey,
              ),
              textAlign: TextAlign.center,
            ),
            SizedBox(height: 10),
            Text(
              translate('Please use mobile app for QR scanning'),
              style: TextStyle(
                fontSize: 14,
                color: Colors.grey[600],
              ),
              textAlign: TextAlign.center,
            ),
          ],
        ),
      ),
    );
  }
}


