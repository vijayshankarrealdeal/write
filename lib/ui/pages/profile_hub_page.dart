import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:provider/provider.dart';
import 'package:url_launcher/url_launcher.dart';
import 'package:inkspacex/provider/auth_provider.dart';
import 'package:inkspacex/ui/widgets/app_network_image.dart';

class ProfileHubPage extends StatelessWidget {
  const ProfileHubPage({super.key});

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final textColor = isDark ? Colors.white : Colors.black;
    final cardColor = isDark ? const Color(0xFF1A1A1A) : const Color(0xFFF3F4F6);
    final subtleBorder = isDark
        ? Colors.white.withValues(alpha: 0.08)
        : Colors.black.withValues(alpha: 0.05);
    final user = context.watch<AuthProvider>().currentUser;

    return Scaffold(
      backgroundColor: Colors.transparent,
      body: Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 520),
          child: ListView(
            padding: const EdgeInsets.fromLTRB(20, 8, 20, 48),
            children: [
              Center(
                child: Column(
                  children: [
                    Container(
                      padding: const EdgeInsets.all(3),
                      decoration: BoxDecoration(
                        shape: BoxShape.circle,
                        border: Border.all(
                          color: subtleBorder,
                          width: 1,
                        ),
                      ),
                      child: ClipOval(
                        child: SizedBox(
                          width: 108,
                          height: 108,
                          child: user?.photoUrl != null
                              ? AppNetworkImage(
                                  url: user!.photoUrl,
                                  meta: user.photoMeta,
                                  width: 108,
                                  height: 108,
                                  fit: BoxFit.cover,
                                )
                              : Container(
                                  alignment: Alignment.center,
                                  color: isDark
                                      ? Colors.white.withValues(alpha: 0.08)
                                      : Colors.black.withValues(alpha: 0.05),
                                  child: Text(
                                    (user?.name.isNotEmpty == true)
                                        ? user!.name[0].toUpperCase()
                                        : 'U',
                                    style: GoogleFonts.inter(
                                      fontSize: 34,
                                      fontWeight: FontWeight.w600,
                                      color: textColor.withValues(alpha: 0.7),
                                    ),
                                  ),
                                ),
                        ),
                      ),
                    ),
                    const SizedBox(height: 14),
                    Text(
                      user?.name.isNotEmpty == true ? user!.name : 'Reader',
                      style: GoogleFonts.playfairDisplay(
                        fontSize: 22,
                        fontWeight: FontWeight.w700,
                        color: textColor,
                      ),
                    ),
                    const SizedBox(height: 6),
                    Row(
                      mainAxisAlignment: MainAxisAlignment.center,
                      children: [
                        _buildStat(
                          '${user?.readingList.length ?? 0}',
                          'reading list',
                          textColor,
                        ),
                        Container(
                          width: 1,
                          height: 14,
                          margin: const EdgeInsets.symmetric(horizontal: 12),
                          color: textColor.withValues(alpha: 0.15),
                        ),
                        _buildStat(
                          '${user?.likes.length ?? 0}',
                          'liked',
                          textColor,
                        ),
                      ],
                    ),
                  ],
                ),
              ),

              const SizedBox(height: 32),

              _buildCardGroup(
                cardColor: cardColor,
                children: [
                  _HubTile(
                    icon: CupertinoIcons.person,
                    label: "My information",
                    onTap: () => context.push('/profile'),
                  ),
                  _buildDivider(context),
                  _HubTile(
                    icon: CupertinoIcons.creditcard,
                    label: "Subscription",
                    onTap: () => context.push('/subscription'),
                  ),
                  _buildDivider(context),
                  _HubTile(
                    icon: CupertinoIcons.chart_bar_alt_fill,
                    label: "Reading Statistics",
                    onTap: () => context.push('/reading-statistics'),
                  ),
                  _buildDivider(context),
                  _HubTile(
                    icon: CupertinoIcons.bookmark,
                    label: "Bookmarks",
                    onTap: () => context.push('/bookmarks'),
                  ),
                  _buildDivider(context),
                  _HubTile(
                    icon: CupertinoIcons.cloud_download,
                    label: "Manage downloads",
                    onTap: () => context.push('/manage-downloads'),
                  ),
                ],
              ),

              const SizedBox(height: 16),

              _buildCardGroup(
                cardColor: cardColor,
                children: [
                  _HubTile(
                    icon: CupertinoIcons.settings,
                    label: "Settings",
                    onTap: () => context.push('/settings-detail'),
                  ),
                  _buildDivider(context),
                  _HubTile(
                    icon: CupertinoIcons.wrench,
                    label: "Support",
                    onTap: () => _showSupportSheet(context),
                  ),
                ],
              ),

              const SizedBox(height: 24),

              // Hidden debug entry: long-press the version line to open
              // the merge log. Tap is intentionally a no-op so casual
              // users don't stumble into it.
              Center(
                child: GestureDetector(
                  behavior: HitTestBehavior.opaque,
                  onLongPress: () => context.push('/debug/merge-log'),
                  child: Padding(
                    padding: const EdgeInsets.symmetric(vertical: 8),
                    child: Text(
                      'InkSpaceX · v1.0.0',
                      style: GoogleFonts.inter(
                        fontSize: 11,
                        color: textColor.withValues(alpha: 0.35),
                      ),
                    ),
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildStat(String count, String label, Color textColor) {
    return RichText(
      text: TextSpan(
        style: GoogleFonts.inter(
          fontSize: 13,
          color: textColor.withValues(alpha: 0.65),
        ),
        children: [
          TextSpan(
            text: '$count ',
            style: GoogleFonts.inter(
              fontWeight: FontWeight.w600,
              color: textColor,
            ),
          ),
          TextSpan(text: label),
        ],
      ),
    );
  }

  Widget _buildCardGroup({
    required Color cardColor,
    required List<Widget> children,
  }) {
    return Container(
      decoration: BoxDecoration(
        color: cardColor,
        borderRadius: BorderRadius.circular(18),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: children,
      ),
    );
  }

  Widget _buildDivider(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    return Padding(
      padding: const EdgeInsets.only(left: 60),
      child: Divider(
        color: isDark
            ? Colors.white.withValues(alpha: 0.06)
            : Colors.black.withValues(alpha: 0.06),
        height: 1,
        thickness: 1,
      ),
    );
  }

  void _showSupportSheet(BuildContext context) {
    showCupertinoModalPopup(
      context: context,
      builder: (_) => CupertinoActionSheet(
        title: const Text("Support"),
        message: const Text("Need help? Reach out to us."),
        actions: [
          CupertinoActionSheetAction(
            onPressed: () {
              Navigator.pop(context);
              _launch(
                context,
                Uri(
                  scheme: 'mailto',
                  path: 'support@inkspacex.com',
                  queryParameters: {'subject': 'InkSpaceX Support'},
                ),
              );
            },
            child: const Text("Contact us"),
          ),
          CupertinoActionSheetAction(
            onPressed: () {
              Navigator.pop(context);
              _launch(
                context,
                Uri(
                  scheme: 'mailto',
                  path: 'support@inkspacex.com',
                  queryParameters: {
                    'subject': 'InkSpaceX Issue Report',
                    'body':
                        'Please describe the issue you are experiencing:\n\n\n'
                        '---\nSteps to reproduce:\n',
                  },
                ),
              );
            },
            child: const Text("Report an issue"),
          ),
          CupertinoActionSheetAction(
            onPressed: () {
              Navigator.pop(context);
              _launch(context, Uri.parse('https://inkspacex.com/help'));
            },
            child: const Text("Help center"),
          ),
        ],
        cancelButton: CupertinoActionSheetAction(
          isDestructiveAction: true,
          onPressed: () => Navigator.pop(context),
          child: const Text("Cancel"),
        ),
      ),
    );
  }

  Future<void> _launch(BuildContext context, Uri uri) async {
    final messenger = ScaffoldMessenger.maybeOf(context);
    final ok = await launchUrl(uri, mode: LaunchMode.externalApplication);
    if (!ok) {
      messenger?.showSnackBar(
        SnackBar(content: Text('Could not open ${uri.toString()}')),
      );
    }
  }
}

class _HubTile extends StatelessWidget {
  final IconData icon;
  final String label;
  final VoidCallback onTap;

  const _HubTile({
    required this.icon,
    required this.label,
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
          padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 18),
          child: Row(
            children: [
              Icon(
                icon,
                size: 22,
                color: textColor.withValues(alpha: 0.8),
              ),
              const SizedBox(width: 16),
              Expanded(
                child: Text(
                  label,
                  style: GoogleFonts.inter(
                    color: textColor,
                    fontSize: 15,
                    fontWeight: FontWeight.w500,
                  ),
                ),
              ),
              Icon(
                CupertinoIcons.chevron_right,
                color: textColor.withValues(alpha: 0.3),
                size: 16,
              ),
            ],
          ),
        ),
      ),
    );
  }
}
