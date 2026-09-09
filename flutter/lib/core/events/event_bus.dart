import 'dart:async';
import 'dart:collection';

import 'agent_events.dart';

/// Broadcast bus for [MissionEvent]s.
///
/// Multicast: every listener receives every event independently. New
/// subscribers are first replayed the most recent [replayBufferSize]
/// events (those passing their filter) before receiving live ones.
///
/// Guarantees:
/// - A throwing listener (or a throwing filter) never breaks other
///   listeners nor the bus: delivery happens inside a guarded tap and
///   the error is swallowed (and optionally surfaced through
///   [onListenerError]).
/// - [publish] after [dispose] is a safe no-op.
///
/// Delivery is synchronous: [publish] dispatches to listeners within the
/// same tick, and replay happens inside [subscribe]'s `listen`, so no
/// event can slip between the replay snapshot and the live subscription.
/// The bus owns no clock and no async machinery — it only forwards what
/// it is given, in order.
class AgentEventBus {
  AgentEventBus({
    this.replayBufferSize = 50,
    this.onListenerError,
  }) : assert(replayBufferSize >= 0, 'replayBufferSize must be >= 0');

  /// Maximum number of past events kept for replay on subscribe.
  final int replayBufferSize;

  /// Optional hook invoked whenever a listener or its filter throws.
  /// The error is never rethrown — delivery to other listeners and to
  /// the bus continues unaffected.
  final void Function(MissionEvent event, Object error)? onListenerError;

  // Synchronous controller: publish dispatches immediately, keeping
  // ordering deterministic. Listener failures are contained by the
  // guarded subscription below, so synchronous dispatch is safe.
  final StreamController<MissionEvent> _controller =
      StreamController<MissionEvent>.broadcast(sync: true);
  final List<MissionEvent> _buffer = <MissionEvent>[];
  bool _disposed = false;

  /// The last [replayBufferSize] published events, oldest first.
  /// Unmodifiable view over the internal buffer.
  List<MissionEvent> get replayBuffer => UnmodifiableListView(_buffer);

  /// Whether [dispose] has been called.
  bool get isDisposed => _disposed;

  /// Adds [event] to the replay buffer and emits it to all listeners.
  ///
  /// Safe no-op after [dispose].
  void publish(MissionEvent event) {
    if (_disposed) return;
    _buffer.add(event);
    if (_buffer.length > replayBufferSize) {
      _buffer.removeRange(0, _buffer.length - replayBufferSize);
    }
    _controller.add(event);
  }

  /// Returns a broadcast stream of [MissionEvent]s: first the replay
  /// buffer (filtered by [filter] when given), then all live events
  /// passing [filter].
  ///
  /// The stream is guarded: exceptions thrown by the listener or by
  /// [filter] are reported to [onListenerError] (when provided) and
  /// otherwise swallowed — they never break other listeners, the bus,
  /// or this subscription's ability to receive later events.
  Stream<MissionEvent> subscribe({bool Function(MissionEvent)? filter}) {
    return _GuardedMissionStream(this, filter);
  }

  /// Closes the bus. Subscriber streams close; [publish] becomes a safe
  /// no-op. Idempotent.
  Future<void> dispose() async {
    if (_disposed) return;
    _disposed = true;
    await _controller.close();
  }

  void _reportListenerError(MissionEvent event, Object error) {
    onListenerError?.call(event, error);
  }
}

/// A broadcast-style [Stream] that delivers every event through a
/// guarded tap so a throwing listener cannot break anything else.
class _GuardedMissionStream extends Stream<MissionEvent> {
  _GuardedMissionStream(this._bus, this._filter);

  final AgentEventBus _bus;
  final bool Function(MissionEvent)? _filter;

  @override
  bool get isBroadcast => true;

  @override
  StreamSubscription<MissionEvent> listen(
    void Function(MissionEvent event)? onData, {
    Function? onError,
    void Function()? onDone,
    bool? cancelOnError,
  }) {
    final subscription = _GuardedSubscription(
      source: _bus._controller.stream,
      filter: _filter,
      dataHandler: onData,
      errorHandler: onError,
      doneHandler: onDone,
      cancelOnError: cancelOnError ?? false,
      reportListenerError: _bus._reportListenerError,
    );
    // Replay the buffer before any live event can be delivered: the
    // source subscription was just attached and no publish can
    // interleave with this synchronous loop. A publish from inside a
    // listener during replay reaches this subscriber live (the event is
    // past the snapshot and the source subscription is attached), so
    // nothing is duplicated or lost.
    for (final event in List<MissionEvent>.of(_bus._buffer)) {
      if (subscription.isCancelled) break;
      if (!subscription.passesFilter(event)) continue;
      subscription.deliver(event);
    }
    return subscription;
  }
}

