import 'dart:typed_data';
import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:image_picker/image_picker.dart';
import 'package:provider/provider.dart';
import 'package:inkspacex/provider/auth_provider.dart';
import 'package:inkspacex/provider/editor_provider.dart';
import 'package:inkspacex/provider/feed_provider.dart';
import 'package:inkspacex/provider/nav_provider.dart';
import 'package:inkspacex/provider/settings_provider.dart';
import 'package:inkspacex/ui/widgets/app_network_image.dart';
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

    final pending = editor.pendingOpsCount.value;
    if (pending > 0) {
      showCupertinoDialog(
        context: context,
        builder: (dialogCtx) => CupertinoAlertDialog(
          title: Text(
            "$pending unsynced edit${pending == 1 ? '' : 's'}",
            style: GoogleFonts.inter(fontWeight: FontWeight.w600),
          ),
          content: Padding(
            padding: const EdgeInsets.only(top: 8.0),
            child: Text(
              "You have changes that haven't reached the server yet. "
              "Logging out now will keep them queued locally — they'll "
              "push the next time you sign in. Discard to drop them.",
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
              onPressed: () async {
                Navigator.of(dialogCtx).pop();
                await editor.discardPendingOps();
                doLogout();
              },
              child: const Text("Discard & log out"),
            ),
            CupertinoDialogAction(
              onPressed: () {
                Navigator.of(dialogCtx).pop();
                doLogout();
              },
              child: const Text("Keep & log out"),
            ),
          ],
        ),
      );
      return;
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
              horizontal: 32.0,
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
  bool _isUploading = false;
  bool _isSaving = false;

  @override
  void initState() {
    super.initState();
    final user = context.read<AuthProvider>().currentUser;
    _nameController = TextEditingController(text: user?.name ?? '');
    _emailController = TextEditingController(text: user?.email ?? '');
  }

  @override
  void dispose() {
    _nameController.dispose();
    _emailController.dispose();
    super.dispose();
  }

  Future<void> _pickAndUploadPhoto() async {
    final picker = ImagePicker();
    final picked = await picker.pickImage(
      source: ImageSource.gallery,
      maxWidth: 512,
      imageQuality: 70,
    );
    if (picked == null) return;
    final Uint8List bytes = await picked.readAsBytes();
    if (!mounted) return;
    setState(() => _isUploading = true);
    try {
      await context.read<AuthProvider>().updateProfilePhoto(bytes);
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
    setState(() => _isSaving = true);
    try {
      await context.read<AuthProvider>().updateProfile(
        name: name,
        email: email,
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

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final bgColor = isDark ? const Color(0xFF000000) : const Color(0xFFFAFAFA);
    final textColor = isDark ? Colors.white : Colors.black;
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
          constraints: const BoxConstraints(maxWidth: 500),
          child: ListView(
            padding: const EdgeInsets.all(24),
            children: [
              Center(
                child: Stack(
                  children: [
                    CircleAvatar(
                      radius: 58,
                      backgroundColor: isDark
                          ? Colors.white.withValues(alpha: 0.1)
                          : Colors.black.withValues(alpha: 0.05),
                      child: _isUploading
                          ? const CupertinoActivityIndicator()
                          : ClipOval(
                              child: SizedBox(
                                width: 110,
                                height: 110,
                                child: user?.photoUrl != null
                                    ? AppNetworkImage(
                                        url: user!.photoUrl,
                                        meta: user.photoMeta,
                                        width: 110,
                                        height: 110,
                                        fit: BoxFit.cover,
                                      )
                                    : Container(
                                        color: isDark
                                            ? Colors.white
                                                .withValues(alpha: 0.2)
                                            : Colors.black
                                                .withValues(alpha: 0.08),
                                        alignment: Alignment.center,
                                        child: Text(
                                          (user?.name.isNotEmpty == true)
                                              ? user!.name[0].toUpperCase()
                                              : 'U',
                                          style: GoogleFonts.inter(
                                            fontSize: 40,
                                            fontWeight: FontWeight.bold,
                                            color: isDark
                                                ? Colors.white70
                                                : Colors.black87,
                                          ),
                                        ),
                                      ),
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
              const SizedBox(height: 40),
              _buildTextField(
                "Full Name",
                _nameController,
                isDark,
                textColor,
              ),
              const SizedBox(height: 16),
              _buildTextField(
                "Email Address",
                _emailController,
                isDark,
                textColor,
              ),
              const SizedBox(height: 32),
              ElevatedButton(
                onPressed: _isSaving ? null : _saveChanges,
                style: ElevatedButton.styleFrom(
                  backgroundColor: isDark ? Colors.white : Colors.black87,
                  foregroundColor: isDark ? Colors.black : Colors.white,
                  padding: const EdgeInsets.symmetric(vertical: 16),
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(12),
                  ),
                ),
                child: _isSaving
                    ? CupertinoActivityIndicator(
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
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildTextField(
    String label,
    TextEditingController controller,
    bool isDark,
    Color textColor,
  ) {
    return TextField(
      controller: controller,
      style: GoogleFonts.inter(color: textColor),
      decoration: InputDecoration(
        labelText: label,
        labelStyle: GoogleFonts.inter(color: textColor.withValues(alpha: 0.5)),
        filled: true,
        fillColor: isDark ? const Color(0xFF1A1A1A) : Colors.white,
        border: OutlineInputBorder(
          borderRadius: BorderRadius.circular(12),
          borderSide: BorderSide(
            color: isDark
                ? Colors.white.withValues(alpha: 0.1)
                : Colors.black.withValues(alpha: 0.1),
          ),
        ),
        enabledBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(12),
          borderSide: BorderSide(
            color: isDark
                ? Colors.white.withValues(alpha: 0.1)
                : Colors.black.withValues(alpha: 0.1),
          ),
        ),
        focusedBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(12),
          borderSide: BorderSide(
            color: isDark ? Colors.white70 : Colors.black87,
            width: 2,
          ),
        ),
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


