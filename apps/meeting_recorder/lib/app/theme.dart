import 'package:flutter/material.dart';

/// Soft violet accent, light surfaces, rounded cards: the "AI note" look.
const seedColor = Color(0xFF6C4DFF);

ThemeData buildTheme(Brightness brightness) {
  final scheme = ColorScheme.fromSeed(seedColor: seedColor, brightness: brightness);
  final isDark = brightness == Brightness.dark;
  return ThemeData(
    useMaterial3: true,
    colorScheme: scheme,
    scaffoldBackgroundColor: isDark ? const Color(0xFF121218) : const Color(0xFFF6F5FB),
    appBarTheme: AppBarTheme(
      backgroundColor: isDark ? const Color(0xFF121218) : const Color(0xFFF6F5FB),
      surfaceTintColor: Colors.transparent,
      elevation: 0,
      titleTextStyle: TextStyle(
        color: scheme.onSurface,
        fontSize: 22,
        fontWeight: FontWeight.w700,
      ),
    ),
    cardTheme: CardThemeData(
      elevation: 0,
      color: isDark ? const Color(0xFF1C1B24) : Colors.white,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
      margin: EdgeInsets.zero,
    ),
    chipTheme: ChipThemeData(
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
      side: BorderSide.none,
      labelStyle: TextStyle(fontSize: 12, color: scheme.onSurfaceVariant),
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
    ),
    inputDecorationTheme: InputDecorationTheme(
      filled: true,
      fillColor: isDark ? const Color(0xFF1C1B24) : Colors.white,
      border: OutlineInputBorder(
        borderRadius: BorderRadius.circular(16),
        borderSide: BorderSide.none,
      ),
      contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
    ),
    segmentedButtonTheme: SegmentedButtonThemeData(
      style: ButtonStyle(
        shape: WidgetStatePropertyAll(
          RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
        ),
      ),
    ),
    floatingActionButtonTheme: FloatingActionButtonThemeData(
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
    ),
  );
}

/// Stable per-speaker colors (index = order in the meeting's speaker list).
const speakerPalette = <Color>[
  Color(0xFF6C4DFF),
  Color(0xFF00A98F),
  Color(0xFFFF7A59),
  Color(0xFF2F80ED),
  Color(0xFFE0479E),
  Color(0xFF8B8000),
];

Color speakerColor(int index) => speakerPalette[index % speakerPalette.length];

/// Tint for the category chip.
Color categoryColor(String? category, ColorScheme scheme) => switch (category) {
      '업무' => const Color(0xFF6C4DFF),
      '개인' => const Color(0xFF00A98F),
      '상담' => const Color(0xFFFF7A59),
      '학습' => const Color(0xFF2F80ED),
      _ => scheme.outline,
    };

/// Constant icons per note template (const so release builds can tree-shake the icon font).
IconData templateIcon(String key) => switch (key) {
      'keypoints' => Icons.format_list_bulleted,
      'lecture' => Icons.school_outlined,
      'thoughts' => Icons.lightbulb_outline,
      _ => Icons.groups_outlined,
    };
