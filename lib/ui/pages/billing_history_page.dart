import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:intl/intl.dart';
import 'package:provider/provider.dart';
import 'package:url_launcher/url_launcher.dart';

import 'package:inkspacex/provider/subscription_provider.dart';
import 'package:inkspacex/services/api/api_subscription_service.dart';

/// Scrollable list of Razorpay invoices against the caller's
/// subscription. One row per charge, newest first; tap to open the
/// Razorpay-hosted PDF receipt via `url_launcher`.
///
/// The page calls through `SubscriptionProvider.fetchHistory()` —
/// the provider exposes it as a thin pass-through to
/// `ApiSubscriptionService.getHistory()`. We keep the page itself
/// stateless about the network: a `FutureBuilder` drives loading,
/// error, and empty states.
class BillingHistoryPage extends StatefulWidget {
  const BillingHistoryPage({super.key});

  @override
  State<BillingHistoryPage> createState() => _BillingHistoryPageState();
}

class _BillingHistoryPageState extends State<BillingHistoryPage> {
  late Future<List<BillingInvoice>> _future;

  @override
  void initState() {
    super.initState();
    _future = context.read<SubscriptionProvider>().fetchHistory();
  }

  Future<void> _reload() async {
    setState(() {
      _future = context.read<SubscriptionProvider>().fetchHistory();
    });
    await _future;
  }

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final bgColor = isDark ? const Color(0xFF000000) : Colors.white;
    final textColor = isDark ? Colors.white : Colors.black;

    return Scaffold(
      backgroundColor: bgColor,
      appBar: AppBar(
        title: Text(
          "Billing history",
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
      body: FutureBuilder<List<BillingInvoice>>(
        future: _future,
        builder: (context, snapshot) {
          if (snapshot.connectionState == ConnectionState.waiting) {
            return const Center(child: CircularProgressIndicator());
          }
          if (snapshot.hasError) {
            return _buildErrorState(context, isDark, textColor);
          }
          final items = snapshot.data ?? const <BillingInvoice>[];
          if (items.isEmpty) {
            return _buildEmptyState(textColor);
          }
          return RefreshIndicator(
            onRefresh: _reload,
            child: Center(
              child: ConstrainedBox(
                constraints: const BoxConstraints(maxWidth: 520),
                child: ListView.separated(
                  padding: const EdgeInsets.fromLTRB(20, 8, 20, 48),
                  itemCount: items.length,
                  separatorBuilder: (_, _) => Divider(
                    color: isDark
                        ? Colors.white.withValues(alpha: 0.06)
                        : Colors.black.withValues(alpha: 0.06),
                    height: 1,
                    thickness: 1,
                  ),
                  itemBuilder: (_, i) => _InvoiceRow(
                    invoice: items[i],
                    isDark: isDark,
                  ),
                ),
              ),
            ),
          );
        },
      ),
    );
  }

  Widget _buildEmptyState(Color textColor) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: Text(
          "No invoices yet.",
          style: GoogleFonts.inter(
            fontSize: 14,
            color: textColor.withValues(alpha: 0.6),
          ),
        ),
      ),
    );
  }

  Widget _buildErrorState(BuildContext context, bool isDark, Color textColor) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(
              "Couldn't load your billing history.",
              style: GoogleFonts.inter(
                fontSize: 14,
                color: textColor.withValues(alpha: 0.7),
              ),
              textAlign: TextAlign.center,
            ),
            const SizedBox(height: 12),
            TextButton(
              onPressed: _reload,
              child: const Text("Retry"),
            ),
          ],
        ),
      ),
    );
  }
}

class _InvoiceRow extends StatelessWidget {
  final BillingInvoice invoice;
  final bool isDark;

  const _InvoiceRow({required this.invoice, required this.isDark});

  @override
  Widget build(BuildContext context) {
    final textColor = isDark ? Colors.white : Colors.black;
    final dateText = _formatDate(invoice.paidAt ?? invoice.billingPeriodStart);
    final amount = _formatAmount(invoice.amountCents, invoice.currency);
    final canOpenReceipt =
        invoice.receiptUrl != null && invoice.receiptUrl!.isNotEmpty;

    return Material(
      color: Colors.transparent,
      child: InkWell(
        onTap: canOpenReceipt ? () => _openReceipt(context) : null,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 14),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.center,
            children: [
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      dateText.isEmpty ? '—' : dateText,
                      style: GoogleFonts.inter(
                        fontSize: 14,
                        fontWeight: FontWeight.w600,
                        color: textColor,
                      ),
                    ),
                    const SizedBox(height: 4),
                    _StatusBadge(status: invoice.status, isDark: isDark),
                  ],
                ),
              ),
              Text(
                amount,
                style: GoogleFonts.inter(
                  fontSize: 14,
                  fontWeight: FontWeight.w600,
                  color: textColor,
                ),
              ),
              const SizedBox(width: 8),
              Icon(
                CupertinoIcons.chevron_right,
                size: 14,
                color: textColor.withValues(
                  alpha: canOpenReceipt ? 0.4 : 0.15,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Future<void> _openReceipt(BuildContext context) async {
    final url = invoice.receiptUrl;
    if (url == null || url.isEmpty) return;
    final messenger = ScaffoldMessenger.of(context);
    try {
      final ok = await launchUrl(
        Uri.parse(url),
        mode: LaunchMode.externalApplication,
      );
      if (!ok) {
        messenger.showSnackBar(
          const SnackBar(content: Text("Couldn't open the receipt.")),
        );
      }
    } catch (e) {
      messenger.showSnackBar(
        SnackBar(content: Text(e.toString().replaceFirst('Exception: ', ''))),
      );
    }
  }

  String _formatDate(DateTime? d) {
    if (d == null) return '';
    return DateFormat('MMMM d, y').format(d.toLocal());
  }

  String _formatAmount(int amountCents, String currency) {
    final rupees = amountCents / 100;
    final formatted = amountCents % 100 == 0
        ? rupees.toStringAsFixed(0)
        : rupees.toStringAsFixed(2);
    if (currency.toLowerCase() == 'inr') return "₹ $formatted";
    return "$formatted ${currency.toUpperCase()}";
  }
}

class _StatusBadge extends StatelessWidget {
  final String status;
  final bool isDark;

  const _StatusBadge({required this.status, required this.isDark});

  @override
  Widget build(BuildContext context) {
    // Tone-map the four Razorpay invoice statuses onto a small palette.
    final (bg, fg) = switch (status) {
      'paid' => isDark
          ? (const Color(0xFF143C28), const Color(0xFF7DDB9F))
          : (const Color(0xFFDBF5E3), const Color(0xFF1F6B3A)),
      'issued' => isDark
          ? (const Color(0xFF2A2A2A), const Color(0xFFCFCFCF))
          : (const Color(0xFFEFEFEF), const Color(0xFF555555)),
      'cancelled' || 'expired' => isDark
          ? (const Color(0xFF3A1F1F), const Color(0xFFFFB4B4))
          : (const Color(0xFFFCE4E4), const Color(0xFF8A1F1F)),
      _ => isDark
          ? (const Color(0xFF2A2A2A), const Color(0xFFCFCFCF))
          : (const Color(0xFFEFEFEF), const Color(0xFF555555)),
    };
    final label = status.isEmpty
        ? '—'
        : status[0].toUpperCase() + status.substring(1);
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
      decoration: BoxDecoration(
        color: bg,
        borderRadius: BorderRadius.circular(8),
      ),
      child: Text(
        label,
        style: GoogleFonts.inter(
          fontSize: 11,
          fontWeight: FontWeight.w600,
          color: fg,
        ),
      ),
    );
  }
}
