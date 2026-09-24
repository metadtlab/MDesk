import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_hbb/models/file_model.dart';

void main() {
  test('DeviceRemote job is tracked but excluded from download progress panel',
      () {
    final jobs = JobController(() => throw UnimplementedError(), () => null);
    final entry = Entry()
      ..path = r'C:\tools\DeviceRemote.exe'
      ..name = 'DeviceRemote.exe'
      ..entryType = 4
      ..size = 123;
    jobs.addTransferJob(entry, false, isDeviceRemote: true);
    final tool = jobs.jobTable.single;
    expect(tool.isDeviceRemote, true);
    expect(tool.isRemoteDropDownload || tool.isDirectDownload, false);
    expect(tool.state, JobState.inProgress);
    jobs.addTransferJob(entry, false, isRemoteDropDownload: true);
    expect(jobs.jobTable.last.isRemoteDropDownload, true);
    expect(jobs.jobTable.last.isDeviceRemote, false);
    expect(kDeviceRemoteTarget, 'mdesk-device-remote:DeviceRemote.exe');
    expect(remoteDropDownloadsPath(['DeviceRemote.exe']),
        'mdesk-drop-downloads:DeviceRemote.exe');
    tool.clear();
    expect(tool.isDeviceRemote, false);
  });
}
