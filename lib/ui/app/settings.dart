import 'dart:typed_data';
import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:image_picker/image_picker.dart';
import 'package:provider/provider.dart';
import 'package:inkspacex/models/user_model.dart';
import 'package:inkspacex/provider/auth_provider.dart';
import 'package:inkspacex/provider/editor_provider.dart';
import 'package:inkspacex/provider/feed_provider.dart';
import 'package:inkspacex/provider/nav_provider.dart';
import 'package:inkspacex/provider/settings_provider.dart';
import 'package:inkspacex/ui/widgets/app_network_image.dart';
import 'package:inkspacex/ui/widgets/app_spinner.dart';
import 'package:inkspacex/ui/widgets/image_crop_page.dart';
class SettingsPage extends StatelessWidget {
  const SettingsPage({super.key});

  void _confirmLogout(BuildContext context) {
    final auth = context.read<AuthProvider>();
    final feed = context.read<FeedProvider>();
    final editor = context.read<EditorProvider>();
    final nav = context.read<NavProvider>();

    void doLogout() {
      feed.clearFeed();
      editor.clearData();
      nav.setIndex(SelectedPage.story);
      auth.logout();
    }

    showCupertinoDialog(
      context: context,
      builder: (dialogCtx) => CupertinoAlertDialog(
        title: Text(
          "Logout",
          style: GoogleFonts.inter(fontWeight: FontWeight.w600),
        ),
        content: Padding(
          padding: const EdgeInsets.only(top: 8.0),
          child: Text(
            "Are you sure you want to log out of your account?",
            style: GoogleFonts.inter(),
          ),
        ),
        actions: [
          CupertinoDialogAction(
            onPressed: () => Navigator.of(dialogCtx).pop(),
            child: const Text("Cancel"),
          ),
          CupertinoDialogAction(
            isDestructiveAction: true,
            onPressed: () {
              Navigator.of(dialogCtx).pop();
              doLogout();
            },
            child: const Text("Logout"),
          ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final textColor = isDark ? Colors.white : Colors.black;
    final cardColor = isDark ? const Color(0xFF1A1A1A) : Colors.white;
    final subtleBorder = isDark
        ? Colors.white.withValues(alpha: 0.1)
        : Colors.black.withValues(alpha: 0.1);

    return Scaffold(
      backgroundColor: Colors.transparent, // Background handled by main layout
      body: Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(
            maxWidth: 680,
          ), // Premium readable width
          child: ListView(
            padding: const EdgeInsets.symmetric(
              horizontal: 16.0,
              vertical: 16.0,
            ),
            children: [
              // --- PREFERENCES SECTION ---
              _buildSectionHeader("PREFERENCES", textColor),
              Consumer<SettingsProvider>(
                builder: (context, provider, child) {
                  final isDarkActive = provider.themeMode == ThemeMode.dark ||
                      (provider.themeMode == ThemeMode.system &&
                          Theme.of(context).brightness == Brightness.dark);
                  return _buildSettingsCard(
                    cardColor: cardColor,
                    borderColor: subtleBorder,
                    children: [
                      SettingsTile(
                        icon: CupertinoIcons.moon,
                        title: "Dark Mode",
                        trailing: CupertinoSwitch(
                          value: isDarkActive,
                          activeTrackColor: CupertinoColors.activeGreen,
                          onChanged: (v) => provider.toggleTheme(v),
                        ),
                      ),
                      _buildDivider(subtleBorder),
                      SettingsTile(
                        icon: CupertinoIcons.bell,
                        title: "Notifications",
                        trailing: CupertinoSwitch(
                          value: provider.notificationsEnabled,
                          activeTrackColor: CupertinoColors.activeGreen,
                          onChanged: (v) => provider.toggleNotifications(v),
                        ),
                      ),
                      _buildDivider(subtleBorder),
                      SettingsTile(
                        icon: CupertinoIcons.globe,
                        title: "Language",
                        subtitle: provider.selectedLanguage,
                        onTap: () => context.push('/language'),
                      ),
                    ],
                  );
                },
              ),

              const SizedBox(height: 32),

              _buildSectionHeader("CONTENT", textColor),
              _buildSettingsCard(
                cardColor: cardColor,
                borderColor: subtleBorder,
                children: [
                  SettingsTile(
                    icon: CupertinoIcons.slider_horizontal_3,
                    title: "Feed Preferences",
                    subtitle: "Genres and writing types for your feed",
                    onTap: () => context.push('/feed-preferences'),
                  ),
                  _buildDivider(subtleBorder),
                  SettingsTile(
                    icon: CupertinoIcons.doc_text,
                    title: "My Drafts",
                    subtitle: "Unpublished posts saved for later",
                    onTap: () => context.push('/drafts'),
                  ),
                  _buildDivider(subtleBorder),
                  SettingsTile(
                    icon: CupertinoIcons.bookmark,
                    title: "Saved Posts",
                    subtitle: "Posts you've bookmarked",
                    onTap: () => context.push('/saved'),
                  ),
                  _buildDivider(subtleBorder),
                  SettingsTile(
                    icon: Icons.star_outline_rounded,
                    title: "Favourites",
                    subtitle: "Posts you've starred",
                    onTap: () => context.push('/favorites'),
                  ),
                ],
              ),

              const SizedBox(height: 32),

              // --- SUPPORT SECTION ---
              _buildSectionHeader("SUPPORT", textColor),
              _buildSettingsCard(
                cardColor: cardColor,
                borderColor: subtleBorder,
                children: [
                  SettingsTile(
                    icon: CupertinoIcons.chat_bubble_text,
                    title: "Send Feedback",
                    subtitle: "Report bugs, suggest features, share praise",
                    onTap: () => context.push('/feedback'),
                  ),
                ],
              ),

              const SizedBox(height: 32),

              // --- LEGAL SECTION ---
              _buildSectionHeader("LEGAL", textColor),
              _buildSettingsCard(
                cardColor: cardColor,
                borderColor: subtleBorder,
                children: [
                  SettingsTile(
                    icon: CupertinoIcons.shield,
                    title: "Privacy Policy",
                    subtitle: "How we handle your data",
                    onTap: () => context.push('/privacy-policy'),
                  ),
                  _buildDivider(subtleBorder),
                  SettingsTile(
                    icon: CupertinoIcons.doc_plaintext,
                    title: "Terms of Service",
                    subtitle: "Rules and guidelines",
                    onTap: () => context.push('/terms-of-service'),
                  ),
                ],
              ),

              const SizedBox(height: 24),

              // --- LOGOUT BUTTON ---
              CupertinoButton(
                padding: const EdgeInsets.symmetric(vertical: 16),
                color: isDark
                    ? Colors.redAccent.withValues(alpha: 0.1)
                    : Colors.red.withValues(alpha: 0.1),
                borderRadius: BorderRadius.circular(16),
                onPressed: () => _confirmLogout(context),
                child: Text(
                  "Log Out",
                  style: GoogleFonts.inter(
                    color: Colors.redAccent,
                    fontWeight: FontWeight.w600,
                    fontSize: 15,
                  ),
                ),
              ),
              const SizedBox(height: 48),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildSectionHeader(String title, Color textColor) {
    return Padding(
      padding: const EdgeInsets.only(left: 16, bottom: 12),
      child: Text(
        title,
        style: GoogleFonts.inter(
          fontSize: 12,
          fontWeight: FontWeight.w700,
          color: textColor.withValues(alpha: 0.4),
          letterSpacing: 1.2,
        ),
      ),
    );
  }

  Widget _buildSettingsCard({
    required Color cardColor,
    required Color borderColor,
    required List<Widget> children,
  }) {
    return Container(
      decoration: BoxDecoration(
        color: cardColor,
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: borderColor),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: children,
      ),
    );
  }

  Widget _buildDivider(Color color) {
    return Padding(
      padding: const EdgeInsets.only(left: 60.0), // iOS style indent
      child: Divider(color: color, height: 1, thickness: 1),
    );
  }
}

// --- CUSTOM SETTINGS TILE ---
class SettingsTile extends StatelessWidget {
  final IconData icon;
  final String title;
  final String? subtitle;
  final Widget? trailing;
  final VoidCallback? onTap;

  const SettingsTile({
    super.key,
    required this.icon,
    required this.title,
    this.subtitle,
    this.trailing,
    this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final textColor = isDark ? Colors.white : Colors.black;

    return Material(
      color: Colors.transparent,
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(16),
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 16),
          child: Row(
            children: [
              // Premium Icon Container
              Container(
                padding: const EdgeInsets.all(8),
                decoration: BoxDecoration(
                  color: isDark
                      ? Colors.white.withValues(alpha: 0.05)
                      : Colors.black.withValues(alpha: 0.04),
                  shape: BoxShape.circle,
                ),
                child: Icon(
                  icon,
                  color: textColor.withValues(alpha: 0.8),
                  size: 20,
                ),
              ),
              const SizedBox(width: 16),

              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      title,
                      style: GoogleFonts.inter(
                        color: textColor,
                        fontSize: 15,
                        fontWeight: FontWeight.w500,
                      ),
                    ),
                    if (subtitle != null) ...[
                      const SizedBox(height: 4),
                      Text(
                        subtitle!,
                        style: GoogleFonts.inter(
                          color: textColor.withValues(alpha: 0.5),
                          fontSize: 13,
                        ),
                      ),
                    ],
                  ],
                ),
              ),

              if (trailing != null)
                trailing!
              else if (onTap != null)
                Icon(
                  CupertinoIcons.chevron_right,
                  color: textColor.withValues(alpha: 0.3),
                  size: 18,
                ),
            ],
          ),
        ),
      ),
    );
  }
}

// --- SUB PAGES (Adapting dynamically to Light/Dark mode) ---
class ProfilePage extends StatefulWidget {
  const ProfilePage({super.key});

