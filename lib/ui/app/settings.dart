import 'package:flutter/material.dart';

class SettingsPage extends StatefulWidget {
  const SettingsPage({super.key});

  @override
  State<SettingsPage> createState() => _SettingsPageState();
}

class _SettingsPageState extends State<SettingsPage> {
  void _confirmLogout() {
    showDialog(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text("Logout"),
        content: const Text(
          "Are you sure you want to log out of your account?",
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text("Cancel", style: TextStyle(color: Colors.grey)),
          ),
          ElevatedButton(
            style: ElevatedButton.styleFrom(backgroundColor: Colors.red),
            onPressed: () {
              Navigator.pop(context);
              ScaffoldMessenger.of(context).showSnackBar(
                const SnackBar(content: Text("Logged out successfully")),
              );
            },
            child: const Text("Logout", style: TextStyle(color: Colors.white)),
          ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: ListView(
        padding: const EdgeInsets.symmetric(horizontal: 16.0, vertical: 8.0),
        children: [
          // --- ACCOUNT SECTION ---
          _buildSectionHeader("ACCOUNT"),
          _buildSettingsCard(
            children: [
              SettingsTile(
                icon: Icons.person_outline,
                title: "User Profile",
                subtitle: "Manage your personal details",
                onTap: () => Navigator.push(
                  context,
                  MaterialPageRoute(builder: (_) => const ProfilePage()),
                ),
              ),
              SettingsTile(
                icon: Icons.shield_outlined,
                title: "Security",
                subtitle: "Password, biometrics, 2FA",
                onTap: () {},
              ),
            ],
          ),

          // --- PREFERENCES SECTION ---
          _buildSectionHeader("PREFERENCES"),
          _buildSettingsCard(
            children: [
              SettingsTile(
                icon: Icons.dark_mode_outlined,
                title: "Dark Mode",
                trailing: Switch(
                  value: false,
                  activeColor: Colors.white,
                  activeTrackColor: Colors.grey[600],
                  inactiveThumbColor: Colors.grey[400],

                  onChanged: (v) {},
                ),
              ),
            ],
          ),
          SettingsTile(
            icon: Icons.notifications_none_outlined,
            title: "Notifications",
            trailing: Switch(
              value: false,
              activeColor: Colors.white,
              activeTrackColor: Colors.grey[600],
              inactiveThumbColor: Colors.grey[400],
              inactiveTrackColor: Colors.grey[600],
              onChanged: (value) => {},
            ),
          ),
          SettingsTile(
            icon: Icons.language,
            title: "Language",
            subtitle: "English (US)",
            onTap: () => Navigator.push(
              context,
              MaterialPageRoute(builder: (_) => const LanguagePage()),
            ),
          ),
        ],
      ),
    );
  }

  // Helper to build Section Headers
  Widget _buildSectionHeader(String title) {
    return Padding(
      padding: const EdgeInsets.only(left: 4, bottom: 8, top: 24),
      child: Text(
        title,
        style: const TextStyle(
          fontSize: 12,
          fontWeight: FontWeight.bold,
          color: Colors.white, // White text on grey bg as seen in your image
          letterSpacing: 1.2,
        ),
      ),
    );
  }

  // Helper to build grouped cards with dividers
  Widget _buildSettingsCard({required List<Widget> children}) {
    // Interleave dividers between items
    List<Widget> separatedChildren = [];
    for (int i = 0; i < children.length; i++) {
      separatedChildren.add(children[i]);
      if (i < children.length - 1) {
        separatedChildren.add(
          Divider(color: Colors.grey[800], height: 1, thickness: 1),
        );
      }
    }

    return Container(
      decoration: BoxDecoration(borderRadius: BorderRadius.circular(12)),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: separatedChildren,
      ),
    );
  }
}

