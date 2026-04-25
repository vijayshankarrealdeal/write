import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:url_launcher/url_launcher.dart';

/// Reusable legal document viewer — renders privacy policy / ToS natively.
class LegalPage extends StatelessWidget {
  final String title;
  final List<_LegalBlock> _blocks;

  const LegalPage._({required this.title, required List<_LegalBlock> blocks})
      : _blocks = blocks;

  // ─── Factory: Privacy Policy ───
  static Widget privacyPolicy() => LegalPage._(
        title: 'Privacy Policy',
        blocks: _privacyBlocks,
      );

  // ─── Factory: Terms of Service ───
  static Widget termsOfService() => LegalPage._(
        title: 'Terms of Service',
        blocks: _termsBlocks,
      );

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final bg = isDark ? Colors.black : const Color(0xFFFAFAFA);
    final text = isDark ? Colors.white : Colors.black;
    final subtle = text.withValues(alpha: 0.5);

    return Scaffold(
      backgroundColor: bg,
      appBar: AppBar(
        title: Text(
          title,
          style: GoogleFonts.inter(
            color: text,
            fontSize: 16,
            fontWeight: FontWeight.w600,
          ),
        ),
        backgroundColor: Colors.transparent,
        elevation: 0,
        iconTheme: IconThemeData(color: text),
      ),
      body: Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 680),
          child: ListView.builder(
            padding: const EdgeInsets.fromLTRB(24, 8, 24, 80),
            itemCount: _blocks.length,
            itemBuilder: (context, i) {
              final block = _blocks[i];
              switch (block.type) {
                case _BlockType.updated:
                  return Padding(
                    padding: const EdgeInsets.only(bottom: 24),
                    child: Text(
                      block.text,
                      style: GoogleFonts.inter(
                        fontSize: 13,
                        color: subtle,
                      ),
                    ),
                  );
                case _BlockType.highlight:
                  return Container(
                    margin: const EdgeInsets.only(bottom: 20),
                    padding: const EdgeInsets.all(16),
                    decoration: BoxDecoration(
                      color: isDark
                          ? const Color(0xFF1A1A2E)
                          : const Color(0xFFF0F0FF),
                      borderRadius: const BorderRadius.horizontal(
                        right: Radius.circular(12),
                      ),
                      border: Border(
                        left: BorderSide(
                          color: isDark
                              ? const Color(0xFF5B8DEF)
                              : const Color(0xFF4A6CF7),
                          width: 3,
                        ),
                      ),
                    ),
                    child: Text(
                      block.text,
                      style: GoogleFonts.inter(
                        fontSize: 14,
                        height: 1.6,
                        color: text.withValues(alpha: 0.85),
                      ),
                    ),
                  );
                case _BlockType.heading:
                  return Padding(
                    padding: const EdgeInsets.only(top: 28, bottom: 10),
                    child: Text(
                      block.text,
                      style: GoogleFonts.inter(
                        fontSize: 18,
                        fontWeight: FontWeight.w700,
                        color: text,
                      ),
                    ),
                  );
                case _BlockType.paragraph:
                  return Padding(
                    padding: const EdgeInsets.only(bottom: 12),
                    child: Text(
                      block.text,
                      style: GoogleFonts.inter(
                        fontSize: 14,
                        height: 1.7,
                        color: text.withValues(alpha: 0.85),
                      ),
                    ),
                  );
                case _BlockType.bullet:
                  return Padding(
                    padding: const EdgeInsets.only(
                      left: 12,
                      bottom: 8,
                    ),
                    child: Row(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Padding(
                          padding: const EdgeInsets.only(top: 7),
                          child: Container(
                            width: 5,
                            height: 5,
                            decoration: BoxDecoration(
                              color: subtle,
                              shape: BoxShape.circle,
                            ),
                          ),
                        ),
                        const SizedBox(width: 12),
                        Expanded(
                          child: Text(
                            block.text,
                            style: GoogleFonts.inter(
                              fontSize: 14,
                              height: 1.6,
                              color: text.withValues(alpha: 0.85),
                            ),
                          ),
                        ),
                      ],
                    ),
                  );
                case _BlockType.email:
                  return Padding(
                    padding: const EdgeInsets.only(bottom: 12),
                    child: GestureDetector(
                      onTap: () => launchUrl(
                        Uri.parse('mailto:${block.text}'),
                      ),
                      child: Text(
                        block.text,
                        style: GoogleFonts.inter(
                          fontSize: 14,
                          color: isDark
                              ? const Color(0xFF5B8DEF)
                              : const Color(0xFF4A6CF7),
                          decoration: TextDecoration.underline,
                        ),
                      ),
                    ),
                  );
              }
            },
          ),
        ),
      ),
    );
  }
}

