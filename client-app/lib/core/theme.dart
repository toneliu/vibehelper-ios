import 'package:flutter/material.dart';

class VibePalette {
  const VibePalette({
    required this.isDark,
    required this.bg,
    required this.panel,
    required this.panelAlt,
    required this.border,
    required this.text,
    required this.muted,
    required this.accent,
    required this.success,
    required this.warning,
    required this.danger,
    required this.chatCanvas,
    required this.codeBg,
    required this.codeHeaderBg,
    required this.codeText,
    required this.inlineCodeBg,
    required this.inlineCodeText,
    required this.userBubbleBg,
    required this.aiCardBg,
  });

  final bool isDark;
  final Color bg;
  final Color panel;
  final Color panelAlt;
  final Color border;
  final Color text;
  final Color muted;
  final Color accent;
  final Color success;
  final Color warning;
  final Color danger;
  final Color chatCanvas;
  final Color codeBg;
  final Color codeHeaderBg;
  final Color codeText;
  final Color inlineCodeBg;
  final Color inlineCodeText;
  final Color userBubbleBg;
  final Color aiCardBg;

  static const VibePalette light = VibePalette(
    isDark: false,
    bg: Color(0xFFF5F6FA),
    panel: Color(0xFFFFFFFF),
    panelAlt: Color(0xFFF0F2F7),
    border: Color(0xFFE5E7EB),
    text: Color(0xFF18181B),
    muted: Color(0xFF71717A),
    accent: Color(0xFF4F6BFF),
    success: Color(0xFF16A34A),
    warning: Color(0xFFD97706),
    danger: Color(0xFFDC2626),
    chatCanvas: Color(0xFFF8F9FC),
    codeBg: Color(0xFF111827),
    codeHeaderBg: Color(0xFF1F2937),
    codeText: Color(0xFFE5E7EB),
    inlineCodeBg: Color(0xFFEEF2FF),
    inlineCodeText: Color(0xFF4338CA),
    userBubbleBg: Color(0xFFEEF2FF),
    aiCardBg: Color(0xFFFFFFFF),
  );

  static const VibePalette dark = VibePalette(
    isDark: true,
    bg: Color(0xFF0B1020),
    panel: Color(0xFF131B2E),
    panelAlt: Color(0xFF19233C),
    border: Color(0xFF263454),
    text: Color(0xFFE6EDF7),
    muted: Color(0xFF8EA0C0),
    accent: Color(0xFF3B82F6),
    success: Color(0xFF22C55E),
    warning: Color(0xFFF59E0B),
    danger: Color(0xFFEF4444),
    chatCanvas: Color(0xFF070B16),
    codeBg: Color(0xFF060A13),
    codeHeaderBg: Color(0xFF0B1120),
    codeText: Color(0xFFE2E8F0),
    inlineCodeBg: Color(0xFF152238),
    inlineCodeText: Color(0xFF7DD3FC),
    userBubbleBg: Color(0xFF162447),
    aiCardBg: Color(0xFF0E1629),
  );
}

class VibeTheme {
  static const Color bg = Color(0xFF0B1020);
  static const Color panel = Color(0xFF131B2E);
  static const Color panelAlt = Color(0xFF19233C);
  static const Color border = Color(0xFF263454);
  static const Color text = Color(0xFFE6EDF7);
  static const Color muted = Color(0xFF8EA0C0);
  static const Color accent = Color(0xFF3B82F6);
  static const Color success = Color(0xFF22C55E);
  static const Color warning = Color(0xFFF59E0B);
  static const Color danger = Color(0xFFEF4444);

  static VibePalette paletteOf(BuildContext context) {
    return Theme.of(context).brightness == Brightness.dark
        ? VibePalette.dark
        : VibePalette.light;
  }

  static ThemeData light() {
    const p = VibePalette.light;
    final base = ThemeData.light(useMaterial3: true);
    return base.copyWith(
      scaffoldBackgroundColor: p.bg,
      colorScheme: ColorScheme.light(
        primary: p.accent,
        secondary: p.success,
        error: p.danger,
        surface: p.panel,
        onSurface: p.text,
      ),
      cardTheme: CardThemeData(
        color: p.panel,
        elevation: 0,
        margin: EdgeInsets.zero,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(18),
          side: BorderSide(color: p.border),
        ),
      ),
      inputDecorationTheme: InputDecorationTheme(
        filled: true,
        fillColor: p.panelAlt,
        isDense: true,
        contentPadding:
            const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
        border: OutlineInputBorder(
          borderRadius: BorderRadius.circular(12),
          borderSide: BorderSide(color: p.border),
        ),
        enabledBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(12),
          borderSide: BorderSide(color: p.border),
        ),
        focusedBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(12),
          borderSide: BorderSide(color: p.accent, width: 1.5),
        ),
      ),
      dividerColor: p.border,
    );
  }

  static ThemeData dark() {
    final base = ThemeData.dark(useMaterial3: true);
    return base.copyWith(
      scaffoldBackgroundColor: bg,
      colorScheme: const ColorScheme.dark(
        primary: accent,
        secondary: success,
        error: danger,
        surface: panel,
        onSurface: text,
      ),
      cardTheme: CardThemeData(
        color: panel,
        elevation: 0,
        margin: EdgeInsets.zero,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(14),
          side: const BorderSide(color: border),
        ),
      ),
      inputDecorationTheme: InputDecorationTheme(
        filled: true,
        fillColor: panelAlt,
        isDense: true,
        contentPadding:
            const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
        border: OutlineInputBorder(
          borderRadius: BorderRadius.circular(10),
          borderSide: const BorderSide(color: border),
        ),
        enabledBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(10),
          borderSide: const BorderSide(color: border),
        ),
        focusedBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(10),
          borderSide: const BorderSide(color: accent, width: 1.5),
        ),
      ),
      dividerColor: border,
    );
  }
}
