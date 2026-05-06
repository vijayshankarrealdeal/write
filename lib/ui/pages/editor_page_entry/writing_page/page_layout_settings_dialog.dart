import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:provider/provider.dart';

import 'package:inkspacex/models/page_layout_settings.dart';
import 'package:inkspacex/provider/editor_provider.dart';

/// Settings sheet for the paginated "Page" view. Per-project
/// configuration: page size (Letter / A4 / custom dimensions),
/// margins, font, font size, and line spacing.
///
/// Persists through [EditorProvider.persistProjectFields] under the
/// `page_layout` key so the change rides on the existing
/// `updateWritingProject` outbox op (offline-safe, debounced retry,
/// echo-suppressed).
class PageLayoutSettingsDialog extends StatefulWidget {
  const PageLayoutSettingsDialog({super.key});

  static Future<void> show(BuildContext context) {
    return showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      backgroundColor: Theme.of(context).brightness == Brightness.dark
          ? const Color(0xFF0E0E0E)
          : Colors.white,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(18)),
      ),
      builder: (_) => const Padding(
        padding: EdgeInsets.only(top: 12),
        child: PageLayoutSettingsDialog(),
      ),
    );
  }

  @override
  State<PageLayoutSettingsDialog> createState() =>
      _PageLayoutSettingsDialogState();
}

class _PageLayoutSettingsDialogState extends State<PageLayoutSettingsDialog> {
  // Custom-dimension text controllers; created lazily so the cursor
  // doesn't reset every keystroke.
  TextEditingController? _customWidthCtrl;
  TextEditingController? _customHeightCtrl;

  @override
  void dispose() {
    _customWidthCtrl?.dispose();
    _customHeightCtrl?.dispose();
    super.dispose();
  }

  PageLayoutSettings _settingsFor(EditorProvider provider) {
    return provider.activeBook?.pageLayout ?? PageLayoutSettings.standard;
  }