// ─── Block model ───
enum _BlockType { updated, highlight, heading, paragraph, bullet, email }

class _LegalBlock {
  final _BlockType type;
  final String text;
  const _LegalBlock(this.type, this.text);
}

// ─── Privacy Policy Content ───
const _privacyBlocks = <_LegalBlock>[
  _LegalBlock(_BlockType.updated, 'Last updated: April 4, 2026'),
  _LegalBlock(
    _BlockType.paragraph,
    'InkSpaceX ("we", "our", or "us") is committed to protecting your privacy. This Privacy Policy explains how we collect, use, disclose, and safeguard your information when you use our mobile application and web service (collectively, the "Service").',
  ),
  _LegalBlock(
    _BlockType.highlight,
    'Summary: We collect only what we need to run the app. We never sell your data. You own your content. You can delete your account anytime.',
  ),
  _LegalBlock(_BlockType.heading, '1. Information We Collect'),
  _LegalBlock(
    _BlockType.paragraph,
    'Account Information: When you create an account, we collect your name, email address, and profile photo (if provided via Google Sign-In).',
  ),
  _LegalBlock(
    _BlockType.paragraph,
    'Content You Create: We store the writing, creative canvas layouts, images, and other content you create within the app. This content is stored on our servers (Google Firebase) to enable syncing across your devices.',
  ),
  _LegalBlock(
    _BlockType.paragraph,
    'Usage Data: We collect anonymous usage data such as reading progress, feature usage patterns, and app performance metrics to improve the Service.',
  ),
  _LegalBlock(
    _BlockType.paragraph,
    'Device Information: We may collect device type, operating system version, and app version for compatibility and debugging purposes.',
  ),
  _LegalBlock(_BlockType.heading, '2. How We Use Your Information'),
  _LegalBlock(_BlockType.bullet, 'To provide, maintain, and improve the Service'),
  _LegalBlock(_BlockType.bullet, 'To sync your content across devices'),
  _LegalBlock(
    _BlockType.bullet,
    'To display your published Spaces on the public feed',
  ),
  _LegalBlock(
    _BlockType.bullet,
    'To enable social features (likes, comments, following)',
  ),
  _LegalBlock(
    _BlockType.bullet,
    'To send important service updates (not marketing)',
  ),
  _LegalBlock(
    _BlockType.bullet,
    'To detect and prevent abuse or security threats',
  ),
  _LegalBlock(_BlockType.heading, '3. Content Ownership'),
  _LegalBlock(
    _BlockType.paragraph,
    'You own your content. By publishing to InkSpaceX, you grant us a limited, non-exclusive license to display your content within the Service. You can unpublish or delete your content at any time.',
  ),
  _LegalBlock(_BlockType.heading, '4. Data Sharing'),
  _LegalBlock(
    _BlockType.paragraph,
    'We do not sell, rent, or trade your personal information. We may share data only in these limited circumstances:',
  ),
  _LegalBlock(
    _BlockType.bullet,
    'Published content: Spaces you publish are visible to other authenticated users on the feed.',
  ),
  _LegalBlock(
    _BlockType.bullet,
    'Service providers: We use Google Firebase for authentication, storage, and database services. Google\'s privacy policy applies to their infrastructure.',
  ),
  _LegalBlock(
    _BlockType.bullet,
    'Legal requirements: We may disclose information if required by law, court order, or to protect our legal rights.',
  ),
  _LegalBlock(_BlockType.heading, '5. Data Storage & Security'),
  _LegalBlock(
    _BlockType.paragraph,
    'Your data is stored on Google Firebase servers. We implement industry-standard security measures including:',
  ),
  _LegalBlock(_BlockType.bullet, 'Encryption in transit (TLS/HTTPS)'),
  _LegalBlock(
    _BlockType.bullet,
    'Firebase Security Rules restricting data access',
  ),
  _LegalBlock(_BlockType.bullet, 'Authentication-gated API access'),
  _LegalBlock(_BlockType.bullet, 'Owner-only access to private content'),
  _LegalBlock(_BlockType.heading, '6. Your Rights'),
  _LegalBlock(_BlockType.paragraph, 'You have the right to:'),
  _LegalBlock(_BlockType.bullet, 'Access your personal data stored in our Service'),
  _LegalBlock(_BlockType.bullet, 'Correct inaccurate information in your profile'),
  _LegalBlock(
    _BlockType.bullet,
    'Delete your account and all associated data',
  ),
  _LegalBlock(_BlockType.bullet, 'Export your content'),
  _LegalBlock(
    _BlockType.bullet,
    'Withdraw consent for optional data processing',
  ),
  _LegalBlock(_BlockType.heading, '7. Children\'s Privacy'),
  _LegalBlock(
    _BlockType.paragraph,
    'InkSpaceX is not intended for children under 13. We do not knowingly collect personal information from children under 13. If we become aware that a child under 13 has provided us with personal data, we will take steps to delete such information.',
  ),
  _LegalBlock(_BlockType.heading, '8. Cookies & Tracking'),
  _LegalBlock(
    _BlockType.paragraph,
    'The web version of InkSpaceX may use essential cookies for authentication and session management. We do not use third-party advertising cookies or cross-site tracking.',
  ),
  _LegalBlock(_BlockType.heading, '9. Third-Party Services'),
  _LegalBlock(_BlockType.paragraph, 'InkSpaceX integrates with:'),
  _LegalBlock(
    _BlockType.bullet,
    'Google Firebase — Authentication, database, storage, hosting',
  ),
  _LegalBlock(
    _BlockType.bullet,
    'Google Sign-In — Optional authentication method',
  ),
  _LegalBlock(
    _BlockType.bullet,
    'Google Fonts — Font rendering (loaded at runtime)',
  ),
  _LegalBlock(
    _BlockType.paragraph,
    'Each third-party service has its own privacy policy governing their data practices.',
  ),
  _LegalBlock(_BlockType.heading, '10. Data Retention'),
  _LegalBlock(
    _BlockType.paragraph,
    'We retain your data for as long as your account is active. If you delete your account, we will delete your personal data within 30 days, except where we are required to retain it for legal or legitimate business purposes.',
  ),
  _LegalBlock(_BlockType.heading, '11. Changes to This Policy'),
  _LegalBlock(
    _BlockType.paragraph,
    'We may update this Privacy Policy from time to time. We will notify you of significant changes through the app or via email. Continued use of the Service after changes constitutes acceptance of the updated policy.',
  ),
  _LegalBlock(_BlockType.heading, '12. Contact Us'),
  _LegalBlock(
    _BlockType.paragraph,
    'If you have questions about this Privacy Policy or your data, contact us at:',
  ),
  _LegalBlock(_BlockType.email, 'privacy@inkspacex.com'),
];

