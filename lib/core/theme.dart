import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';

/// Palette Cono Moto : asphalte sombre + orange « cône de chantier ».
class CmColors {
  CmColors._();

  static const orange = Color(0xFFFF6B1A);
  static const orangeDeep = Color(0xFFE5520A);
  static const amber = Color(0xFFFFB020);
  static const teal = Color(0xFF2EC4B6);
  static const sky = Color(0xFF4EA8FF);
  static const red = Color(0xFFEF4444);
  static const green = Color(0xFF22C55E);

  // Fonds sombres « asphalte ».
  static const asphalt900 = Color(0xFF0B0D10);
  static const asphalt800 = Color(0xFF121519);
  static const asphalt700 = Color(0xFF1A1E24);
  static const asphalt600 = Color(0xFF242932);
  static const asphalt500 = Color(0xFF323946);

  // Fonds clairs.
  static const paper = Color(0xFFF6F4F1);
  static const paperDim = Color(0xFFECE8E3);

  /// Couleurs des potes sur la carte (attribuées par défaut).
  static const friendPalette = [
    Color(0xFF2EC4B6),
    Color(0xFF4EA8FF),
    Color(0xFFA78BFA),
    Color(0xFFF472B6),
    Color(0xFFFACC15),
    Color(0xFF34D399),
    Color(0xFFFB923C),
    Color(0xFF60A5FA),
  ];

  /// Couleur selon l'angle d'inclinaison (valeur absolue en degrés).
  static Color forLean(double absDeg) {
    if (absDeg < 15) return green;
    if (absDeg < 30) return const Color(0xFFA3E635);
    if (absDeg < 40) return amber;
    if (absDeg < 48) return orange;
    return red;
  }
}

/// Espacements et rayons standard.
class CmSpacing {
  CmSpacing._();

  static const xs = 4.0;
  static const sm = 8.0;
  static const md = 12.0;
  static const lg = 16.0;
  static const xl = 24.0;
  static const xxl = 32.0;
  static const radius = 20.0;
  static const radiusSm = 12.0;
}

class CmTheme {
  CmTheme._();

  /// Police des grands chiffres (compteur, stats).
  static TextStyle numbers({double size = 48, FontWeight weight = FontWeight.w700, Color? color}) =>
      GoogleFonts.barlowCondensed(
        fontSize: size,
        fontWeight: weight,
        color: color,
        height: 1.0,
        fontFeatures: const [FontFeature.tabularFigures()],
      );

  static ThemeData dark() => _build(Brightness.dark);
  static ThemeData light() => _build(Brightness.light);

