import 'dart:isolate';
import 'dart:ui' show IsolateNameServer;

/// Tells a visible app that a background engine just committed care.
///
/// A notification button that does not open the app runs in a headless
/// engine with its own database connection, and Drift change notifications
/// belong to each connection. Without a nudge, an app that is already on
/// screen would keep showing the dose as pending until it next returns from
/// the background. Both engines share one Android process, so the visible app
/// registers a port in [IsolateNameServer] and the headless one pings it.
class ForegroundCareSignal {
  ForegroundCareSignal._(this._port);

  static const portName = 'simpastil_foreground_care_changed';

  final ReceivePort _port;

  /// Listens in the foreground engine. A name left by an engine that is gone
  /// (restart, process reuse) is replaced rather than blocking the new one.
  static ForegroundCareSignal listen(void Function() onChange) {
    IsolateNameServer.removePortNameMapping(portName);
    final port = ReceivePort();
    IsolateNameServer.registerPortWithName(port.sendPort, portName);
    port.listen((_) => onChange());
    return ForegroundCareSignal._(port);
  }

  /// Sent by a background engine after its care transaction has finished.
  /// Does nothing when no app is on screen.
  static void notify() =>
      IsolateNameServer.lookupPortByName(portName)?.send(true);

  void close() {
    if (IsolateNameServer.lookupPortByName(portName) == _port.sendPort) {
      IsolateNameServer.removePortNameMapping(portName);
    }
    _port.close();
  }
}
