import 'package:inkspacex/services/api/api_client.dart';

/// Reader subscription state returned by `/api/subscriptions/me`.
///
/// Mirrors the Razorpay subscription lifecycle locally so the UI can
/// branch on a single `status` field. `status == "none"` is the
/// never-subscribed (or fully-ended) case where the page shows a
/// Subscribe CTA.
class SubscriptionMe {
  /// One of: `none`, `created`, `authenticated`, `active`, `pending`,
  /// `halted`, `cancelled`, `completed`.
  final String status;

  /// Human-readable plan name (e.g. "1 month").
  final String planLabel;

  /// Plan price in paise (₹199 = 19900).
  final int amountCents;

  /// ISO 4217 lowercase, e.g. `inr`.
  final String currency;

  /// End of the current billing cycle, i.e. when the next charge fires.
  /// Null until the subscription is authorized and the first cycle starts.
  final DateTime? currentPeriodEnd;

  /// True iff the user has scheduled cancellation at cycle end. The UI
  /// switches the heading to `Ends {date}` and greys out the cancel CTA.
  final bool cancelAtCycleEnd;

  /// Display label for the payment method (e.g. "Razorpay"). Server-controlled.
  final String paymentMethod;

  /// Hosted Razorpay payment page. Populated when the user still needs
  /// to authorize (status `created` / `authenticated`); cleared once active.
  final String? shortUrl;

  /// Hosted Razorpay URL where the user can update saved card / UPI.
  /// Populated when status is `active` or `halted`.
  final String? manageUrl;

  const SubscriptionMe({
    required this.status,
    required this.planLabel,
    required this.amountCents,
    required this.currency,
    required this.currentPeriodEnd,
    required this.cancelAtCycleEnd,
    required this.paymentMethod,
    required this.shortUrl,
    required this.manageUrl,
  });

  /// True when the subscription is currently in good standing.
  bool get isActive => status == 'active';

  /// True when the user hasn't completed the hosted authorization yet.
  /// UI surfaces a "Complete payment" CTA that re-opens `shortUrl`.
  bool get needsAuthorization =>
      status == 'created' || status == 'authenticated';

  /// True when Razorpay has given up on retrying the charge and the user
  /// must update their payment method.
  bool get isHalted => status == 'halted';

  factory SubscriptionMe.fromJson(Map<String, dynamic> json) => SubscriptionMe(
        status: json['status'] as String? ?? 'none',
        planLabel: json['plan_label'] as String? ?? '',
        amountCents: (json['amount_cents'] as num?)?.toInt() ?? 0,
        currency: json['currency'] as String? ?? 'inr',
        currentPeriodEnd: _parseDate(json['current_period_end']),
        cancelAtCycleEnd: json['cancel_at_cycle_end'] == true,
        paymentMethod: json['payment_method'] as String? ?? '',
        shortUrl: json['short_url'] as String?,
        manageUrl: json['manage_url'] as String?,
      );
}

/// One row of the billing history page — a single Razorpay invoice
/// against the caller's subscription.
class BillingInvoice {
  final String id;
  final int amountCents;
  final String currency;

  /// One of: `issued`, `paid`, `cancelled`, `expired`.
  final String status;
  final DateTime? billingPeriodStart;
  final DateTime? billingPeriodEnd;
  final DateTime? paidAt;

  /// Razorpay-hosted PDF receipt; tapping the row launches this URL.
  final String? receiptUrl;

  const BillingInvoice({
    required this.id,
    required this.amountCents,
    required this.currency,
    required this.status,
    required this.billingPeriodStart,
    required this.billingPeriodEnd,
    required this.paidAt,
    required this.receiptUrl,
  });

  factory BillingInvoice.fromJson(Map<String, dynamic> json) => BillingInvoice(
        id: json['id'] as String,
        amountCents: (json['amount_cents'] as num?)?.toInt() ?? 0,
        currency: json['currency'] as String? ?? 'inr',
        status: json['status'] as String? ?? '',
        billingPeriodStart: _parseDate(json['billing_period_start']),
        billingPeriodEnd: _parseDate(json['billing_period_end']),
        paidAt: _parseDate(json['paid_at']),
        receiptUrl: json['receipt_url'] as String?,
      );
}

