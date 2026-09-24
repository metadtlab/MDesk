import 'dart:async';
import 'dart:convert';
import 'package:flutter/material.dart';
import '../../models/model.dart';
import '../../models/platform_model.dart';
import '../../main.dart' show kWindowId;
import 'log_analysis_result_window.dart';
import 'remote_log_analysis_controller.dart';

final _analyses = <String, RemoteLogAnalysisController>{};
final _viewerIds = <String, int>{};

Future<void> showRemoteLogAnalysis(
    BuildContext context, FFI ffi, String peerId) async {
  try {
    final owner = kWindowId;
    if (owner == null) throw Exception('데스크톱 원격 창에서 분석을 실행해주세요.');
    final controller = _analyses.putIfAbsent(
        peerId,
        () => RemoteLogAnalysisController(
              peerId: peerId,
              apiServer: () => bind.mainGetApiServer(),
              accessToken: () => bind.mainGetLocalOption(key: 'access_token'),
              checkConnection: () {
                if (!ffi.ffiModel.pi.isSet.value) {
                  throw Exception('원격 연결이 필요합니다.');
                }
                if (ffi.ffiModel.pi.platformAdditions['log_analysis_v1'] !=
                    true) {
                  throw Exception(
                      '피원격 PC의 MDesk를 로그 분석 기능이 포함된 버전으로 업데이트해주세요.');
                }
              },
              collect: (message) =>
                  bind.sessionSendChat(sessionId: ffi.sessionId, text: message),
              checkEventConnection: () {
                if (ffi.ffiModel.pi
                        .platformAdditions['log_analysis_events_v1'] !=
                    true) {
                  throw Exception(
                      '피원격 PC의 MDesk를 Windows 이벤트 로그 수집 지원 버전으로 업데이트해주세요.');
                }
              },
            ));
    await showLogAnalysisResultWindow(
      peerId,
      const {},
      ownerWindowId: owner,
      workflow: true,
      onWindowReady: (id) => _viewerIds[peerId] = id,
    );
    unawaited(controller.load());
  } catch (e) {
    if (context.mounted) {
      ScaffoldMessenger.maybeOf(context)?.showSnackBar(SnackBar(
          content: Text(e.toString().replaceFirst('Exception: ', ''))));
    }
  }
}

/// Only the viewer registered for this peer may start work in its owner session.
dynamic handleLogAnalysisCommand(dynamic arguments, int fromWindowId) {
  final command = jsonDecode(arguments as String) as Map<String, dynamic>;
  final peerId = command['peerId'] as String;
  final controller = _analyses[peerId];
  if (controller == null || _viewerIds[peerId] != fromWindowId) {
    return {
      'loading': false,
      'running': false,
      'finished': true,
      'message': '원격 연결이 종료되었습니다. 다시 연결한 후 분석을 열어주세요.',
      'profiles': []
    };
  }
  switch (command['action']) {
    case 'start':
      controller.start(command['profileId'] as int);
      break;
    case 'reload':
      unawaited(controller.load(retry: true));
      break;
    case 'history':
      unawaited(controller.refreshHistory());
      break;
  }
  return controller.snapshot;
}

void disposeRemoteLogAnalysis(String peerId) {
  _analyses.remove(peerId)?.dispose();
  _viewerIds.remove(peerId);
}

void disposeAllRemoteLogAnalyses() {
  for (final controller in _analyses.values) {
    controller.dispose();
  }
  _analyses.clear();
  _viewerIds.clear();
}
