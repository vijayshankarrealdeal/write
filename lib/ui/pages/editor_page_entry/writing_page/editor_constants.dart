import 'package:flutter/widgets.dart';
import 'package:google_fonts/google_fonts.dart';

// Resolved Google Fonts styles, keyed by family name. Quill calls the
// custom style builder per styled span on every paint, and getFont() is
// not free — caching the resolved TextStyle avoids the repeated lookup.
final Map<String, TextStyle> _fontStyleCache = {};
TextStyle cachedFontStyle(String name) =>
    _fontStyleCache.putIfAbsent(name, () {
      try {
        return GoogleFonts.getFont(name);
      } catch (_) {
        return TextStyle(fontFamily: name);
      }
    });

// ─── Font families available in the editor ───
//
// Curated Google Fonts grouped by visual family. Each entry is the actual
// Google Font name — what the dropdown shows AND what gets stored on the
// `font` attribute, so there is no label/value indirection to round-trip.
const editorFonts = <String>[
  // Sans-serif
  'Inter',
  'Source Sans 3',
  'IBM Plex Sans',
  'Nunito',
  'Work Sans',
  'DM Sans',
  // Serif
  'Merriweather',
  'Lora',
  'Crimson Pro',
  'EB Garamond',
  'Source Serif 4',
  'Spectral',
  // Display
  'Playfair Display',
  'DM Serif Display',
  'Bebas Neue',
  'Abril Fatface',
  // Elegant
  'Cormorant Garamond',
  'Italiana',
  // Handwritten
  'Caveat',
  'Dancing Script',
  'Patrick Hand',
  'Kalam',
  // Mono
  'JetBrains Mono',
  'Fira Code',
];

const wordFontSizes = <double>[
  8, 9, 10, 11, 12, 14, 16, 18, 20, 22, 24, 26, 28, 36, 48, 72,
];

// ─── Paper Themes ───
enum PaperTheme {
  defaultTheme('Default'),
  sepia('Sepia'),
  warm('Warm'),
  cool('Cool'),
  green('Green'),
  rose('Rose'),
  midnight('Midnight');

  final String label;
  const PaperTheme(this.label);
}

// ─── Writing Prompts ───
const writingPrompts = <String>[
  'Write about a sound that changed everything.',
  'Describe a place you\'ve never been but can see clearly.',
  'What would you say to your past self?',
  'Write the opening line of a story you\'d want to read.',
  'Describe the color blue without using the word "blue".',
  'Write about a door that should never be opened.',
  'What does silence sound like in your favorite place?',
  'Describe a stranger you\'ll never forget.',
  'Write about the last time you were truly surprised.',
  'What lives in the space between sleeping and waking?',
  'Write about an object you\'ve carried for years.',
  'Describe a meal that felt like coming home.',
  'What would the walls of this room say?',
  'Write about a promise that was kept.',
  'Describe the feeling of rain on skin.',
  'Write about a letter that was never sent.',
  'What does your handwriting say about you?',
  'Describe a moment when time stood still.',
  'Write about a road that only exists at night.',
  'What does courage smell like?',
  'Write about something beautiful that\'s broken.',
  'Describe the space between two heartbeats.',
  'Write about a word that doesn\'t exist but should.',
  'What color is the feeling of nostalgia?',
  'Describe a conversation between the sun and moon.',
  'Write about the first thing you remember.',
  'What does your shadow do when you\'re not looking?',
  'Describe a map to somewhere that can\'t be found.',
  'Write about what the ocean forgets.',
  'What would you plant in a garden of memories?',
];
