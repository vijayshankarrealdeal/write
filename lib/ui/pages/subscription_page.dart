import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:intl/intl.dart';
import 'package:provider/provider.dart';
import 'package:url_launcher/url_launcher.dart';

import 'package:inkspacex/provider/subscription_provider.dart';
import 'package:inkspacex/services/api/api_subscription_service.dart';

/// Reader-subscription dashboard.
///
/// Visual shell (playfair heading, pink/purple plan card, rounded action
/// tiles) is preserved exactly from the original mockup — only the data
/// source changed: every value now flows from `SubscriptionProvider`.
///
/// Status handling mirrors the Razorpay subscription lifecycle:
///
/// * `null` / `provider.loading` → spinner
/// * `none` → Subscribe CTA card (the entry into the flow)
/// * `created` / `authenticated` → "Authorization pending" + reopen-link CTA
/// * `active` → real plan card (next billing, amount, payment method)
/// * `halted` → red "Payment failed" + update-payment CTA
/// * `cancelled` / `completed` → greyed-out "Ended …" card
/// * `active` with `cancelAtCycleEnd=true` → "Ends …" heading, cancel disabled
///
/// On `AppLifecycleState.resumed` while the row is in the pending-auth
/// window, the provider polls `/api/subscriptions/me` until status flips
/// to `active` (or the poll budget expires). This makes the page reflow
/// automatically when the user returns from the Razorpay-hosted page.
class SubscriptionPage extends StatefulWidget {
  const SubscriptionPage({super.key});

  @override
  State<SubscriptionPage> createState() => _SubscriptionPageState();
}

