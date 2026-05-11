import 'package:inkspacex/services/api/api_client.dart';

/// Author Razorpay status returned by `/api/payments/connect/status`.
class ConnectStatus {
  /// Razorpay linked-account id once onboarding has been kicked off.
  /// Null until the author taps "Set up payouts" for the first time.
  final String? accountId;
  /// True iff the linked account has cleared KYC and can take Route
  /// transfers. The publish dialog only allows pricing a book when this
  /// is true; otherwise it shows a "Set up payouts" CTA pointing at the
  /// activation form URL.
  final bool chargesEnabled;
  /// Platform fee in basis points the author is told they pay (2000 =
  /// 20%). Surfaced verbatim in the publish dialog so authors aren't
  /// surprised by the cut.
  final int platformFeeBps;

  const ConnectStatus({
    required this.accountId,
    required this.chargesEnabled,
    required this.platformFeeBps,
  });

  factory ConnectStatus.fromJson(Map<String, dynamic> json) => ConnectStatus(
        accountId: json['account_id'] as String?,
        chargesEnabled: json['charges_enabled'] == true,
        platformFeeBps: (json['platform_fee_bps'] as num?)?.toInt() ?? 2000,
      );
}

/// Lookup result from `/api/payments/purchases/by-item/{id}`.
class PurchaseStatus {
  final bool purchased;
  final int? amountCents;
  final String? currency;

  const PurchaseStatus({
    required this.purchased,
    this.amountCents,
    this.currency,
  });

  factory PurchaseStatus.fromJson(Map<String, dynamic> json) => PurchaseStatus(
        purchased: json['purchased'] == true,
        amountCents: (json['amount_cents'] as num?)?.toInt(),
        currency: json['currency'] as String?,
      );
}

/// Frontend wrapper over the Razorpay onboarding / Payment Link endpoints.
/// All Razorpay interaction is server-side — this service only ferries
/// hosted URLs the caller opens via `url_launcher`.
class ApiPaymentsService {
  final ApiClient _client;

  ApiPaymentsService(this._client);

  /// Mint a hosted Razorpay activation-form URL for the calling author.
  /// Idempotent — second tap on a still-onboarding author returns a
  /// fresh link against the same Razorpay linked account.
  Future<String> startOnboarding() async {
    final response = await _client.post('/api/payments/connect/onboard');
    final data = response.data as Map<String, dynamic>;
    return data['url'] as String;
  }

  /// Refresh and return the calling author's payouts status. Called on
  /// publish-page load and right after returning from onboarding so
  /// the pricing toggle flips from disabled to enabled without waiting
  /// on the `account.updated` webhook.
  Future<ConnectStatus> getStatus() async {
    final response = await _client.get('/api/payments/connect/status');
    return ConnectStatus.fromJson(response.data as Map<String, dynamic>);
  }

  /// Create a hosted Razorpay Payment Link for the given paid book.
  /// Returns the URL the reader opens via `url_launcher`. The author
  /// receives X - platform_fee via a Route transfer fanned out on
  /// `payment.captured` — no separate manual step.
  Future<String> startCheckout(String feedItemId) async {
    final response = await _client.post('/api/payments/checkout/$feedItemId');
    final data = response.data as Map<String, dynamic>;
    return data['url'] as String;
  }

  /// Polled after returning from the Payment Link to detect that the
  /// webhook landed and the Purchase row exists. The reader UI flips
  /// from "Buy" to "Read" once `purchased` is true.
  Future<PurchaseStatus> getPurchase(String feedItemId) async {
    final response =
        await _client.get('/api/payments/purchases/by-item/$feedItemId');
    return PurchaseStatus.fromJson(response.data as Map<String, dynamic>);
  }
}
