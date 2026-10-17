import 'dart:async';

import 'package:flutter/widgets.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:home_widget/home_widget.dart';

import '../../core/protection/app_lock_controller.dart';
import '../../core/utils/app_logger.dart';
import '../router/app_router.dart';

class NotificationReviewRequest {
  const NotificationReviewRequest(this.response, {this.isInitial = false});
  final NotificationResponse response;
  final bool isInitial;
}

class _PendingReview {
  const _PendingReview.widget(this.uri)
    : notification = null,
      reviewOnly = true;
  const _PendingReview.notification(this.notification, this.reviewOnly)
    : uri = null;
  final Uri? uri;
  final NotificationResponse? notification;
  final bool reviewOnly;
}

/// Retains complete external requests only in memory while care is concealed.
/// Locked care actions become review requests, never delayed recording commands.
class WidgetReviewHandoff extends ConsumerStatefulWidget {
  const WidgetReviewHandoff({
    super.key,
    required this.validate,
    required this.child,
    this.notifications,
    this.validateNotification,
    this.dispatchNotification,
  });

  final Future<String?> Function(Uri) validate;
  final Widget child;
  final ValueNotifier<NotificationReviewRequest?>? notifications;
  final Future<String?> Function(NotificationResponse)? validateNotification;
  final Future<void> Function(NotificationResponse, void Function(String))?
  dispatchNotification;

  @override
  ConsumerState<WidgetReviewHandoff> createState() =>
      _WidgetReviewHandoffState();
}

class _WidgetReviewHandoffState extends ConsumerState<WidgetReviewHandoff>
    with WidgetsBindingObserver {
  StreamSubscription<Uri?>? _clicks;
  _PendingReview? _pending;
  int _request = 0;
  bool _warmReceived = false;
  bool _foreground = true;
  bool _scheduled = false;
  bool _validating = false;

  @override
  void initState() {
    super.initState();
    final lifecycle = WidgetsBinding.instance.lifecycleState;
    _foreground = lifecycle == null || lifecycle == AppLifecycleState.resumed;
    WidgetsBinding.instance.addObserver(this);
    _clicks = HomeWidget.widgetClicked.listen((uri) {
      if (uri == null) return;
      _warmReceived = true;
      _receive(uri);
    }, onError: _unavailable);
    widget.notifications?.addListener(_notificationReceived);
    _notificationReceived();
    unawaited(_readInitial());
  }

  @override
  void didUpdateWidget(WidgetReviewHandoff oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.notifications != widget.notifications) {
      oldWidget.notifications?.removeListener(_notificationReceived);
      widget.notifications?.addListener(_notificationReceived);
      _notificationReceived();
    }
  }

  void _notificationReceived() {
    final request = widget.notifications?.value;
    if (!mounted || request == null) return;
    widget.notifications!.value = null;
    if (request.isInitial && _warmReceived) return;
    if (!request.isInitial) _warmReceived = true;
    _pending = _PendingReview.notification(
      request.response,
      ref.read(appLockControllerProvider).enabled,
    );
    _request++;
    _schedule();
  }

  Future<void> _readInitial() async {
    try {
      final uri = await HomeWidget.initiallyLaunchedFromHomeWidget();
      if (mounted && !_warmReceived && uri != null) _receive(uri);
    } on Object catch (error) {
      _unavailable(error);
    }
  }

  void _unavailable(Object error) => AppLogger.warning(
    'ExternalReview',
    'External review entry unavailable: ${error.runtimeType}',
  );

  void _receive(Uri uri) {
    if (!mounted) return;
    _pending = _PendingReview.widget(uri);
    _request++;
    _schedule();
  }

  bool get _ready =>
      mounted && _foreground && ref.read(appLockControllerProvider).canAccess;

  void _schedule() {
    if (!_ready || _pending == null || _scheduled || _validating) return;
    _scheduled = true;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _scheduled = false;
      if (_ready) unawaited(_review());
    });
    WidgetsBinding.instance.ensureVisualUpdate();
  }

  Future<void> _review() async {
    if (!_ready || _pending == null || _validating) return;
    final pending = _pending!;
    final request = _request;
    final lease = ref.read(appLockControllerProvider.notifier).captureAccess();
    _validating = true;
    try {
      final notification = pending.notification;
      if (notification != null &&
          !pending.reviewOnly &&
          !ref.read(appLockControllerProvider).enabled) {
        // Preserve off-policy behavior through the existing guarded dispatcher.
        // A request received under enabled policy never enters this branch.
        lease.requireCurrent();
        _pending = null;
        await widget.dispatchNotification?.call(notification, (route) {
          if (!_ready || request != _request) return;
          lease.requireCurrent();
          ref.read(routerProvider).go(route);
        });
        return;
      }
      final occurrenceId = notification == null
          ? await widget.validate(pending.uri!)
          : await widget.validateNotification?.call(notification);
      if (!_ready || request != _request || _pending != pending) return;
      lease.requireCurrent();
      _pending = null;
      if (occurrenceId == null) return;
      // Keep the existing route/draft beneath an explicit review screen. The
      // source URI's Take/Skip verb is never dispatched or replayed here.
      unawaited(
        ref
            .read(routerProvider)
            .push<void>(
              Uri(pathSegments: ['', 'doses', occurrenceId]).toString(),
            ),
      );
    } on AppLockRequired {
      // A fresh unlock must revalidate the original complete request.
    } on Object catch (error) {
      if (mounted && request == _request) _pending = null;
      _unavailable(error);
    } finally {
      _validating = false;
      _schedule();
    }
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    _foreground = state == AppLifecycleState.resumed;
    if (_foreground) _schedule();
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    widget.notifications?.removeListener(_notificationReceived);
    unawaited(_clicks?.cancel());
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    ref.listen(appLockControllerProvider, (_, next) {
      if (next.canAccess) _schedule();
    });
    return widget.child;
  }
}