class _SubscriptionPageState extends State<SubscriptionPage>
    with WidgetsBindingObserver {
  static const List<String> _features = [
    "Unlimited books and audiobooks",
    "Fresh new titles added every month",
    "Personalised recommendations",
    "Seamless switch between reading and listening",
    "Offline access",
    "Sync across all devices",
  ];

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    // Defer the first fetch to the next frame so the during-build
    // setState lint stays happy and the provider's notifyListeners
    // doesn't fire while the widget tree is being mounted.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      context.read<SubscriptionProvider>().refresh();
    });
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state != AppLifecycleState.resumed) return;
    if (!mounted) return;
    final provider = context.read<SubscriptionProvider>();
    final me = provider.me;
    // User just came back from the Razorpay hosted page; poll until the
    // webhook lands and the row flips to `active`.
    if (me?.needsAuthorization == true) {
      provider.pollUntilActive();
    } else {
      // Cheap one-shot refresh on any resume — covers the case where
      // the row moves to `halted` or `cancelled` while we were
      // backgrounded.
      provider.refresh();
    }
  }

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final bgColor = isDark ? const Color(0xFF000000) : Colors.white;
    final textColor = isDark ? Colors.white : Colors.black;

    final provider = context.watch<SubscriptionProvider>();
    final me = provider.me;
    final loading = provider.loading;

    return Scaffold(
      backgroundColor: bgColor,
      appBar: AppBar(
        title: Text(
          "Subscription",
          style: GoogleFonts.inter(
            color: textColor,
            fontSize: 16,
            fontWeight: FontWeight.w600,
          ),
        ),
        backgroundColor: Colors.transparent,
        elevation: 0,
        iconTheme: IconThemeData(color: textColor),
        centerTitle: true,
      ),
      body: _buildBody(context, me, loading, isDark, textColor),
    );
  }

  Widget _buildBody(
    BuildContext context,
    SubscriptionMe? me,
    bool loading,
    bool isDark,
    Color textColor,
  ) {
    // First load (no cached snapshot yet) → spinner.
    if (me == null && loading) {
      return const Center(child: CircularProgressIndicator());
    }
    // After a fetch failure with no cached snapshot we still get
    // `me == null`. Render a minimal retry surface so the page isn't
    // a blank screen.
    if (me == null) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(
                "Couldn't load your subscription.",
                style: GoogleFonts.inter(
                  fontSize: 14,
                  color: textColor.withValues(alpha: 0.7),
                ),
                textAlign: TextAlign.center,
              ),
              const SizedBox(height: 12),
              TextButton(
                onPressed: () =>
                    context.read<SubscriptionProvider>().refresh(),
                child: const Text("Retry"),
              ),
            ],
          ),
        ),
      );
    }
    return _buildContent(context, me, isDark, textColor);
  }

  Widget _buildContent(
    BuildContext context,
    SubscriptionMe me,
    bool isDark,
    Color textColor,
  ) {
    final pinkCardColor = isDark
        ? const Color(0xFF3A2735)
        : const Color(0xFFF3DCEB);
    final tileGroupColor = isDark
        ? const Color(0xFF1A1A1A)
        : const Color(0xFFF3F4F6);

    return Center(
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 520),
        child: ListView(
          padding: const EdgeInsets.fromLTRB(20, 8, 20, 48),
          children: [
            _buildTopCard(context, me, pinkCardColor, isDark),
            const SizedBox(height: 28),
            Text(
              "Your subscription includes:",
              style: GoogleFonts.inter(
                fontSize: 16,
                fontWeight: FontWeight.w700,
                color: textColor,
              ),
            ),
            const SizedBox(height: 14),
            ..._features.map((f) => _buildFeatureRow(f, textColor, isDark)),
            const SizedBox(height: 24),
            _buildActionGroup(
              tileGroupColor: tileGroupColor,
              children: _buildActionTiles(context, me, isDark),
            ),
          ],
        ),
      ),
    );
  }

  // ---------------------------------------------------------------------------
  // Top card — branches on status to render Subscribe CTA, pending-auth,
  // active plan, halted, or ended states. Visual frame is shared.
  // ---------------------------------------------------------------------------

  Widget _buildTopCard(
    BuildContext context,
    SubscriptionMe me,
    Color bg,
    bool isDark,
  ) {
    switch (me.status) {
      case 'none':
        return _buildSubscribeCta(context, bg, isDark);
      case 'created':
      case 'authenticated':
        return _buildPendingAuthCard(context, me, bg, isDark);
      case 'halted':
        return _buildHaltedCard(context, me, isDark);
      case 'cancelled':
      case 'completed':
        return _buildEndedCard(context, me, bg, isDark);
      case 'active':
      case 'pending':
      default:
        return _buildActiveCard(context, me, bg, isDark);
    }
  }

  Widget _buildSubscribeCta(BuildContext context, Color bg, bool isDark) {
    final accent = isDark ? Colors.white : const Color(0xFF2B1F3A);
    return Container(
      padding: const EdgeInsets.fromLTRB(22, 24, 22, 22),
      decoration: BoxDecoration(
        color: bg,
        borderRadius: BorderRadius.circular(22),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Expanded(
                child: Text.rich(
                  TextSpan(
                    children: [
                      TextSpan(
                        text: "InkSpaceX\n",
                        style: GoogleFonts.playfairDisplay(
                          fontSize: 30,
                          fontWeight: FontWeight.w700,
                          color: accent,
                          height: 1.1,
                        ),
                      ),
                      TextSpan(
                        text: "₹199/month",
                        style: GoogleFonts.playfairDisplay(
                          fontSize: 30,
                          fontWeight: FontWeight.w700,
                          color: accent,
                          height: 1.1,
                        ),
                      ),
                    ],
                  ),
                ),
              ),
              Icon(
                CupertinoIcons.book,
                size: 56,
                color: accent.withValues(alpha: 0.85),
              ),
            ],
          ),
          const SizedBox(height: 22),
          SizedBox(
            width: double.infinity,
            child: ElevatedButton(
              style: ElevatedButton.styleFrom(
                backgroundColor: accent,
                foregroundColor: isDark ? Colors.black : Colors.white,
                padding: const EdgeInsets.symmetric(vertical: 14),
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(14),
                ),
                elevation: 0,
              ),
              onPressed: () => _onSubscribe(context),
              child: Text(
                "Subscribe",
                style: GoogleFonts.inter(
                  fontSize: 15,
                  fontWeight: FontWeight.w600,
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildPendingAuthCard(
    BuildContext context,
    SubscriptionMe me,
    Color bg,
    bool isDark,
  ) {
    final accent = isDark ? Colors.white : const Color(0xFF2B1F3A);
    return Container(
      padding: const EdgeInsets.fromLTRB(22, 24, 22, 22),
      decoration: BoxDecoration(
        color: bg,
        borderRadius: BorderRadius.circular(22),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Expanded(
                child: Text(
                  "Authorization\npending",
                  style: GoogleFonts.playfairDisplay(
                    fontSize: 28,
                    fontWeight: FontWeight.w700,
                    color: accent,
                    height: 1.1,
                  ),
                ),
              ),
              Icon(
                CupertinoIcons.clock,
                size: 56,
                color: accent.withValues(alpha: 0.85),
              ),
            ],
          ),
          const SizedBox(height: 16),
          Text(
            "Finish the Razorpay authorization to activate your "
            "subscription.",
            style: GoogleFonts.inter(
              fontSize: 13,
              color: accent.withValues(alpha: 0.7),
              height: 1.4,
            ),
          ),
          const SizedBox(height: 18),
          SizedBox(
            width: double.infinity,
            child: ElevatedButton(
              style: ElevatedButton.styleFrom(
                backgroundColor: accent,
                foregroundColor: isDark ? Colors.black : Colors.white,
                padding: const EdgeInsets.symmetric(vertical: 14),
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(14),
                ),
                elevation: 0,
              ),
              onPressed: () => _openUrl(context, me.shortUrl),
              child: Text(
                "Complete payment",
                style: GoogleFonts.inter(
                  fontSize: 15,
                  fontWeight: FontWeight.w600,
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildActiveCard(
    BuildContext context,
    SubscriptionMe me,
    Color bg,
    bool isDark,
  ) {
    final accent = isDark ? Colors.white : const Color(0xFF2B1F3A);
    final periodEnd = _formatDate(me.currentPeriodEnd);
    // `cancel_at_cycle_end=true` while still in good standing flips the
    // heading from "Active" to "Ends {date}" — same visual surface,
    // softer language, and the End-subscription tile disables itself.
    final heading = me.cancelAtCycleEnd
        ? (periodEnd.isEmpty ? "Ending soon" : "Ends $periodEnd")
        : "Active";
    return Container(
      padding: const EdgeInsets.fromLTRB(22, 24, 22, 22),
      decoration: BoxDecoration(
        color: bg,
        borderRadius: BorderRadius.circular(22),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Expanded(
                child: Text.rich(
                  TextSpan(
                    children: [
                      TextSpan(
                        text: "$heading\n",
                        style: GoogleFonts.playfairDisplay(
                          fontSize: 30,
                          fontWeight: FontWeight.w700,
                          color: accent,
                          height: 1.1,
                        ),
                      ),
                      TextSpan(
                        text: me.planLabel.isEmpty ? "—" : me.planLabel,
                        style: GoogleFonts.playfairDisplay(
                          fontSize: 30,
                          fontWeight: FontWeight.w700,
                          color: accent,
                          height: 1.1,
                        ),
                      ),
                    ],
                  ),
                ),
              ),
              Icon(
                CupertinoIcons.book,
                size: 56,
                color: accent.withValues(alpha: 0.85),
              ),
            ],
          ),
          const SizedBox(height: 22),
          _buildPlanRow(
            me.cancelAtCycleEnd ? "Ends on" : "Next billing date",
            periodEnd.isEmpty ? "—" : periodEnd,
            accent,
          ),
          const SizedBox(height: 10),
          _buildPlanRow(
            "Amount",
            _formatAmount(me.amountCents, me.currency),
            accent,
          ),
          const SizedBox(height: 10),
          _buildPlanRow(
            "Payment method",
            me.paymentMethod.isEmpty ? "Razorpay" : me.paymentMethod,
            accent,
          ),
        ],
      ),
    );
  }

  Widget _buildHaltedCard(
    BuildContext context,
    SubscriptionMe me,
    bool isDark,
  ) {
    // Red-tinted card so the "something needs your attention" signal
    // is unmistakable.
    final cardBg = isDark
        ? const Color(0xFF3A1F1F)
        : const Color(0xFFFCE4E4);
    final accent = isDark
        ? const Color(0xFFFFB4B4)
        : const Color(0xFF8A1F1F);
    return Container(
      padding: const EdgeInsets.fromLTRB(22, 24, 22, 22),
      decoration: BoxDecoration(
        color: cardBg,
        borderRadius: BorderRadius.circular(22),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Expanded(
                child: Text(
                  "Payment\nfailed",
                  style: GoogleFonts.playfairDisplay(
                    fontSize: 30,
                    fontWeight: FontWeight.w700,
                    color: accent,
                    height: 1.1,
                  ),
                ),
              ),
              Icon(
                CupertinoIcons.exclamationmark_triangle,
                size: 52,
                color: accent.withValues(alpha: 0.85),
              ),
            ],
          ),
          const SizedBox(height: 16),
          Text(
            "Update your payment method to resume.",
            style: GoogleFonts.inter(
              fontSize: 14,
              color: accent.withValues(alpha: 0.85),
              height: 1.4,
            ),
          ),
          const SizedBox(height: 18),
          SizedBox(
            width: double.infinity,
            child: ElevatedButton(
              style: ElevatedButton.styleFrom(
                backgroundColor: accent,
                foregroundColor: isDark ? Colors.black : Colors.white,
                padding: const EdgeInsets.symmetric(vertical: 14),
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(14),
                ),
                elevation: 0,
              ),
              onPressed: () => _onManagePayment(context),
              child: Text(
                "Update payment method",
                style: GoogleFonts.inter(
                  fontSize: 15,
                  fontWeight: FontWeight.w600,
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildEndedCard(
    BuildContext context,
    SubscriptionMe me,
    Color bg,
    bool isDark,
  ) {
    // Used in the brief window between `subscription.cancelled` / `.completed`
    // landing and `users.active_subscription_id` being cleared. After that
    // window the server returns `status="none"` and we render the
    // Subscribe CTA instead.
    final accent = (isDark ? Colors.white : const Color(0xFF2B1F3A))
        .withValues(alpha: 0.5);
    final periodEnd = _formatDate(me.currentPeriodEnd);
    return Container(
      padding: const EdgeInsets.fromLTRB(22, 24, 22, 22),
      decoration: BoxDecoration(
        color: bg.withValues(alpha: 0.6),
        borderRadius: BorderRadius.circular(22),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Expanded(
                child: Text(
                  periodEnd.isEmpty ? "Ended" : "Ended $periodEnd",
                  style: GoogleFonts.playfairDisplay(
                    fontSize: 28,
                    fontWeight: FontWeight.w700,
                    color: accent,
                    height: 1.1,
                  ),
                ),
              ),
              Icon(
                CupertinoIcons.book,
                size: 56,
                color: accent.withValues(alpha: 0.6),
              ),
            ],
          ),
          const SizedBox(height: 12),
          Text(
            "Your subscription has ended.",
            style: GoogleFonts.inter(
              fontSize: 13,
              color: accent,
            ),
          ),
        ],
      ),
    );
  }

  // ---------------------------------------------------------------------------
  // Actions list — only renders the four management tiles for the active
  // (or scheduled-to-end) status. Other statuses' primary actions live on
  // the card itself.
  // ---------------------------------------------------------------------------

  List<Widget> _buildActionTiles(
    BuildContext context,
    SubscriptionMe me,
    bool isDark,
  ) {
    final isActive = me.status == 'active' || me.status == 'pending';
    // We always show the four tiles when the user has any kind of live
    // subscription row — the End-subscription tile self-disables when
    // cancellation is already scheduled, and the others remain useful
    // (manage payment / history) even during the cycle wind-down.
    if (!isActive) return const [];
    final cancelAlreadyScheduled = me.cancelAtCycleEnd;
    final periodEnd = _formatDate(me.currentPeriodEnd);
    return [
      _ActionTile(
        label: "Manage payment method",
        trailing: me.paymentMethod.isEmpty ? "Razorpay" : me.paymentMethod,
        onTap: () => _onManagePayment(context),
      ),
      _buildDivider(isDark),
      _ActionTile(
        label: "Change plan",
        onTap: () => _onChangePlan(context, isDark),
      ),
      _buildDivider(isDark),
      _ActionTile(
        label: "End subscription",
        disabled: cancelAlreadyScheduled,
        onTap: cancelAlreadyScheduled
            ? null
            : () => _onEndSubscription(context, periodEnd),
      ),
      _buildDivider(isDark),
      _ActionTile(
        label: "View billing history",
        onTap: () => context.push('/subscription/history'),
      ),
    ];
  }

  // ---------------------------------------------------------------------------
  // Action handlers — each catches its own errors and surfaces them via
  // SnackBar so the page never silently swallows a failure.
  // ---------------------------------------------------------------------------

  Future<void> _onSubscribe(BuildContext context) async {
    final provider = context.read<SubscriptionProvider>();
    final messenger = ScaffoldMessenger.of(context);
    try {
      final shortUrl = await provider.startSubscribe();
      if (shortUrl == null || shortUrl.isEmpty) {
        messenger.showSnackBar(
          const SnackBar(
            content: Text("Couldn't start the subscription flow."),
          ),
        );
        return;
      }
      final ok = await launchUrl(
        Uri.parse(shortUrl),
        mode: LaunchMode.externalApplication,
      );
      if (!ok) {
        messenger.showSnackBar(
          const SnackBar(
            content: Text("Couldn't open the Razorpay payment page."),
          ),
        );
      }
      // Polling on return is handled by didChangeAppLifecycleState.
    } catch (e) {
      messenger.showSnackBar(
        SnackBar(content: Text(e.toString().replaceFirst('Exception: ', ''))),
      );
    }
  }

  Future<void> _onManagePayment(BuildContext context) async {
    final provider = context.read<SubscriptionProvider>();
    final messenger = ScaffoldMessenger.of(context);
    try {
      final url = await provider.manage();
      if (url == null || url.isEmpty) {
        messenger.showSnackBar(
          const SnackBar(
            content: Text("Couldn't open the payment-management page."),
          ),
        );
        return;
      }
      // `_openUrl` only uses the captured `messenger` after another
      // await — passing the same captured handle through avoids the
      // BuildContext-across-async-gap lint.
      await _launchAndReport(messenger, url);
    } catch (e) {
      messenger.showSnackBar(
        SnackBar(content: Text(e.toString().replaceFirst('Exception: ', ''))),
      );
    }
  }

  /// Variant of [_openUrl] that uses a pre-captured ScaffoldMessenger
  /// instead of reading a BuildContext after an async gap.
  Future<void> _launchAndReport(
    ScaffoldMessengerState messenger,
    String url,
  ) async {
    try {
      final ok = await launchUrl(
        Uri.parse(url),
        mode: LaunchMode.externalApplication,
      );
      if (!ok) {
        messenger.showSnackBar(
          const SnackBar(content: Text("Couldn't open the link.")),
        );
      }
    } catch (e) {
      messenger.showSnackBar(
        SnackBar(content: Text(e.toString().replaceFirst('Exception: ', ''))),
      );
    }
  }

  void _onChangePlan(BuildContext context, bool isDark) {
    showModalBottomSheet<void>(
      context: context,
      backgroundColor: isDark ? const Color(0xFF1A1A1A) : Colors.white,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
      ),
      builder: (ctx) {
        final textColor = isDark ? Colors.white : Colors.black;
        return SafeArea(
          child: Padding(
            padding: const EdgeInsets.fromLTRB(24, 24, 24, 24),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Text(
                  "Change plan",
                  style: GoogleFonts.inter(
                    fontSize: 16,
                    fontWeight: FontWeight.w700,
                    color: textColor,
                  ),
                ),
                const SizedBox(height: 10),
                Text(
                  "Only one plan available at the moment.",
                  style: GoogleFonts.inter(
                    fontSize: 14,
                    color: textColor.withValues(alpha: 0.7),
                    height: 1.4,
                  ),
                ),
                const SizedBox(height: 20),
                TextButton(
                  onPressed: () => Navigator.of(ctx).pop(),
                  child: const Text("Close"),
                ),
              ],
            ),
          ),
        );
      },
    );
  }

  void _onEndSubscription(BuildContext context, String periodEnd) {
    showCupertinoModalPopup<void>(
      context: context,
      builder: (ctx) => CupertinoActionSheet(
        title: const Text("End subscription"),
        message: const Text(
          "You can end your subscription at the end of the current cycle "
          "(you keep access until then) or end it immediately.",
        ),
        actions: [
          CupertinoActionSheetAction(
            isDestructiveAction: true,
            onPressed: () {
              Navigator.pop(ctx);
              _runCancel(context, immediate: false);
            },
            child: Text(
              periodEnd.isEmpty
                  ? "End at end of cycle"
                  : "End at end of cycle ($periodEnd)",
            ),
          ),
          CupertinoActionSheetAction(
            isDestructiveAction: true,
            onPressed: () {
              Navigator.pop(ctx);
              _runCancel(context, immediate: true);
            },
            child: const Text("End immediately"),
          ),
        ],
        cancelButton: CupertinoActionSheetAction(
          onPressed: () => Navigator.pop(ctx),
          child: const Text("Cancel"),
        ),
      ),
    );
  }

  Future<void> _runCancel(
    BuildContext context, {
    required bool immediate,
  }) async {
    // Capture the period-end string up front — the provider's `cancel`
    // calls refresh() internally, so `me.currentPeriodEnd` is the most
    // recent value we'll have for the user-facing confirmation.
    final provider = context.read<SubscriptionProvider>();
    final messenger = ScaffoldMessenger.of(context);
    final endsAt = _formatDate(provider.me?.currentPeriodEnd);
    try {
      await provider.cancel(immediate: immediate);
      final msg = immediate
          ? "Subscription ended."
          : (endsAt.isEmpty
              ? "Subscription will end at the end of the current cycle."
              : "Subscription will end on $endsAt.");
      messenger.showSnackBar(SnackBar(content: Text(msg)));
    } catch (e) {
      messenger.showSnackBar(
        SnackBar(content: Text(e.toString().replaceFirst('Exception: ', ''))),
      );
    }
  }

  Future<void> _openUrl(BuildContext context, String? url) async {
    final messenger = ScaffoldMessenger.of(context);
    if (url == null || url.isEmpty) {
      messenger.showSnackBar(
        const SnackBar(content: Text("No URL to open.")),
      );
      return;
    }
    try {
      final ok = await launchUrl(
        Uri.parse(url),
        mode: LaunchMode.externalApplication,
      );
      if (!ok) {
        messenger.showSnackBar(
          const SnackBar(content: Text("Couldn't open the link.")),
        );
      }
    } catch (e) {
      messenger.showSnackBar(
        SnackBar(content: Text(e.toString().replaceFirst('Exception: ', ''))),
      );
    }
  }

  // ---------------------------------------------------------------------------
  // Formatters.
  // ---------------------------------------------------------------------------

  /// `DateTime` → e.g. "June 22, 2026". Empty string when null.
  String _formatDate(DateTime? d) {
    if (d == null) return '';
    // intl is a direct dep — no need for the inline fallback.
    return DateFormat('MMMM d, y').format(d.toLocal());
  }

  /// `19900` paise → "₹ 199/month". Whole-rupee amounts drop the
  /// trailing zeros; sub-rupee amounts show two decimals.
  String _formatAmount(int amountCents, String currency) {
    final rupees = amountCents / 100;
    final formatted = amountCents % 100 == 0
        ? rupees.toStringAsFixed(0)
        : rupees.toStringAsFixed(2);
    // For now the plan ID is hard-coded to monthly; we display "/month"
    // unconditionally. Once an annual plan ships the server can return
    // a localised cadence string and we'll thread it through here.
    if (currency.toLowerCase() == 'inr') {
      return "₹ $formatted/month";
    }
    return "$formatted ${currency.toUpperCase()}/month";
  }

  // ---------------------------------------------------------------------------
  // Visual primitives — preserved verbatim from the original mockup so the
  // dark/light look is unchanged.
  // ---------------------------------------------------------------------------

  Widget _buildPlanRow(String label, String value, Color accent) {
    return Row(
      mainAxisAlignment: MainAxisAlignment.spaceBetween,
      children: [
        Text(
          label,
          style: GoogleFonts.inter(
            fontSize: 13,
            color: accent.withValues(alpha: 0.65),
          ),
        ),
        Text(
          value,
          style: GoogleFonts.inter(
            fontSize: 13,
            fontWeight: FontWeight.w600,
            color: accent,
          ),
        ),
      ],
    );
  }

  Widget _buildFeatureRow(String text, Color textColor, bool isDark) {
    const accent = Color(0xFF6B7AF0);
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 7),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Icon(
            Icons.auto_awesome,
            size: 16,
            color: accent,
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Text(
              text,
              style: GoogleFonts.inter(
                fontSize: 14,
                color: textColor.withValues(alpha: 0.8),
                height: 1.4,
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildActionGroup({
    required Color tileGroupColor,
    required List<Widget> children,
  }) {
    if (children.isEmpty) return const SizedBox.shrink();
    return Container(
      decoration: BoxDecoration(
        color: tileGroupColor,
        borderRadius: BorderRadius.circular(18),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: children,
      ),
    );
  }

  Widget _buildDivider(bool isDark) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 18),
      child: Divider(
        color: isDark
            ? Colors.white.withValues(alpha: 0.06)
            : Colors.black.withValues(alpha: 0.06),
        height: 1,
        thickness: 1,
      ),
    );
  }
}

class _ActionTile extends StatelessWidget {
  final String label;
  final String? trailing;
  final VoidCallback? onTap;
  final bool disabled;

  const _ActionTile({
    required this.label,
    this.trailing,
    required this.onTap,
    this.disabled = false,
  });

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final baseColor = isDark ? Colors.white : Colors.black;
    final textColor =
        disabled ? baseColor.withValues(alpha: 0.35) : baseColor;

    return Material(
      color: Colors.transparent,
      child: InkWell(
        onTap: disabled ? null : onTap,
        borderRadius: BorderRadius.circular(18),
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 16),
          child: Row(
            children: [
              Expanded(
                child: Text(
                  label,
                  style: GoogleFonts.inter(
                    fontSize: 14,
                    fontWeight: FontWeight.w500,
                    color: textColor,
                  ),
                ),
              ),
              if (trailing != null) ...[
                Text(
                  trailing!,
                  style: GoogleFonts.inter(
                    fontSize: 13,
                    color: textColor.withValues(alpha: 0.55),
                  ),
                ),
                const SizedBox(width: 6),
              ],
              Icon(
                CupertinoIcons.chevron_right,
                size: 16,
                color: textColor.withValues(alpha: 0.3),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
