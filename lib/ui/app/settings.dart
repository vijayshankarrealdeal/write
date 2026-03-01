import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:provider/provider.dart';
import 'package:writer/provider/settings_provider.dart';
import 'package:writer/provider/auth_provider.dart';

class SettingsPage extends StatelessWidget {
  const SettingsPage({super.key});

  void _confirmLogout(BuildContext context) {
    showCupertinoDialog(
      context: context,
      builder: (context) => CupertinoAlertDialog(
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
            onPressed: () => Navigator.pop(context),
            child: const Text("Cancel"),
          ),
          CupertinoDialogAction(
            isDestructiveAction: true,
            onPressed: () {
              Navigator.pop(context);
              context.read<AuthProvider>().logout(); // Call logout
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
    final cardColor = isDark ? const Color(0xFF1E293B) : Colors.white;
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
              // --- ACCOUNT SECTION ---
              _buildSectionHeader("ACCOUNT", textColor),
              _buildSettingsCard(
                cardColor: cardColor,
                borderColor: subtleBorder,
                children: [
                  SettingsTile(
                    icon: CupertinoIcons.person,
                    title: "User Profile",
                    subtitle: "Manage your personal details",
                    onTap: () => Navigator.push(
                      context,
                      MaterialPageRoute(builder: (_) => const ProfilePage()),
                    ),
                  ),
                  _buildDivider(subtleBorder),
                  SettingsTile(
                    icon: CupertinoIcons.shield,
                    title: "Security",
                    subtitle: "Password, biometrics, 2FA",
                    onTap: () {},
                  ),
                ],
              ),

              const SizedBox(height: 32),

              // --- PREFERENCES SECTION ---
              _buildSectionHeader("PREFERENCES", textColor),
              Consumer<SettingsProvider>(
                builder: (context, provider, child) {
                  return _buildSettingsCard(
                    cardColor: cardColor,
                    borderColor: subtleBorder,
                    children: [
                      SettingsTile(
                        icon: CupertinoIcons.moon,
                        title: "Dark Mode",
                        trailing: CupertinoSwitch(
                          value: provider.themeMode == ThemeMode.dark,
                          activeColor: isDark ? Colors.white : Colors.black,
                          onChanged: (v) => provider.toggleTheme(v),
                        ),
                      ),
                      _buildDivider(subtleBorder),
                      SettingsTile(
                        icon: CupertinoIcons.bell,
                        title: "Notifications",
                        trailing: CupertinoSwitch(
                          value: provider.notificationsEnabled,
                          activeColor: isDark ? Colors.white : Colors.black,
                          onChanged: (v) => provider.toggleNotifications(v),
                        ),
                      ),
                      _buildDivider(subtleBorder),
                      SettingsTile(
                        icon: CupertinoIcons.globe,
                        title: "Language",
                        subtitle: provider.selectedLanguage,
                        onTap: () => Navigator.push(
                          context,
                          MaterialPageRoute(
                            builder: (_) => const LanguagePage(),
                          ),
                        ),
                      ),
                    ],
                  );
                },
              ),

              const SizedBox(height: 48),

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
class ProfilePage extends StatelessWidget {
  const ProfilePage({super.key});
  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final bgColor = isDark ? const Color(0xFF0F172A) : const Color(0xFFFAFAFA);
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
                      backgroundColor: Colors.blueAccent.withValues(alpha: 0.1),
                      child: CircleAvatar(
                        radius: 55,
                        backgroundColor: Colors.blueAccent.withValues(
                          alpha: 0.2,
                        ),
                        child: Text(
                          user?.name.substring(0, 1).toUpperCase() ?? 'U',
                          style: GoogleFonts.inter(
                            fontSize: 40,
                            fontWeight: FontWeight.bold,
                            color: Colors.blueAccent,
                          ),
                        ),
                      ),
                    ),
                    Positioned(
                      bottom: 0,
                      right: 0,
                      child: Container(
                        padding: const EdgeInsets.all(8),
                        decoration: BoxDecoration(
                          color: Colors.blueAccent,
                          shape: BoxShape.circle,
                          border: Border.all(color: bgColor, width: 3),
                        ),
                        child: const Icon(
                          CupertinoIcons.camera,
                          size: 16,
                          color: Colors.white,
                        ),
                      ),
                    ),
                  ],
                ),
              ),
              const SizedBox(height: 40),
              _buildTextField(
                "Full Name",
                user?.name ?? "User",
                isDark,
                textColor,
              ),
              const SizedBox(height: 16),
              _buildTextField(
                "Email Address",
                user?.email ?? "user@example.com",
                isDark,
                textColor,
              ),
              const SizedBox(height: 32),
              ElevatedButton(
                onPressed: () {},
                style: ElevatedButton.styleFrom(
                  backgroundColor: Colors.blueAccent,
                  foregroundColor: Colors.white,
                  padding: const EdgeInsets.symmetric(vertical: 16),
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(12),
                  ),
                ),
                child: Text(
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
    String initialValue,
    bool isDark,
    Color textColor,
  ) {
    return TextField(
      controller: TextEditingController(text: initialValue),
      style: GoogleFonts.inter(color: textColor),
      decoration: InputDecoration(
        labelText: label,
        labelStyle: GoogleFonts.inter(color: textColor.withValues(alpha: 0.5)),
        filled: true,
        fillColor: isDark ? const Color(0xFF1E293B) : Colors.white,
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
          borderSide: const BorderSide(color: Colors.blueAccent, width: 2),
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
    final bgColor = isDark ? const Color(0xFF0F172A) : const Color(0xFFFAFAFA);
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
                separatorBuilder: (_, __) => Divider(
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
                        ? const Icon(
                            CupertinoIcons.check_mark,
                            color: Colors.blueAccent,
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