/// The per-listener tap: wraps the source subscription and guards every
/// callback so listener errors stay contained.
class _GuardedSubscription implements StreamSubscription<MissionEvent> {
  _GuardedSubscription({
    required Stream<MissionEvent> source,
    required this.filter,
    required this.dataHandler,
    required this.errorHandler,
    required this.doneHandler,
    required this.cancelOnError,
    required this.reportListenerError,
  }) {
    _source = source.listen(
      _handleEvent,
      onError: _handleSourceError,
      onDone: _handleDone,
      cancelOnError: false,
    );
  }

  /// Filter predicate; null means "everything passes".
  final bool Function(MissionEvent)? filter;
  final bool cancelOnError;
  final void Function(MissionEvent event, Object error) reportListenerError;

  /// The consumer's data callback — invoked only through [deliver], so a
  /// throw is always caught by the guard.
  void Function(MissionEvent event)? dataHandler;
  Function? errorHandler;
  void Function()? doneHandler;

  StreamSubscription<MissionEvent>? _source;
  bool _cancelled = false;
  int _pauseCount = 0;

  bool get isCancelled => _cancelled;

  /// Filtered delivery check; a throwing filter counts as "not passing"
  /// and is reported, never propagated.
  bool passesFilter(MissionEvent event) {
    final predicate = filter;
    if (predicate == null) return true;
    try {
      return predicate(event);
    } catch (error) {
      reportListenerError(event, error);
      return false;
    }
  }

  /// Guarded delivery: a throwing listener is reported and swallowed.
  void deliver(MissionEvent event) {
    if (_cancelled) return;
    try {
      dataHandler?.call(event);
    } catch (error) {
      reportListenerError(event, error);
    }
  }

  void _handleEvent(MissionEvent event) {
    if (_cancelled) return;
    if (!passesFilter(event)) return;
    deliver(event);
  }

  void _handleSourceError(Object error, StackTrace stackTrace) {
    // The bus never adds error events today; if one ever appears, forward
    // it to the listener's onError without breaking the subscription.
    final handler = errorHandler;
    if (handler != null) {
      try {
        (handler as dynamic)(error, stackTrace);
      } on NoSuchMethodError {
        // Handler takes a single argument — retry without the stack.
        try {
          (handler as dynamic)(error);
        } catch (_) {
          // Broken error handler — swallow.
        }
      } catch (_) {
        // Handler threw — swallow; never break the bus.
      }
    }
    if (cancelOnError) {
      _cancelled = true;
      _source?.cancel();
    }
  }

  void _handleDone() {
    if (_cancelled) return;
    _cancelled = true;
    try {
      doneHandler?.call();
    } catch (_) {
      // Broken onDone — swallow; other listeners are unaffected.
    }
  }

  @override
  void onData(void Function(MissionEvent event)? handleData) =>
      dataHandler = handleData;

  @override
  void onError(Function? handleError) => errorHandler = handleError;

  @override
  void onDone(void Function()? handleDone) => doneHandler = handleDone;

  @override
  bool get isPaused => _pauseCount > 0;

  @override
  void pause([Future<void>? resumeSignal]) {
    _pauseCount++;
    _source?.pause(resumeSignal);
  }

  @override
  void resume() {
    if (_pauseCount > 0) _pauseCount--;
    if (_pauseCount == 0) _source?.resume();
  }

  @override
  Future<void> cancel() async {
    if (_cancelled) return;
    _cancelled = true;
    await _source?.cancel();
  }

  @override
  Future<E> asFuture<E>([E? futureValue]) {
    final completer = Completer<E>();
    doneHandler = () {
      if (futureValue is E) {
        completer.complete(futureValue);
      } else if (null is E) {
        completer.complete(null as E);
      } else {
        completer.completeError(
          UnsupportedError('asFuture without a value on non-nullable stream'),
        );
      }
    };
    errorHandler = (Object error, [StackTrace? stack]) =>
        completer.completeError(error, stack);
    return completer.future;
  }
}
