import 'package:flutter/widgets.dart';

import 'package:inkspacex/services/analytics_service.dart';

/// Auto-capture: every push/pop/replace fires `screen_viewed` with the
/// route name. Plug into `GoRouter(observers: [...])` so the analytics
/// pipeline gets a baseline navigation log even on screens we haven't
/// instrumented with explicit `Analytics.track(...)` calls.
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

  String? _name(Route<dynamic>? route) {
    final settings = route?.settings;
    final name = settings?.name;
    if (name == null || name.isEmpty) return null;
    return name;
  }

  @override
  void didPush(Route<dynamic> route, Route<dynamic>? previousRoute) {
    _svc?.trackScreenView(_name(route));
  }

  @override
  void didReplace({Route<dynamic>? newRoute, Route<dynamic>? oldRoute}) {
    _svc?.trackScreenView(_name(newRoute));
  }

  @override
  void didPop(Route<dynamic> route, Route<dynamic>? previousRoute) {
    _svc?.trackScreenView(_name(previousRoute));
  }
}