// ─── Terms of Service Content ───
const _termsBlocks = <_LegalBlock>[
  _LegalBlock(_BlockType.updated, 'Last updated: April 4, 2026'),
  _LegalBlock(
    _BlockType.paragraph,
    'Welcome to InkSpaceX. These Terms of Service ("Terms") govern your access to and use of the InkSpaceX application and website (collectively, the "Service") operated by InkSpaceX ("we", "our", or "us"). By creating an account or using the Service, you agree to be bound by these Terms.',
  ),
  _LegalBlock(
    _BlockType.highlight,
    'Summary: Be respectful. You own your content. Don\'t abuse the platform. We can remove content that violates these terms.',
  ),
  _LegalBlock(_BlockType.heading, '1. Eligibility'),
  _LegalBlock(
    _BlockType.paragraph,
    'You must be at least 13 years old to use InkSpaceX. If you are between 13 and 18, you represent that your parent or legal guardian has reviewed and agreed to these Terms on your behalf.',
  ),
  _LegalBlock(_BlockType.heading, '2. Your Account'),
  _LegalBlock(
    _BlockType.paragraph,
    'You are responsible for maintaining the security of your account credentials. You agree to:',
  ),
  _LegalBlock(
    _BlockType.bullet,
    'Provide accurate and complete information when creating your account',
  ),
  _LegalBlock(
    _BlockType.bullet,
    'Keep your login credentials secure and confidential',
  ),
  _LegalBlock(
    _BlockType.bullet,
    'Notify us immediately of any unauthorized access to your account',
  ),
  _LegalBlock(
    _BlockType.bullet,
    'Accept responsibility for all activity that occurs under your account',
  ),
  _LegalBlock(_BlockType.heading, '3. Your Content'),
  _LegalBlock(
    _BlockType.paragraph,
    'Ownership: You retain full ownership of all content you create, upload, or publish through InkSpaceX ("Your Content"), including writing, images, canvas layouts, and other creative works.',
  ),
  _LegalBlock(
    _BlockType.paragraph,
    'License to Us: By publishing Your Content on InkSpaceX, you grant us a worldwide, non-exclusive, royalty-free license to host, display, reproduce, and distribute Your Content solely for the purpose of operating and improving the Service. This license ends when you delete Your Content or your account.',
  ),
  _LegalBlock(
    _BlockType.paragraph,
    'License to Other Users: Content you publish to the public feed is viewable by other authenticated users of InkSpaceX. You grant other users a non-exclusive license to view and interact with your published content within the Service.',
  ),
  _LegalBlock(
    _BlockType.paragraph,
    'Unpublishing: You may unpublish or delete Your Content at any time. Once deleted, we will remove it from our servers within a reasonable timeframe.',
  ),
  _LegalBlock(_BlockType.heading, '4. Acceptable Use'),
  _LegalBlock(
    _BlockType.paragraph,
    'You agree not to use InkSpaceX to:',
  ),
  _LegalBlock(
    _BlockType.bullet,
    'Post content that is illegal, threatening, harassing, defamatory, or obscene',
  ),
  _LegalBlock(
    _BlockType.bullet,
    'Infringe on the intellectual property rights of others',
  ),
  _LegalBlock(
    _BlockType.bullet,
    'Upload malware, viruses, or any harmful code',
  ),
  _LegalBlock(_BlockType.bullet, 'Impersonate another person or entity'),
  _LegalBlock(
    _BlockType.bullet,
    'Spam, phish, or conduct any deceptive practices',
  ),
  _LegalBlock(
    _BlockType.bullet,
    'Attempt to gain unauthorized access to other users\' accounts or data',
  ),
  _LegalBlock(
    _BlockType.bullet,
    'Scrape, crawl, or use automated means to collect data from the Service',
  ),
  _LegalBlock(
    _BlockType.bullet,
    'Interfere with or disrupt the integrity or performance of the Service',
  ),
  _LegalBlock(
    _BlockType.bullet,
    'Post content that exploits, harms, or endangers minors',
  ),
  _LegalBlock(_BlockType.heading, '5. Content Moderation'),
  _LegalBlock(
    _BlockType.paragraph,
    'We reserve the right, but are not obligated, to review, monitor, and remove content that we determine violates these Terms or is otherwise harmful. We may also suspend or terminate accounts that repeatedly violate these Terms.',
  ),
  _LegalBlock(_BlockType.heading, '6. Intellectual Property'),
  _LegalBlock(
    _BlockType.paragraph,
    'The InkSpaceX name, logo, interface design, and underlying software are the property of InkSpaceX and are protected by intellectual property laws. You may not copy, modify, distribute, or reverse-engineer any part of the Service without our prior written consent.',
  ),
  _LegalBlock(_BlockType.heading, '7. Copyright Infringement (DMCA)'),
  _LegalBlock(
    _BlockType.paragraph,
    'We respect the intellectual property rights of others. If you believe that your copyrighted work has been copied in a way that constitutes copyright infringement, please contact us with the relevant details.',
  ),
  _LegalBlock(_BlockType.email, 'legal@inkspacex.com'),
  _LegalBlock(_BlockType.heading, '8. Third-Party Services'),
  _LegalBlock(
    _BlockType.paragraph,
    'InkSpaceX uses third-party services including Google Firebase and Google Sign-In. Your use of these services is subject to their respective terms of service and privacy policies.',
  ),
  _LegalBlock(_BlockType.heading, '9. Disclaimer of Warranties'),
  _LegalBlock(
    _BlockType.paragraph,
    'The Service is provided "as is" and "as available" without warranties of any kind, either express or implied, including but not limited to implied warranties of merchantability, fitness for a particular purpose, and non-infringement.',
  ),
  _LegalBlock(_BlockType.heading, '10. Limitation of Liability'),
  _LegalBlock(
    _BlockType.paragraph,
    'To the maximum extent permitted by applicable law, InkSpaceX shall not be liable for any indirect, incidental, special, consequential, or punitive damages, including but not limited to loss of profits, data, or goodwill.',
  ),
  _LegalBlock(_BlockType.heading, '11. Termination'),
  _LegalBlock(
    _BlockType.paragraph,
    'You may stop using the Service and delete your account at any time. We may suspend or terminate your access to the Service at any time, with or without cause, and with or without notice.',
  ),
  _LegalBlock(_BlockType.heading, '12. Changes to These Terms'),
  _LegalBlock(
    _BlockType.paragraph,
    'We may update these Terms from time to time. We will notify you of material changes through the app or via email at least 30 days before they take effect. Your continued use of the Service after the changes take effect constitutes acceptance.',
  ),
  _LegalBlock(_BlockType.heading, '13. Governing Law'),
  _LegalBlock(
    _BlockType.paragraph,
    'These Terms shall be governed by and construed in accordance with applicable laws, without regard to conflict of law principles. Any disputes shall be resolved through good-faith negotiation first, and if necessary, through binding arbitration.',
  ),
  _LegalBlock(_BlockType.heading, '14. Contact Us'),
  _LegalBlock(
    _BlockType.paragraph,
    'If you have questions about these Terms, contact us at:',
  ),
  _LegalBlock(_BlockType.email, 'support@inkspacex.com'),
];