  @override
  State<ProfilePage> createState() => _ProfilePageState();
}

class _ProfilePageState extends State<ProfilePage> {
  late TextEditingController _nameController;
  late TextEditingController _emailController;
  late TextEditingController _bioController;
  late final Map<String, TextEditingController> _socialControllers;
  bool _isUploading = false;
  bool _isSaving = false;

  @override
  void initState() {
    super.initState();
    final user = context.read<AuthProvider>().currentUser;
    _nameController = TextEditingController(text: user?.name ?? '');
    _emailController = TextEditingController(text: user?.email ?? '');
    _bioController = TextEditingController(text: user?.bio ?? '');
    _socialControllers = {
      for (final key in kSocialLinkKeys)
        key: TextEditingController(text: user?.socialLinks[key] ?? ''),
    };
  }

  @override
  void dispose() {
    _nameController.dispose();
    _emailController.dispose();
    _bioController.dispose();
    for (final c in _socialControllers.values) {
      c.dispose();
    }
    super.dispose();
  }

  Future<void> _pickAndUploadPhoto() async {
    final picker = ImagePicker();
    final picked = await picker.pickImage(source: ImageSource.gallery);
    if (picked == null) return;
    final Uint8List raw = await picked.readAsBytes();
    if (!mounted) return;
    final cropped = await Navigator.of(context).push<Uint8List>(
      MaterialPageRoute(
        fullscreenDialog: true,
        builder: (_) => ImageCropPage(
          imageBytes: raw,
          aspectRatio: 1,
          circleOverlay: true,
          title: 'Adjust photo',
          confirmLabel: 'Use this photo',
        ),
      ),
    );
    if (cropped == null || !mounted) return;
    setState(() => _isUploading = true);
    try {
      await context.read<AuthProvider>().updateProfilePhoto(cropped);
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Failed to upload photo: $e')),
        );
      }
    } finally {
      if (mounted) setState(() => _isUploading = false);
    }
  }

  Future<void> _saveChanges() async {
    final name = _nameController.text.trim();
    final email = _emailController.text.trim();
    if (name.isEmpty || email.isEmpty) return;
    final bioRaw = _bioController.text.trim();
    final socials = <String, String>{
      for (final entry in _socialControllers.entries)
        if (entry.value.text.trim().isNotEmpty)
          entry.key: entry.value.text.trim(),
    };
    setState(() => _isSaving = true);
    try {
      await context.read<AuthProvider>().updateProfile(
        name: name,
        email: email,
        bio: bioRaw.isEmpty ? null : bioRaw,
        clearBio: bioRaw.isEmpty,
        socialLinks: socials,
      );
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Profile updated')),
        );
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Failed to save: $e')),
        );
      }
    } finally {
      if (mounted) setState(() => _isSaving = false);
    }
  }

  String _socialLabelFor(String key) {
    switch (key) {
      case 'website':
        return 'Website';
      case 'twitter':
        return 'Twitter / X';
      case 'instagram':
        return 'Instagram';
      case 'linkedin':
        return 'LinkedIn';
      case 'goodreads':
        return 'Goodreads';
    }
    return key;
  }

  String _socialHintFor(String key) {
    switch (key) {
      case 'website':
        return 'https://yoursite.com';
      case 'twitter':
        return '@handle or full URL';
      case 'instagram':
        return '@handle';
      case 'linkedin':
        return 'linkedin.com/in/username';
      case 'goodreads':
        return 'goodreads.com/author/show/...';
    }
    return '';
  }

  IconData _socialIconFor(String key) {
    switch (key) {
      case 'website':
        return CupertinoIcons.link;
      case 'twitter':
        return CupertinoIcons.chat_bubble;
      case 'instagram':
        return CupertinoIcons.camera;
      case 'linkedin':
        return CupertinoIcons.briefcase;
      case 'goodreads':
        return CupertinoIcons.book;
    }
    return CupertinoIcons.link;
  }

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final bgColor = isDark ? const Color(0xFF000000) : const Color(0xFFFAFAFA);
    final textColor = isDark ? Colors.white : Colors.black;
    final cardColor = isDark ? const Color(0xFF1A1A1A) : Colors.white;
    final user = context.watch<AuthProvider>().currentUser;

    return Scaffold(
      backgroundColor: bgColor,
      appBar: AppBar(
        title: Text(
          "User Profile",
          style: GoogleFonts.inter(
            color: textColor,
            fontSize: 16,
            fontWeight: FontWeight.w600,
          ),
        ),
        backgroundColor: Colors.transparent,
        elevation: 0,
        iconTheme: IconThemeData(color: textColor),
      ),
      body: Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 520),
          child: ListView(
            padding: const EdgeInsets.fromLTRB(20, 12, 20, 32),
            children: [
              const SizedBox(height: 8),
              Center(
                child: Stack(
                  children: [
                    Container(
                      padding: const EdgeInsets.all(3),
                      decoration: BoxDecoration(
                        shape: BoxShape.circle,
                        border: Border.all(
                          color: textColor.withValues(alpha: 0.08),
                          width: 1,
                        ),
                      ),
                      child: ClipOval(
                        child: SizedBox(
                          width: 108,
                          height: 108,
                          child: _isUploading
                              ? Container(
                                  color: isDark
                                      ? Colors.white.withValues(alpha: 0.08)
                                      : Colors.black.withValues(alpha: 0.05),
                                  alignment: Alignment.center,
                                  child: const AppSpinner(),
                                )
                              : (user?.photoUrl != null
                                  ? AppNetworkImage(
                                      url: user!.photoUrl,
                                      meta: user.photoMeta,
                                      width: 108,
                                      height: 108,
                                      fit: BoxFit.cover,
                                    )
                                  : Container(
                                      color: isDark
                                          ? Colors.white
                                              .withValues(alpha: 0.08)
                                          : Colors.black
                                              .withValues(alpha: 0.05),
                                      alignment: Alignment.center,
                                      child: Text(
                                        (user?.name.isNotEmpty == true)
                                            ? user!.name[0].toUpperCase()
                                            : 'U',
                                        style: GoogleFonts.inter(
                                          fontSize: 36,
                                          fontWeight: FontWeight.w600,
                                          color:
                                              textColor.withValues(alpha: 0.7),
                                        ),
                                      ),
                                    )),
                        ),
                      ),
                    ),
                    Positioned(
                      bottom: 0,
                      right: 0,
                      child: GestureDetector(
                        onTap: _isUploading ? null : _pickAndUploadPhoto,
                        child: Container(
                          padding: const EdgeInsets.all(8),
                          decoration: BoxDecoration(
                            color: isDark ? Colors.white : Colors.black87,
                            shape: BoxShape.circle,
                            border: Border.all(color: bgColor, width: 3),
                          ),
                          child: Icon(
                            CupertinoIcons.camera,
                            size: 16,
                            color: isDark ? Colors.black : Colors.white,
                          ),
                        ),
                      ),
                    ),
                  ],
                ),
              ),
              const SizedBox(height: 12),
              Center(
                child: Text(
                  user?.name.isNotEmpty == true ? user!.name : 'Reader',
                  style: GoogleFonts.playfairDisplay(
                    fontSize: 20,
                    fontWeight: FontWeight.w700,
                    color: textColor,
                  ),
                ),
              ),
              const SizedBox(height: 4),
              Center(
                child: Text(
                  user?.email ?? '',
                  style: GoogleFonts.inter(
                    fontSize: 13,
                    color: textColor.withValues(alpha: 0.55),
                  ),
                ),
              ),
              const SizedBox(height: 36),
              _buildSectionHeader(context, 'Personal Information', textColor),
              _buildFieldCard(
                cardColor: cardColor,
                isDark: isDark,
                children: [
                  _buildLabeledField(
                    label: 'Full Name',
                    controller: _nameController,
                    isDark: isDark,
                    textColor: textColor,
                    hint: 'Your display name',
                  ),
                  _buildFieldDivider(isDark),
                  _buildLabeledField(
                    label: 'Email Address',
                    controller: _emailController,
                    isDark: isDark,
                    textColor: textColor,
                    hint: 'name@example.com',
                    keyboardType: TextInputType.emailAddress,
                  ),
                ],
              ),
              const SizedBox(height: 8),
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 6),
                child: Text(
                  'Used for sign-in and account notifications.',
                  style: GoogleFonts.inter(
                    fontSize: 12,
                    color: textColor.withValues(alpha: 0.5),
                  ),
                ),
              ),
              const SizedBox(height: 28),
              _buildSectionHeader(context, 'About', textColor),
              _buildFieldCard(
                cardColor: cardColor,
                isDark: isDark,
                children: [
                  _buildBioField(
                    isDark: isDark,
                    textColor: textColor,
                  ),
                ],
              ),
              const SizedBox(height: 8),
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 6),
                child: Text(
                  'A short intro shown on your public profile.',
                  style: GoogleFonts.inter(
                    fontSize: 12,
                    color: textColor.withValues(alpha: 0.5),
                  ),
                ),
              ),
              const SizedBox(height: 28),
              _buildSectionHeader(context, 'Social Links', textColor),
              _buildFieldCard(
                cardColor: cardColor,
                isDark: isDark,
                children: [
                  for (var i = 0; i < kSocialLinkKeys.length; i++) ...[
                    _buildSocialField(
                      keyName: kSocialLinkKeys[i],
                      isDark: isDark,
                      textColor: textColor,
                    ),
                    if (i < kSocialLinkKeys.length - 1)
                      _buildFieldDivider(isDark),
                  ],
                ],
              ),
              const SizedBox(height: 8),
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 6),
                child: Text(
                  'Other readers will see these on your profile.',
                  style: GoogleFonts.inter(
                    fontSize: 12,
                    color: textColor.withValues(alpha: 0.5),
                  ),
                ),
              ),
              const SizedBox(height: 28),
              SizedBox(
                width: double.infinity,
                child: ElevatedButton(
                  onPressed: _isSaving ? null : _saveChanges,
                  style: ElevatedButton.styleFrom(
                    backgroundColor: isDark ? Colors.white : Colors.black87,
                    foregroundColor: isDark ? Colors.black : Colors.white,
                    padding: const EdgeInsets.symmetric(vertical: 16),
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(14),
                    ),
                    elevation: 0,
                  ),
                  child: _isSaving
                      ? AppSpinner(
                          color: isDark ? Colors.black : Colors.white,
                        )
                      : Text(
                          "Save Changes",
                          style: GoogleFonts.inter(
                            fontWeight: FontWeight.w600,
                            fontSize: 15,
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

  Widget _buildSectionHeader(
    BuildContext context,
    String label,
    Color textColor,
  ) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(6, 0, 6, 10),
      child: Text(
        label.toUpperCase(),
        style: GoogleFonts.inter(
          fontSize: 11,
          fontWeight: FontWeight.w600,
          letterSpacing: 1.1,
          color: textColor.withValues(alpha: 0.5),
        ),
      ),
    );
  }

  Widget _buildFieldCard({
    required Color cardColor,
    required bool isDark,
    required List<Widget> children,
  }) {
    return Container(
      decoration: BoxDecoration(
        color: cardColor,
        borderRadius: BorderRadius.circular(14),
        border: Border.all(
          color: isDark
              ? Colors.white.withValues(alpha: 0.06)
              : Colors.black.withValues(alpha: 0.06),
        ),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: children,
      ),
    );
  }

  Widget _buildFieldDivider(bool isDark) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16),
      child: Divider(
        height: 1,
        thickness: 1,
        color: isDark
            ? Colors.white.withValues(alpha: 0.06)
            : Colors.black.withValues(alpha: 0.06),
      ),
    );
  }

  Widget _buildBioField({required bool isDark, required Color textColor}) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 12, 16, 12),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            'Bio',
            style: GoogleFonts.inter(
              fontSize: 12,
              fontWeight: FontWeight.w500,
              color: textColor.withValues(alpha: 0.55),
            ),
          ),
          const SizedBox(height: 4),
          TextField(
            controller: _bioController,
            maxLines: null,
            minLines: 3,
            maxLength: 1000,
            style: GoogleFonts.inter(
              color: textColor,
              fontSize: 15,
              fontWeight: FontWeight.w500,
              height: 1.45,
            ),
            decoration: InputDecoration(
              hintText: 'Tell readers a little about yourself…',
              hintStyle: GoogleFonts.inter(
                color: textColor.withValues(alpha: 0.3),
                fontSize: 15,
              ),
              isDense: true,
              contentPadding: EdgeInsets.zero,
              border: InputBorder.none,
              enabledBorder: InputBorder.none,
              focusedBorder: InputBorder.none,
              counterStyle: GoogleFonts.inter(
                fontSize: 11,
                color: textColor.withValues(alpha: 0.4),
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildSocialField({
    required String keyName,
    required bool isDark,
    required Color textColor,
  }) {
    final controller = _socialControllers[keyName]!;
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 12, 16, 12),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Padding(
            padding: const EdgeInsets.only(top: 22),
            child: Icon(
              _socialIconFor(keyName),
              size: 18,
              color: textColor.withValues(alpha: 0.55),
            ),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  _socialLabelFor(keyName),
                  style: GoogleFonts.inter(
                    fontSize: 12,
                    fontWeight: FontWeight.w500,
                    color: textColor.withValues(alpha: 0.55),
                  ),
                ),
                const SizedBox(height: 4),
                TextField(
                  controller: controller,
                  keyboardType: TextInputType.url,
                  autocorrect: false,
                  style: GoogleFonts.inter(
                    color: textColor,
                    fontSize: 15,
                    fontWeight: FontWeight.w500,
                  ),
                  decoration: InputDecoration(
                    hintText: _socialHintFor(keyName),
                    hintStyle: GoogleFonts.inter(
                      color: textColor.withValues(alpha: 0.3),
                      fontSize: 15,
                    ),
                    isDense: true,
                    contentPadding: EdgeInsets.zero,
                    border: InputBorder.none,
                    enabledBorder: InputBorder.none,
                    focusedBorder: InputBorder.none,
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildLabeledField({
    required String label,
    required TextEditingController controller,
    required bool isDark,
    required Color textColor,
    String? hint,
    TextInputType? keyboardType,
  }) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 12, 16, 12),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            label,
            style: GoogleFonts.inter(
              fontSize: 12,
              fontWeight: FontWeight.w500,
              color: textColor.withValues(alpha: 0.55),
            ),
          ),
          const SizedBox(height: 4),
          TextField(
            controller: controller,
            keyboardType: keyboardType,
            style: GoogleFonts.inter(
              color: textColor,
              fontSize: 15,
              fontWeight: FontWeight.w500,
            ),
            decoration: InputDecoration(
              hintText: hint,
              hintStyle: GoogleFonts.inter(
                color: textColor.withValues(alpha: 0.3),
                fontSize: 15,
              ),
              isDense: true,
              contentPadding: EdgeInsets.zero,
              border: InputBorder.none,
              enabledBorder: InputBorder.none,
              focusedBorder: InputBorder.none,
            ),
          ),
        ],
      ),
    );
  }
}

