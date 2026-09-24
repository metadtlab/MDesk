import 'dart:async';

import 'package:desktop_multi_window/desktop_multi_window.dart';
import 'package:flutter/services.dart';

const paneDragProbe = 'mdesk.paneDrag.probe';
const paneDragDrop = 'mdesk.paneDrag.drop';
const paneDragClear = 'mdesk.paneDrag.clear';
const paneDragValidate = 'mdesk.paneDrag.validate';
const paneDragSupported = 'mdesk.paneDrag.supported';

/// Contains identifiers only. Passwords and cached session data never travel
/// through drag broadcasts; the destination uses the existing monitor API.
class RemoteWindowDragOffer {
  const RemoteWindowDragOffer({
    required this.token,
    required this.peerId,
    required this.display,
    required this.sessionId,
    required this.paneOnly,
  });

  final String token;
  final String peerId;
  final int display;
  final String sessionId;
  final bool paneOnly;

  Map<String, dynamic> toMap() => {
        'token': token,
        'peer': peerId,
        'display': display,
        'session': sessionId,
        'paneOnly': paneOnly,
      };

  static RemoteWindowDragOffer? fromMap(dynamic value) {
    if (value is! Map ||
        value['token'] is! String ||
        value['peer'] is! String ||
        value['display'] is! int ||
        value['session'] is! String ||
        value['paneOnly'] is! bool ||
        (value['display'] as int) < 0) {
      return null;
    }
    return RemoteWindowDragOffer(
        token: value['token'],
        peerId: value['peer'],
        display: value['display'],
        sessionId: value['session'],
        paneOnly: value['paneOnly']);
  }
}

/// Coordinates are physical desktop pixels until converted by the destination
/// view. WindowFromPoint prevents dropping through an overlapping window.
class RemoteWindowDragPlatform {
  static const channel = MethodChannel('mdesk/pane_drag');

  Future<Offset?> cursor() async {
    final value = await channel.invokeMapMethod<String, num>('cursor');
    return value == null
        ? null
        : Offset(value['x']!.toDouble(), value['y']!.toDouble());
  }

  Future<Offset?> hitTest(Offset point, double devicePixelRatio) async {
    final value = await channel.invokeMapMethod<String, num>(
        'hitTest', {'x': point.dx.round(), 'y': point.dy.round()});
    return value == null
        ? null
        : Offset(value['x']!.toDouble(), value['y']!.toDouble()) /
            devicePixelRatio;
  }

  Future<List<int>> windows() => DesktopMultiWindow.getAllSubWindowIds();

  Future<dynamic> call(int window, String method, dynamic args) =>
      DesktopMultiWindow.invokeMethod(window, method, args);
}

/// Flutter drags keep pointer capture in the source engine. Probe other engines
/// while dragging, then acknowledge a ready destination before removing source.
class RemoteWindowDragController {
  RemoteWindowDragController({
    required this.windowId,
    required this.createOffer,
    required this.isValid,
    required this.onMoved,
    required this.onFailure,
    RemoteWindowDragPlatform? platform,
  }) : platform = platform ?? RemoteWindowDragPlatform();

  final int windowId;
  final RemoteWindowDragOffer? Function(String, int?) createOffer;
  final bool Function(RemoteWindowDragOffer) isValid;
  final void Function(RemoteWindowDragOffer) onMoved;
  final VoidCallback onFailure;
  final RemoteWindowDragPlatform platform;
  RemoteWindowDragOffer? _offer;
  List<int> _windows = [];
  Timer? _timer;
  Future<void>? _probe;
  bool _ending = false;
  bool _cancelled = false;
  bool _disposed = false;

  bool validates(dynamic args) {
    final offer = RemoteWindowDragOffer.fromMap(args);
    return !_disposed &&
        !_cancelled &&
        offer != null &&
        _offer?.token == offer.token &&
        _offer?.peerId == offer.peerId &&
        _offer?.display == offer.display &&
        _offer?.sessionId == offer.sessionId &&
        _offer?.paneOnly == offer.paneOnly &&
        isValid(offer);
  }

  void start(String peerId, int? display) {
    if (_disposed || _offer != null) return;
    final offer = createOffer(peerId, display);
    if (offer == null) return;
    _offer = offer;
    _ending = false;
    _cancelled = false;
    HardwareKeyboard.instance.addHandler(_key);
    _timer = Timer.periodic(const Duration(milliseconds: 70), (_) => _tick());
    _probe = _discover();
  }

