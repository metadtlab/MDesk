import 'dart:async';

/// Shares an in-flight refresh only within the exact login generation and
/// account-server boundary. URL validation and credential pinning belong to the
/// caller; this class never normalizes or selects a server.
class SessionRefreshCoordinator<T> {
  final Map<_SessionRefreshKey, Future<T>> _pending = {};

  Future<T> run({
    required int generation,
    required String server,
    required Future<T> Function() request,
  }) {
    final key = _SessionRefreshKey(generation, server);
    final existing = _pending[key];
    if (existing != null) return existing;

    final completion = Completer<T>();
    final future = completion.future;
    _pending[key] = future;
    unawaited(_execute(key, future, completion, request));
    return future;
  }

  Future<void> _execute(
    _SessionRefreshKey key,
    Future<T> ownedFuture,
    Completer<T> completion,
    Future<T> Function() request,
  ) async {
    try {
      completion.complete(await request());
    } catch (error, stackTrace) {
      // Preserve failure for the caller, including synchronously thrown errors,
      // without leaving an additional unobserved failing cleanup future.
      completion.completeError(error, stackTrace);
    } finally {
      // An older generation/server finishing cannot remove another refresh.
      if (identical(_pending[key], ownedFuture)) _pending.remove(key);
    }
  }
}

class _SessionRefreshKey {
  const _SessionRefreshKey(this.generation, this.server);

  final int generation;
  final String server;

  @override
  bool operator ==(Object other) =>
      other is _SessionRefreshKey &&
      generation == other.generation &&
      server == other.server;

  @override
  int get hashCode => Object.hash(generation, server);
}