/// Result of `POST /api/subscriptions/cancel`. `endsAt` is the moment
/// access actually expires — equal to `current_period_end` when
/// `immediate=false`, or `now()` when `immediate=true`.
class CancelResult {
  final String status;
  final bool cancelAtCycleEnd;
  final DateTime? endsAt;

  const CancelResult({
    required this.status,
    required this.cancelAtCycleEnd,
    required this.endsAt,
  });

  factory CancelResult.fromJson(Map<String, dynamic> json) => CancelResult(
        status: json['status'] as String? ?? '',
        cancelAtCycleEnd: json['cancel_at_cycle_end'] == true,
        endsAt: _parseDate(json['ends_at']),
      );
}

/// Result of `POST /api/subscriptions` — the new Razorpay subscription
/// row id plus the hosted authorization URL the client launches via
/// `url_launcher`.
class StartSubscriptionResult {
  final String subscriptionId;
  final String shortUrl;

  const StartSubscriptionResult({
    required this.subscriptionId,
    required this.shortUrl,
  });

  factory StartSubscriptionResult.fromJson(Map<String, dynamic> json) =>
      StartSubscriptionResult(
        subscriptionId: json['subscription_id'] as String,
        shortUrl: json['short_url'] as String,
      );
}

/// Tolerant ISO-8601 parser. Server emits UTC strings; null fields are
/// expected on rows that haven't been advanced through their lifecycle
/// yet (e.g. `current_period_end` before activation).
DateTime? _parseDate(Object? raw) {
  if (raw == null) return null;
  if (raw is! String || raw.isEmpty) return null;
  try {
    return DateTime.parse(raw);
  } catch (_) {
    return null;
  }
}

/// Frontend wrapper over the reader-subscription endpoints. All Razorpay
/// interaction is server-side — this service only ferries JSON and
/// hosted URLs the caller opens via `url_launcher`.
class ApiSubscriptionService {
  final ApiClient _client;

  ApiSubscriptionService(this._client);

  /// Fetch the caller's current subscription state. Called by
  /// `SubscriptionProvider.refresh()` and polled after returning from
  /// the hosted authorization page.
  Future<SubscriptionMe> getMe() async {
    final response = await _client.get('/api/subscriptions/me');
    return SubscriptionMe.fromJson(response.data as Map<String, dynamic>);
  }

  /// Create a new Razorpay subscription for the caller and return the
  /// hosted short_url the client opens. Idempotent — if the user already
  /// has a pending-authorization or active subscription, the existing
  /// short_url is returned.
  Future<StartSubscriptionResult> startSubscribe() async {
    final response = await _client.post('/api/subscriptions');
    return StartSubscriptionResult.fromJson(
      response.data as Map<String, dynamic>,
    );
  }

  /// Return the caller's billing history, newest first. Server unwraps
  /// to `{items: [...]}`; we hand back a plain list to the provider.
  Future<List<BillingInvoice>> getHistory() async {
    final response = await _client.get('/api/subscriptions/history');
    final data = response.data as Map<String, dynamic>;
    final items = (data['items'] as List?) ?? const [];
    return items
        .whereType<Map<String, dynamic>>()
        .map(BillingInvoice.fromJson)
        .toList();
  }

  /// Cancel the caller's subscription. `immediate=false` (default) lets
  /// access ride out the current billing cycle; `immediate=true` ends
  /// it now.
  Future<CancelResult> cancel({required bool immediate}) async {
    final response = await _client.post(
      '/api/subscriptions/cancel',
      data: {'immediate': immediate},
    );
    return CancelResult.fromJson(response.data as Map<String, dynamic>);
  }

  /// Mint a hosted Razorpay URL where the user can update their saved
  /// card / UPI. Returned URL is launched via `url_launcher`.
  Future<String> getManageUrl() async {
    final response =
        await _client.get('/api/subscriptions/manage-payment-method');
    final data = response.data as Map<String, dynamic>;
    return data['url'] as String;
  }
}