  void _persist(EditorProvider provider, PageLayoutSettings next) {
    final book = provider.activeBook;
    if (book == null) return;
    book.pageLayout = next;
    provider.persistProjectFields({'page_layout': next.toJson()});
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final textColor = theme.textTheme.bodyMedium?.color ?? Colors.black;
    final mediaHeight = MediaQuery.sizeOf(context).height;
    return SizedBox(
      height: mediaHeight * 0.82,
      child: Consumer<EditorProvider>(
        builder: (context, provider, _) {
          final book = provider.activeBook;
          if (book == null) return const SizedBox.shrink();
          final settings = _settingsFor(provider);
          return ListView(
            padding: const EdgeInsets.fromLTRB(20, 8, 20, 28),
            children: [
              _grabber(textColor),
              const SizedBox(height: 8),
              Text(
                'Page Layout',
                style: GoogleFonts.inter(
                  fontSize: 18,
                  fontWeight: FontWeight.w700,
                  color: textColor,
                ),
              ),
              Text(
                'Applies to the paginated view (⌘5). Saved per project.',
                style: GoogleFonts.inter(
                  fontSize: 12,
                  color: textColor.withValues(alpha: 0.6),
                ),
              ),
              const SizedBox(height: 16),
              _sectionTitle(textColor, 'PAGE SIZE'),
              const SizedBox(height: 8),
              _pageSizeChips(provider, settings, textColor),
              if (settings.size == PageSize.custom) ...[
                const SizedBox(height: 12),
                _customSizeFields(provider, settings, textColor),
              ],
              const SizedBox(height: 18),
              _sectionTitle(textColor, 'MARGINS (inches)'),
              const SizedBox(height: 8),
              _marginSliders(provider, settings, textColor),
              const SizedBox(height: 18),
              _sectionTitle(textColor, 'FONT'),
              const SizedBox(height: 8),
              _fontPicker(provider, settings, textColor),
              const SizedBox(height: 14),
              _sectionTitle(textColor, 'FONT SIZE'),
              const SizedBox(height: 8),
              _fontSizeSlider(provider, settings, textColor),
              const SizedBox(height: 14),
              _sectionTitle(textColor, 'LINE SPACING'),
              const SizedBox(height: 8),
              _lineHeightSlider(provider, settings, textColor),
              const SizedBox(height: 24),
              ElevatedButton.icon(
                style: ElevatedButton.styleFrom(
                  backgroundColor:
                      theme.colorScheme.surface.withValues(alpha: 0.4),
                  foregroundColor: textColor,
                  shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(8)),
                ),
                onPressed: () =>
                    _persist(provider, PageLayoutSettings.standard),
                icon: const Icon(CupertinoIcons.refresh, size: 16),
                label: Text(
                  'Reset to Letter / Merriweather 12 / 1.5',
                  style: GoogleFonts.inter(
                      fontSize: 13, fontWeight: FontWeight.w600),
                ),
              ),
            ],
          );
        },
      ),
    );
  }

  Widget _grabber(Color textColor) => Center(
        child: Container(
          margin: const EdgeInsets.only(top: 4),
          width: 40,
          height: 4,
          decoration: BoxDecoration(
            color: textColor.withValues(alpha: 0.15),
            borderRadius: BorderRadius.circular(2),
          ),
        ),
      );

  Widget _sectionTitle(Color textColor, String text) => Text(
        text,
        style: GoogleFonts.inter(
          fontSize: 11,
          fontWeight: FontWeight.w800,
          letterSpacing: 1.1,
          color: textColor.withValues(alpha: 0.55),
        ),
      );

  Widget _pageSizeChips(
    EditorProvider provider,
    PageLayoutSettings settings,
    Color textColor,
  ) {
    return Wrap(
      spacing: 8,
      runSpacing: 8,
      children: [
        for (final s in PageSize.values)
          ChoiceChip(
            label: Text(s.label, style: GoogleFonts.inter(fontSize: 12)),
            selected: settings.size == s,
            onSelected: (_) {
              final defaults = s.defaults;
              _persist(
                provider,
                settings.copyWith(
                  size: s,
                  widthIn: s == PageSize.custom
                      ? settings.widthIn
                      : defaults.widthIn,
                  heightIn: s == PageSize.custom
                      ? settings.heightIn
                      : defaults.heightIn,
                ),
              );
            },
          ),
      ],
    );
  }

  Widget _customSizeFields(
    EditorProvider provider,
    PageLayoutSettings settings,
    Color textColor,
  ) {
    _customWidthCtrl ??=
        TextEditingController(text: settings.widthIn.toStringAsFixed(2));
    _customHeightCtrl ??=
        TextEditingController(text: settings.heightIn.toStringAsFixed(2));
    return Row(
      children: [
        Expanded(
          child: TextField(
            controller: _customWidthCtrl,
            keyboardType:
                const TextInputType.numberWithOptions(decimal: true),
            inputFormatters: [
              FilteringTextInputFormatter.allow(RegExp(r'[0-9.]')),
            ],
            decoration: const InputDecoration(
              labelText: 'Width (in)',
              border: OutlineInputBorder(),
              isDense: true,
            ),
            onChanged: (v) {
              final parsed = double.tryParse(v);
              if (parsed != null && parsed > 1 && parsed < 50) {
                _persist(provider, settings.copyWith(widthIn: parsed));
              }
            },
          ),
        ),
        const SizedBox(width: 10),
        Expanded(
          child: TextField(
            controller: _customHeightCtrl,
            keyboardType:
                const TextInputType.numberWithOptions(decimal: true),
            inputFormatters: [
              FilteringTextInputFormatter.allow(RegExp(r'[0-9.]')),
            ],
            decoration: const InputDecoration(
              labelText: 'Height (in)',
              border: OutlineInputBorder(),
              isDense: true,
            ),
            onChanged: (v) {
              final parsed = double.tryParse(v);
              if (parsed != null && parsed > 1 && parsed < 50) {
                _persist(provider, settings.copyWith(heightIn: parsed));
              }
            },
          ),
        ),
      ],
    );
  }

  Widget _marginSliders(
    EditorProvider provider,
    PageLayoutSettings settings,
    Color textColor,
  ) {
    Widget oneSlider({
      required String label,
      required double value,
      required ValueChanged<double> onChanged,
    }) {
      return Padding(
        padding: const EdgeInsets.symmetric(vertical: 2),
        child: Row(
          children: [
            SizedBox(
              width: 70,
              child: Text(
                label,
                style: GoogleFonts.inter(fontSize: 12, color: textColor),
              ),
            ),
            Expanded(
              child: Slider(
                value: value,
                min: 0.25,
                max: 2.0,
                divisions: 35,
                label: '${value.toStringAsFixed(2)} in',
                onChanged: onChanged,
              ),
            ),
            SizedBox(
              width: 50,
              child: Text(
                '${value.toStringAsFixed(2)}"',
                textAlign: TextAlign.right,
                style: GoogleFonts.inter(
                  fontSize: 12,
                  color: textColor.withValues(alpha: 0.7),
                ),
              ),
            ),
          ],
        ),
      );
    }

    return Column(
      children: [
        oneSlider(
          label: 'Top',
          value: settings.marginTopIn,
          onChanged: (v) =>
              _persist(provider, settings.copyWith(marginTopIn: v)),
        ),
        oneSlider(
          label: 'Bottom',
          value: settings.marginBottomIn,
          onChanged: (v) =>
              _persist(provider, settings.copyWith(marginBottomIn: v)),
        ),
        oneSlider(
          label: 'Left',
          value: settings.marginLeftIn,
          onChanged: (v) =>
              _persist(provider, settings.copyWith(marginLeftIn: v)),
        ),
        oneSlider(
          label: 'Right',
          value: settings.marginRightIn,
          onChanged: (v) =>
              _persist(provider, settings.copyWith(marginRightIn: v)),
        ),
      ],
    );
  }

  Widget _fontPicker(
    EditorProvider provider,
    PageLayoutSettings settings,
    Color textColor,
  ) {
    return Wrap(
      spacing: 8,
      runSpacing: 8,
      children: [
        for (final f in PageFont.values)
          ChoiceChip(
            label: Text(f.label, style: GoogleFonts.inter(fontSize: 12)),
            selected: settings.font == f,
            onSelected: (_) =>
                _persist(provider, settings.copyWith(font: f)),
          ),
      ],
    );
  }

  Widget _fontSizeSlider(
    EditorProvider provider,
    PageLayoutSettings settings,
    Color textColor,
  ) {
    return Row(
      children: [
        Expanded(
          child: Slider(
            value: settings.fontSizePt,
            min: 9,
            max: 18,
            divisions: 18,
            label: '${settings.fontSizePt.toStringAsFixed(1)} pt',
            onChanged: (v) =>
                _persist(provider, settings.copyWith(fontSizePt: v)),
          ),
        ),
        SizedBox(
          width: 56,
          child: Text(
            '${settings.fontSizePt.toStringAsFixed(1)} pt',
            textAlign: TextAlign.right,
            style: GoogleFonts.inter(
                fontSize: 12, color: textColor.withValues(alpha: 0.7)),
          ),
        ),
      ],
    );
  }

  Widget _lineHeightSlider(
    EditorProvider provider,
    PageLayoutSettings settings,
    Color textColor,
  ) {
    return Row(
      children: [
        Expanded(
          child: Slider(
            value: settings.lineHeight,
            min: 1.0,
            max: 2.5,
            divisions: 30,
            label: settings.lineHeight.toStringAsFixed(2),
            onChanged: (v) =>
                _persist(provider, settings.copyWith(lineHeight: v)),
          ),
        ),
        SizedBox(
          width: 56,
          child: Text(
            settings.lineHeight.toStringAsFixed(2),
            textAlign: TextAlign.right,
            style: GoogleFonts.inter(
                fontSize: 12, color: textColor.withValues(alpha: 0.7)),
          ),
        ),
      ],
    );
  }
}