  Future<void> _discover() async {
    try {
      final ids = (await platform.windows()).where((id) => id != windowId);
      final supported = await Future.wait(ids.map((id) async {
        try {
          return await platform
                      .call(id, paneDragSupported, null)
                      .timeout(const Duration(milliseconds: 500)) ==
                  true
              ? id
              : null;
        } catch (_) {
          return null;
        }
      }));
      _windows = supported.whereType<int>().toList();
    } catch (_) {
      _windows = [];
    }
  }

  bool _key(KeyEvent event) {
    if (event.logicalKey != LogicalKeyboardKey.escape) return false;
    cancel();
    return true;
  }

  void cancel() {
    _cancelled = true;
    _timer?.cancel();
  }

  void _tick() {
    if (_ending || _cancelled || _disposed) return;
    // Serialize probes so a delayed hover cannot reappear after clear/drop.
    if (_probe != null) {
      final pending = _probe;
      pending!.whenComplete(() {
        if (identical(_probe, pending)) _probe = null;
      });
      return;
    }
    _probe = _probeWindows().then((_) {});
  }

  Future<Map<int, int>> _probeWindows([Offset? screenPoint]) async {
    final offer = _offer;
    if (offer == null || _cancelled || _disposed || !isValid(offer)) return {};
    Offset? point;
    try {
      point = screenPoint ?? await platform.cursor();
    } catch (_) {
      return {};
    }
    if (point == null || _cancelled || _disposed) return {};
    final args = {...offer.toMap(), 'x': point.dx, 'y': point.dy};
    final hits = <int, int>{};
    await Future.wait(_windows.map((id) async {
      try {
        final slot = await platform
            .call(id, paneDragProbe, args)
            .timeout(const Duration(milliseconds: 500));
        if (slot is int && slot >= 0) hits[id] = slot;
      } catch (_) {
        // Closed/non-viewer windows simply do not accept pane drags.
      }
    }));
    return hits;
  }

  Future<void> finish({required bool acceptedLocally}) async {
    if (_offer == null || _ending) return;
    _ending = true;
    _timer?.cancel();
    try {
      // Capture the release point before waiting for an outstanding hover IPC.
      // Subsequent mouse movement must not change which pane receives the drop.
      final point = acceptedLocally || _cancelled || _disposed
          ? null
          : await platform.cursor();
      await _probe;
      if (acceptedLocally || _cancelled || _disposed || point == null) return;
      final hits = await _probeWindows(point);
      if (hits.length != 1 || _cancelled || _disposed) return;
      final offer = _offer!;
      if (!isValid(offer)) return;
      final destination = hits.entries.single;
      final accepted = await platform.call(destination.key, paneDragDrop, {
        ...offer.toMap(),
        'slot': destination.value
      }).timeout(const Duration(seconds: 15));
      if (accepted == true && !_disposed && isValid(offer)) {
        onMoved(offer);
      } else if (!_disposed && !_cancelled) {
        onFailure();
      }
    } catch (_) {
      if (!_disposed && !_cancelled) onFailure();
    } finally {
      final token = _offer?.token;
      await Future.wait(_windows.map((id) async {
        try {
          await platform
              .call(id, paneDragClear, token)
              .timeout(const Duration(milliseconds: 500));
        } catch (_) {}
      }));
      HardwareKeyboard.instance.removeHandler(_key);
      _offer = null;
      _probe = null;
      _ending = false;
    }
  }

  void dispose() {
    _disposed = true;
    cancel();
    HardwareKeyboard.instance.removeHandler(_key);
    unawaited(finish(acceptedLocally: true));
  }
}

/// The source stays untouched on rejection, timeout, or a closed destination.
/// Revalidate after readiness so a stale drag cannot move a reconnected peer.
Future<bool> receiveRemoteWindowPane({
  required Future<bool> Function() validateSource,
  required bool Function() reserve,
  required Future<bool> Function() waitUntilReady,
  required VoidCallback rollback,
}) async {
  var reserved = false;
  var committed = false;
  try {
    if (!await validateSource()) return false;
    reserved = reserve();
    if (!reserved) return false;
    if (!await waitUntilReady() || !await validateSource()) return false;
    committed = true;
    return true;
  } catch (_) {
    return false;
  } finally {
    if (reserved && !committed) rollback();
  }
}
