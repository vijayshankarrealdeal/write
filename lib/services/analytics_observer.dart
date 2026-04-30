import 'package:flutter/widgets.dart';

import 'package:inkspacex/services/analytics_service.dart';

/// Auto-capture: every push/pop/replace fires `screen_viewed` with the
/// route name. Plug into `GoRouter(observers: [...])` so the analytics
/// pipeline gets a baseline navigation log even on screens we haven't
/// instrumented with explicit `Analytics.track(...)` calls.
///
/// Dwell pairing: on every transition we emit a `screen_left` event for
/// the route the user is leaving, with `duration_ms` measuring how long
/// they actually stayed there. That makes "where do users spend their
/// time?" answerable without any per-screen timing code.
class AnalyticsNavigatorObserver extends NavigatorObserver {
  AnalyticsNavigatorObserver({AnalyticsService? service}) : _service = service;

  // Allow tests to inject; production reads the singleton lazily so we
  // don't crash if a route fires before init() completes.
  final AnalyticsService? _service;

  AnalyticsService? get _svc {
    if (_service != null) return _service;
    try {
      return AnalyticsService.instance;
    } on StateError {
      return null;
    }
  }

  String? _activeName;
  DateTime? _activeStartedAt;

  String? _name(Route<dynamic>? route) {
    final name = route?.settings.name;
    if (name == null || name.isEmpty) return null;
    return name;
  }

  void _emitLeftIfActive(String? nextName) {
    final svc = _svc;
    if (svc == null) return;
    final name = _activeName;
    final startedAt = _activeStartedAt;
    if (name == null || startedAt == null) return;
    final dwellMs = DateTime.now().difference(startedAt).inMilliseconds;
    svc.track(
      'screen_left',
      screen: name,
      action: 'view',
      durationMs: dwellMs,
      // sourceScreen here points at where the user is going next — the
      // mirror of `screen_viewed`'s sourceScreen (which points at where
      // they came from). Lets funnel queries reconstruct edges from
      // either direction.
      sourceScreen: nextName,
    );
  }

  void _enter(Route<dynamic>? route) {
    final name = _name(route);
    final svc = _svc;
    if (svc != null) {
      svc.trackScreenView(name);
    }
    _activeName = name;
    _activeStartedAt = name != null ? DateTime.now() : null;
  }

  @override
  void didPush(Route<dynamic> route, Route<dynamic>? previousRoute) {
    _emitLeftIfActive(_name(route));
    _enter(route);
  }

  @override
  void didReplace({Route<dynamic>? newRoute, Route<dynamic>? oldRoute}) {
    _emitLeftIfActive(_name(newRoute));
    _enter(newRoute);
  }

  @override
  void didPop(Route<dynamic> route, Route<dynamic>? previousRoute) {
    // The popped route is the screen the user is leaving — emit its
    // dwell — and the previous route resumes focus, which we model as
    // a fresh `screen_viewed` (each foreground appearance counts).
    _emitLeftIfActive(_name(previousRoute));
    _enter(previousRoute);
  }
}
