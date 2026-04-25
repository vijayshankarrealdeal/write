import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';

class SubscriptionPage extends StatelessWidget {
  const SubscriptionPage({super.key});

  static const List<String> _features = [
    "Unlimited books and audiobooks",
    "Fresh new titles added every month",
    "Personalised recommendations",
    "Seamless switch between reading and listening",
    "Offline access",
    "Sync across all devices",
  ];

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final bgColor = isDark ? const Color(0xFF000000) : Colors.white;
    final textColor = isDark ? Colors.white : Colors.black;
    final pinkCardColor = isDark
        ? const Color(0xFF3A2735)
        : const Color(0xFFF3DCEB);
    final tileGroupColor = isDark
        ? const Color(0xFF1A1A1A)
        : const Color(0xFFF3F4F6);

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
      body: Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 520),
          child: ListView(
            padding: const EdgeInsets.fromLTRB(20, 8, 20, 48),
            children: [
              _buildPlanCard(pinkCardColor, textColor, isDark),
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
                children: [
                  _ActionTile(
                    label: "Manage payment method",
                    trailing: "Apple Pay",
                    onTap: () {},
                  ),
                  _buildDivider(isDark),
                  _ActionTile(
                    label: "Change plan",
                    onTap: () {},
                  ),
                  _buildDivider(isDark),
                  _ActionTile(
                    label: "End subscription",
                    onTap: () {},
                  ),
                  _buildDivider(isDark),
                  _ActionTile(
                    label: "View billing history",
                    onTap: () {},
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildPlanCard(Color bg, Color textColor, bool isDark) {
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
                        text: "Active\n",
                        style: GoogleFonts.playfairDisplay(
                          fontSize: 30,
                          fontWeight: FontWeight.w700,
                          color: accent,
                          height: 1.1,
                        ),
                      ),
                      TextSpan(
                        text: "1 month",
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
            "Next billing date",
            "April 22, 2026",
            accent,
          ),
          const SizedBox(height: 10),
          _buildPlanRow(
            "Amount",
            "\$ 7.99/month",
            accent,
          ),
          const SizedBox(height: 10),
          _buildPlanRow(
            "Payment method",
            "Apple Pay",
            accent,
          ),
        ],
      ),
    );
  }

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
    final accent = const Color(0xFF6B7AF0);
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 7),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(
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
  final VoidCallback onTap;

  const _ActionTile({
    required this.label,
    this.trailing,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final textColor = isDark ? Colors.white : Colors.black;

    return Material(
      color: Colors.transparent,
      child: InkWell(
        onTap: onTap,
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
