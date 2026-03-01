// --- USER PROFILE PAGE ---
import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';

class ProfilePage extends StatelessWidget {
  const ProfilePage({super.key});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text("User Profile")),
      body: ListView(
        padding: const EdgeInsets.all(20),
        children: [
          const Center(
            child: CircleAvatar(
              radius: 50,
              backgroundImage: NetworkImage(
                "https://ui-avatars.com/api/?name=John+Doe&size=200",
              ),
            ),
          ),
          const SizedBox(height: 20),
          TextFormField(
            initialValue: "John Doe",
            decoration: const InputDecoration(
              labelText: "Full Name",
              border: OutlineInputBorder(),
            ),
          ),
          const SizedBox(height: 16),
          TextFormField(
            initialValue: "john.doe@example.com",
            decoration: const InputDecoration(
              labelText: "Email",
              border: OutlineInputBorder(),
            ),
            keyboardType: TextInputType.emailAddress,
          ),
          const SizedBox(height: 32),
          ElevatedButton(
            onPressed: () {
              Navigator.pop(context);
              showDialog(
                context: context,
                builder: (context) => AlertDialog(
                  content: Text(
                    "Profile updated successfully!",
                    style: GoogleFonts.inter(),
                  ),
                ),
              );
            },
            style: ElevatedButton.styleFrom(
              padding: const EdgeInsets.symmetric(vertical: 16),
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(12),
              ),
            ),
            child: const Text("Save Changes"),
          ),
        ],
      ),
    );
  }
}

// --- LANGUAGE SELECTION PAGE ---
class LanguagePage extends StatefulWidget {
  const LanguagePage({super.key});

  @override
  State<LanguagePage> createState() => _LanguagePageState();
}

class _LanguagePageState extends State<LanguagePage> {
  String selectedLang = "English";
  final List<String> languages = [
    "English",
    "Spanish",
    "French",
    "German",
    "Chinese",
    "Arabic",
  ];

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text("Language")),
      body: ListView.separated(
        itemCount: languages.length,
        separatorBuilder: (context, index) => const Divider(height: 1),
        itemBuilder: (context, index) {
          final lang = languages[index];
          return ListTile(
            title: Text(lang),
            trailing: selectedLang == lang
                ? Icon(
                    Icons.check,
                    color: Theme.of(context).colorScheme.primary,
                  )
                : null,
            onTap: () {
              setState(() => selectedLang = lang);
              // Save language preference here
            },
          );
        },
      ),
    );
  }
}

// --- PRIVACY POLICY PAGE ---
class PrivacyPage extends StatelessWidget {
  const PrivacyPage({super.key});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text("Privacy Policy")),
      body: const SingleChildScrollView(
        padding: EdgeInsets.all(20),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              "Data Collection",
              style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold),
            ),
            SizedBox(height: 8),
            Text(
              "We value your privacy. This app only collects necessary data to ensure functionality. We do not sell your personal information to third parties. All data is encrypted and stored securely.",
              style: TextStyle(height: 1.5),
            ),
            SizedBox(height: 20),
            Text(
              "Permissions",
              style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold),
            ),
            SizedBox(height: 8),
            Text(
              "This app requires network access to fetch data and local storage permissions to save your preferences offline.",
              style: TextStyle(height: 1.5),
            ),
          ],
        ),
      ),
    );
  }
}

// --- ABOUT PAGE ---
class AboutPage extends StatelessWidget {
  const AboutPage({super.key});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text("About")),
      body: Center(
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Container(
              padding: const EdgeInsets.all(20),
              decoration: BoxDecoration(
                color: Theme.of(context).colorScheme.primary.withOpacity(0.1),
                shape: BoxShape.circle,
              ),
              child: Icon(
                Icons.settings_suggest,
                size: 80,
                color: Theme.of(context).colorScheme.primary,
              ),
            ),
            const SizedBox(height: 24),
            const Text(
              "My Awesome App",
              style: TextStyle(fontSize: 24, fontWeight: FontWeight.bold),
            ),
            const SizedBox(height: 8),
            const Text("Version 1.0.0 (Build 14)"),
            const SizedBox(height: 32),
            TextButton(onPressed: () {}, child: const Text("Terms of Service")),
            TextButton(
              onPressed: () {},
              child: const Text("Open Source Licenses"),
            ),
          ],
        ),
      ),
    );
  }
}