// --- CUSTOM SETTINGS TILE WIDGET ---
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
    return Material(
      color: Colors.transparent,
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(12), // Match card border radius
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
          child: Row(
            children: [
              // Circular Leading Icon
              Container(
                padding: const EdgeInsets.all(8),
                decoration: const BoxDecoration(
                  color: Color(0xFF2C2C2E), // Icon Background
                  shape: BoxShape.circle,
                ),
                child: Icon(icon, color: Colors.white, size: 20),
              ),
              const SizedBox(width: 16),

              // Title and Subtitle
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      title,
                      style: const TextStyle(
                        color: Colors.white,
                        fontSize: 15,
                        fontWeight: FontWeight.w500,
                      ),
                    ),
                    if (subtitle != null) ...[
                      const SizedBox(height: 4),
                      Text(
                        subtitle!,
                        style: const TextStyle(
                          color: Color(0xFFAAAAAA),
                          fontSize: 13,
                        ),
                      ),
                    ],
                  ],
                ),
              ),

              // Trailing Widget or Chevron
              if (trailing != null)
                trailing!
              else if (onTap != null)
                const Icon(
                  Icons.chevron_right,
                  color: Color(0xFF757575),
                  size: 22,
                ),
            ],
          ),
        ),
      ),
    );
  }
}

// ============================================================================
// SUB-PAGES (Styled in standard dark mode to match the settings vibe)
// ============================================================================

class ProfilePage extends StatelessWidget {
  const ProfilePage({super.key});
  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: const Color(0xFF121212),
      appBar: AppBar(
        title: const Text("User Profile"),
        backgroundColor: Colors.transparent,
      ),
      body: ListView(
        padding: const EdgeInsets.all(20),
        children: [
          const Center(
            child: CircleAvatar(
              radius: 50,
              backgroundColor: Color(0xFF2C2C2E),
              child: Icon(Icons.person, size: 50, color: Colors.white),
            ),
          ),
          const SizedBox(height: 30),
          _buildTextField("Full Name", "John Doe"),
          const SizedBox(height: 16),
          _buildTextField("Email Address", "john.doe@example.com"),
        ],
      ),
    );
  }

  Widget _buildTextField(String label, String initialValue) {
    return TextField(
      controller: TextEditingController(text: initialValue),
      style: const TextStyle(color: Colors.white),
      decoration: InputDecoration(
        labelText: label,
        labelStyle: const TextStyle(color: Colors.grey),
        filled: true,
        fillColor: const Color(0xFF1E1E1E),
        border: OutlineInputBorder(
          borderRadius: BorderRadius.circular(12),
          borderSide: BorderSide.none,
        ),
      ),
    );
  }
}

class LanguagePage extends StatefulWidget {
  const LanguagePage({super.key});
  @override
  State<LanguagePage> createState() => _LanguagePageState();
}

class _LanguagePageState extends State<LanguagePage> {
  String selectedLang = "English (US)";
  final List<String> languages = [
    "English (US)",
    "English (UK)",
    "Spanish",
    "French",
    "German",
  ];

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: const Color(0xFF121212),
      appBar: AppBar(
        title: const Text("Language"),
        backgroundColor: Colors.transparent,
      ),
      body: ListView.builder(
        itemCount: languages.length,
        itemBuilder: (context, index) {
          final lang = languages[index];
          return ListTile(
            title: Text(lang, style: const TextStyle(color: Colors.white)),
            trailing: selectedLang == lang
                ? const Icon(Icons.check, color: Colors.blueAccent)
                : null,
            onTap: () => setState(() => selectedLang = lang),
          );
        },
      ),
    );
  }
}

class PrivacyPage extends StatelessWidget {
  const PrivacyPage({super.key});
  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: const Color(0xFF121212),
      appBar: AppBar(
        title: const Text("Privacy Policy"),
        backgroundColor: Colors.transparent,
      ),
      body: const SingleChildScrollView(
        padding: EdgeInsets.all(20),
        child: Text(
          "Your privacy is critically important to us. \n\nWe collect minimal data to ensure our services run smoothly. We do not sell your personal data to third parties.",
          style: TextStyle(color: Colors.white70, fontSize: 16, height: 1.5),
        ),
      ),
    );
  }
}

class AboutPage extends StatelessWidget {
  const AboutPage({super.key});
  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: const Color(0xFF121212),
      appBar: AppBar(
        title: const Text("About"),
        backgroundColor: Colors.transparent,
      ),
      body: Center(
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            const Icon(Icons.settings_suggest, size: 80, color: Colors.grey),
            const SizedBox(height: 20),
            const Text(
              "Settings App",
              style: TextStyle(
                color: Colors.white,
                fontSize: 24,
                fontWeight: FontWeight.bold,
              ),
            ),
            const SizedBox(height: 8),
            Text("Version 2.0.1", style: TextStyle(color: Colors.grey[400])),
          ],
        ),
      ),
    );
  }
}
