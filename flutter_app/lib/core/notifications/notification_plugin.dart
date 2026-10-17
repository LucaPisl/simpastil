import 'package:flutter_local_notifications/flutter_local_notifications.dart';

/// App-wide notification plugin singleton.
///
/// Constructed on first access, before any provider can capture it. Native
/// initialization still runs in startup via
/// [FlutterLocalNotificationsPlugin.initialize]. Session reconciliation can
/// construct its service before that optional startup task begins.
/// Kept here (rather than in main.dart) so [NotificationService] can import it
/// without creating a circular dependency.
FlutterLocalNotificationsPlugin notificationsPlugin =
    FlutterLocalNotificationsPlugin();