class LanguagePage extends StatelessWidget {
  const LanguagePage({super.key});

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final bgColor = isDark ? const Color(0xFF000000) : const Color(0xFFFAFAFA);
    final textColor = isDark ? Colors.white : Colors.black;

    return Scaffold(
      backgroundColor: bgColor,
      appBar: AppBar(
        title: Text(
          "Language",
          style: GoogleFonts.inter(
            color: textColor,
            fontSize: 16,
            fontWeight: FontWeight.w600,
          ),
        ),
        backgroundColor: Colors.transparent,
        elevation: 0,
        iconTheme: IconThemeData(color: textColor),
      ),
      body: Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 500),
          child: Consumer<SettingsProvider>(
            builder: (context, provider, child) {
              return ListView.separated(
                padding: const EdgeInsets.all(24),
                itemCount: provider.availableLanguages.length,
                separatorBuilder: (context, index) => Divider(
                  color: isDark
                      ? Colors.white.withValues(alpha: 0.05)
                      : Colors.black.withValues(alpha: 0.05),
                  height: 1,
                ),
                itemBuilder: (context, index) {
                  final lang = provider.availableLanguages[index];
                  final isSelected = provider.selectedLanguage == lang;
                  return ListTile(
                    contentPadding: const EdgeInsets.symmetric(
                      horizontal: 16,
                      vertical: 4,
                    ),
                    title: Text(
                      lang,
                      style: GoogleFonts.inter(
                        color: textColor,
                        fontWeight: isSelected
                            ? FontWeight.w600
                            : FontWeight.w400,
                      ),
                    ),
                    trailing: isSelected
                        ? Icon(
                            CupertinoIcons.check_mark,
                            color: isDark ? Colors.white70 : Colors.black87,
                            size: 20,
                          )
                        : null,
                    onTap: () => provider.setLanguage(lang),
                  );
                },
              );
            },
          ),
        ),
      ),
    );
  }
}


