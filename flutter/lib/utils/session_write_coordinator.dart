/// Serializes credential writes in FIFO order. Account-generation guards belong
/// inside each operation so queued stale writes can be rejected before touching
/// storage. Errors remain visible to their caller but do not poison the queue.
class SessionWriteCoordinator {
  Future<void> _tail = Future<void>.value();

  Future<void> run(Future<void> Function() write) {
    final operation = _tail.then<void>((_) => write());
    // Keep a successful scheduling tail even when this operation throws, without
    // changing the result or stack trace of the caller's own operation future.
    _tail = operation.then<void>(
      (_) {},
      onError: (Object _, StackTrace __) {},
    );
    return operation;
  }
}