  static ThemeData _build(Brightness brightness) {
    final isDark = brightness == Brightness.dark;
    final scheme = ColorScheme.fromSeed(
      seedColor: CmColors.orange,
      brightness: brightness,
    ).copyWith(
      primary: CmColors.orange,
      onPrimary: Colors.white,
      primaryContainer: isDark ? const Color(0xFF4A2410) : const Color(0xFFFFE3D3),
      onPrimaryContainer: isDark ? const Color(0xFFFFD6C0) : const Color(0xFF3A1600),
      secondary: CmColors.teal,
      onSecondary: Colors.black,
      tertiary: CmColors.sky,
      error: CmColors.red,
      surface: isDark ? CmColors.asphalt800 : CmColors.paper,
      onSurface: isDark ? const Color(0xFFEDEFF2) : const Color(0xFF16181C),
      surfaceContainerLowest: isDark ? CmColors.asphalt900 : Colors.white,
      surfaceContainerLow: isDark ? const Color(0xFF15181D) : const Color(0xFFFBFAF8),
      surfaceContainer: isDark ? CmColors.asphalt700 : Colors.white,
      surfaceContainerHigh: isDark ? CmColors.asphalt600 : CmColors.paperDim,
      surfaceContainerHighest: isDark ? CmColors.asphalt500 : const Color(0xFFE2DDD6),
      outline: isDark ? const Color(0xFF4B5361) : const Color(0xFFB9B2A8),
      outlineVariant: isDark ? const Color(0xFF2C323C) : const Color(0xFFDCD6CE),
    );

    final baseText = GoogleFonts.barlowTextTheme(
      isDark ? ThemeData.dark().textTheme : ThemeData.light().textTheme,
    ).apply(bodyColor: scheme.onSurface, displayColor: scheme.onSurface);

    final text = baseText.copyWith(
      displayLarge: GoogleFonts.barlowCondensed(textStyle: baseText.displayLarge, fontWeight: FontWeight.w700),
      displayMedium: GoogleFonts.barlowCondensed(textStyle: baseText.displayMedium, fontWeight: FontWeight.w700),
      displaySmall: GoogleFonts.barlowCondensed(textStyle: baseText.displaySmall, fontWeight: FontWeight.w700),
      headlineLarge: GoogleFonts.barlowCondensed(textStyle: baseText.headlineLarge, fontWeight: FontWeight.w700),
      headlineMedium: GoogleFonts.barlowCondensed(textStyle: baseText.headlineMedium, fontWeight: FontWeight.w700),
      headlineSmall: GoogleFonts.barlowCondensed(textStyle: baseText.headlineSmall, fontWeight: FontWeight.w700),
      titleLarge: baseText.titleLarge?.copyWith(fontWeight: FontWeight.w700),
      titleMedium: baseText.titleMedium?.copyWith(fontWeight: FontWeight.w600),
      labelLarge: baseText.labelLarge?.copyWith(fontWeight: FontWeight.w700, letterSpacing: 0.3),
    );

    final shape = RoundedRectangleBorder(borderRadius: BorderRadius.circular(CmSpacing.radius));

    return ThemeData(
      useMaterial3: true,
      brightness: brightness,
      colorScheme: scheme,
      textTheme: text,
      scaffoldBackgroundColor: isDark ? CmColors.asphalt900 : CmColors.paper,
      appBarTheme: AppBarTheme(
        backgroundColor: isDark ? CmColors.asphalt900 : CmColors.paper,
        foregroundColor: scheme.onSurface,
        elevation: 0,
        scrolledUnderElevation: 0,
        centerTitle: false,
        titleTextStyle: GoogleFonts.barlowCondensed(
          fontSize: 26,
          fontWeight: FontWeight.w700,
          color: scheme.onSurface,
          letterSpacing: 0.2,
        ),
      ),
      cardTheme: CardThemeData(
        color: scheme.surfaceContainer,
        elevation: 0,
        margin: EdgeInsets.zero,
        shape: shape,
      ),
      navigationBarTheme: NavigationBarThemeData(
        backgroundColor: isDark ? CmColors.asphalt800 : Colors.white,
        indicatorColor: CmColors.orange.withValues(alpha: isDark ? 0.22 : 0.16),
        height: 68,
        labelTextStyle: WidgetStateProperty.resolveWith(
          (states) => GoogleFonts.barlow(
            fontSize: 12,
            fontWeight: states.contains(WidgetState.selected) ? FontWeight.w700 : FontWeight.w500,
          ),
        ),
        iconTheme: WidgetStateProperty.resolveWith(
          (states) => IconThemeData(
            color: states.contains(WidgetState.selected) ? CmColors.orange : scheme.onSurfaceVariant,
          ),
        ),
      ),
      filledButtonTheme: FilledButtonThemeData(
        style: FilledButton.styleFrom(
          minimumSize: const Size(64, 52),
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
          textStyle: GoogleFonts.barlow(fontSize: 16, fontWeight: FontWeight.w700),
        ),
      ),
      outlinedButtonTheme: OutlinedButtonThemeData(
        style: OutlinedButton.styleFrom(
          minimumSize: const Size(64, 52),
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
          textStyle: GoogleFonts.barlow(fontSize: 16, fontWeight: FontWeight.w700),
        ),
      ),
      floatingActionButtonTheme: const FloatingActionButtonThemeData(
        backgroundColor: CmColors.orange,
        foregroundColor: Colors.white,
        shape: StadiumBorder(),
      ),
      chipTheme: ChipThemeData(
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
        side: BorderSide(color: scheme.outlineVariant),
        labelStyle: GoogleFonts.barlow(fontWeight: FontWeight.w600),
      ),
      inputDecorationTheme: InputDecorationTheme(
        filled: true,
        fillColor: scheme.surfaceContainerHigh,
        border: OutlineInputBorder(
          borderRadius: BorderRadius.circular(14),
          borderSide: BorderSide.none,
        ),
        contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
      ),
      bottomSheetTheme: BottomSheetThemeData(
        backgroundColor: scheme.surfaceContainerLow,
        showDragHandle: true,
        shape: const RoundedRectangleBorder(
          borderRadius: BorderRadius.vertical(top: Radius.circular(28)),
        ),
      ),
      dialogTheme: DialogThemeData(
        backgroundColor: scheme.surfaceContainerLow,
        shape: shape,
      ),
      snackBarTheme: SnackBarThemeData(
        behavior: SnackBarBehavior.floating,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
      ),
      listTileTheme: ListTileThemeData(
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
      ),
      dividerTheme: DividerThemeData(color: scheme.outlineVariant, space: 1),
      sliderTheme: const SliderThemeData(showValueIndicator: ShowValueIndicator.onDrag),
    );
  }
}
