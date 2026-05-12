import 'dart:async';

import 'package:flutter/foundation.dart';

import 'package:inkspacex/services/api/api_client.dart';
import 'package:inkspacex/services/api/api_subscription_service.dart';
import 'package:inkspacex/services/app_log.dart';

/// Owns the reader-subscription state shown on the subscription + billing
/// history pages. Wraps `ApiSubscriptionService` and converts thrown
/// network errors into `lastError` so the UI can render a friendly
/// error state without a try/catch at the call site.
///
/// The page calls [refresh] in initState. After the user returns from
/// the Razorpay-hosted authorization URL, [pollUntilActive] keeps
/// re-hitting `/me` until the webhook lands the `subscription.activated`
/// event and the status flips to `active` — saves the user from having
/// to pull-to-refresh.
class SubscriptionProvider extends ChangeNotifier {
  SubscriptionProvider(ApiClient client)
      : _api = ApiSubscriptionService(client);

  final ApiSubscriptionService _api;

  SubscriptionMe? _me;
  SubscriptionMe? get me => _me;

  bool _loading = false;
  bool get loading => _loading;

  Object? _lastError;
  Object? get lastError => _lastError;

  /// Re-fetch `/api/subscriptions/me` and notify listeners. Errors are
  /// swallowed into [lastError] so the UI can render an inline message
  /// without a try/catch around every call site.
  Future<void> refresh() async {
    _loading = true;
    _lastError = null;
    notifyListeners();
    try {
      _me = await _api.getMe();
    } catch (e, st) {
      log.w('[subscription] refresh failed: $e');
      _lastError = e;
      // Don't clobber `_me` — a stale snapshot is more useful than null
      // when the network briefly drops mid-page.
      assert(() {
        // Surface the stack in debug only; production logs are noisy enough.
        debugPrintStack(stackTrace: st, label: 'subscription.refresh');
        return true;
      }());
    } finally {
      _loading = false;
      notifyListeners();
    }
  }

  /// Kick off a fresh subscription on the server and return the hosted
  /// Razorpay short_url for the caller to launch via `url_launcher`.
  /// After the user returns from the hosted page, call
  /// [pollUntilActive] to flip the screen to Active without a manual
  /// reload. Returns null if the server refused (e.g. plan not
  /// configured); the error is also stashed in [lastError].
  Future<String?> startSubscribe() async {
    try {
      final result = await _api.startSubscribe();
      // Refresh so the page can show the "Authorization pending" state
      // while the user is over on the hosted page.
      await refresh();
      return result.shortUrl;
    } catch (e) {
      log.w('[subscription] startSubscribe failed: $e');
      _lastError = e;
      notifyListeners();
      return null;
    }
  }

  /// Cancel the caller's subscription. With `immediate=false`, access
  /// continues until `current_period_end`; with `immediate=true`, it
  /// ends now.
  Future<void> cancel({required bool immediate}) async {
    try {
      await _api.cancel(immediate: immediate);
    } catch (e) {
      log.w('[subscription] cancel failed: $e');
      _lastError = e;
      notifyListeners();
    }
    await refresh();
  }

  /// Mint and return the hosted "manage payment method" URL for the
  /// caller to launch via `url_launcher`. Returns null on error
  /// (also stashed in [lastError]).
  Future<String?> manage() async {
    try {
      return await _api.getManageUrl();
    } catch (e) {
      log.w('[subscription] manage failed: $e');
      _lastError = e;
      notifyListeners();
      return null;
    }
  }

  /// Repeatedly call [refresh] until the user is `active` or the
  /// timeout expires. Used by the subscription page right after the
  /// user returns from the Razorpay-hosted authorization URL — the
  /// webhook usually lands within a few seconds, but we don't want to
  /// rely on the user to pull-to-refresh.
  ///
  /// Returns true if the subscription flipped to active before the
  /// timeout, false otherwise. The page can show a fallback "still
  /// processing — pull to refresh" CTA on false.
  Future<bool> pollUntilActive({
    Duration interval = const Duration(seconds: 2),
    Duration timeout = const Duration(seconds: 60),
  }) async {
    final deadline = DateTime.now().add(timeout);
    while (DateTime.now().isBefore(deadline)) {
      await refresh();
      if (_me?.isActive == true) return true;
      // Sleep, but never past the deadline so we don't overrun.
      final remaining = deadline.difference(DateTime.now());
      if (remaining <= Duration.zero) break;
      final wait = remaining < interval ? remaining : interval;
      await Future<void>.delayed(wait);
    }
    return _me?.isActive == true;
  }

  /// Convenience for the billing-history page, which is the only caller
  /// that needs the raw invoice list. We could host a `_invoices` field
  /// here too, but the page is throwaway enough that a one-shot fetch
  /// keeps the provider lean.
  Future<List<BillingInvoice>> fetchHistory() {
    return _api.getHistory();
  }
}
