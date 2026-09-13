import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'mana.dart';

/// Arcanum's bespoke palette, exposed through the theme so widgets never
/// hard-code a colour.
@immutable
class ArcanumColors extends ThemeExtension<ArcanumColors> {
  const ArcanumColors({
    required this.canvas,
    required this.canvasDeep,
    required this.surface,
    required this.surfaceRaised,
    required this.glass,
    required this.hairline,
    required this.hairlineStrong,
    required this.textPrimary,
    required this.textSecondary,
    required this.textTertiary,
    required this.positive,
    required this.negative,
    required this.warning,
    required this.accent,
    required this.accentSoft,
    required this.gold,
  });

  final Color canvas;
  final Color canvasDeep;
  final Color surface;
  final Color surfaceRaised;
  final Color glass;
  final Color hairline;
  final Color hairlineStrong;
  final Color textPrimary;
  final Color textSecondary;
  final Color textTertiary;
  final Color positive;
  final Color negative;
  final Color warning;
  final Color accent;
  final Color accentSoft;
  final Color gold;

  /// Colour used to represent a signed change.
  Color forDelta(double delta) =>
      delta > 0.0001 ? positive : (delta < -0.0001 ? negative : textSecondary);

  static const dark = ArcanumColors(
    canvas: Color(0xFF07070C),
    canvasDeep: Color(0xFF04040A),
    surface: Color(0xFF111119),
    surfaceRaised: Color(0xFF191924),
    glass: Color(0x14FFFFFF),
    hairline: Color(0x14FFFFFF),
    hairlineStrong: Color(0x24FFFFFF),
    textPrimary: Color(0xFFF2F3F7),
    textSecondary: Color(0xFF9BA3B4),
    textTertiary: Color(0xFF646C7E),
    positive: Color(0xFF3FD98A),
    negative: Color(0xFFFF5C6E),
    warning: Color(0xFFFFB454),
    accent: Color(0xFF8B6CF6),
    accentSoft: Color(0x338B6CF6),
    gold: Color(0xFFD8B44A),
  );

  static const light = ArcanumColors(
    canvas: Color(0xFFF6F6FA),
    canvasDeep: Color(0xFFEDEDF4),
    surface: Color(0xFFFFFFFF),
    surfaceRaised: Color(0xFFF2F2F8),
    glass: Color(0x0A000000),
    hairline: Color(0x14000000),
    hairlineStrong: Color(0x24000000),
    textPrimary: Color(0xFF101018),
    textSecondary: Color(0xFF565E70),
    textTertiary: Color(0xFF8A92A4),
    positive: Color(0xFF128A52),
    negative: Color(0xFFCC2B3E),
    warning: Color(0xFFB4700A),
    accent: Color(0xFF5B3FD1),
    accentSoft: Color(0x225B3FD1),
    gold: Color(0xFF9A7B1E),
  );

  @override
  ArcanumColors copyWith({
    Color? canvas,
    Color? canvasDeep,
    Color? surface,
    Color? surfaceRaised,
    Color? glass,
    Color? hairline,
    Color? hairlineStrong,
    Color? textPrimary,
    Color? textSecondary,
    Color? textTertiary,
    Color? positive,
    Color? negative,
    Color? warning,
    Color? accent,
    Color? accentSoft,
    Color? gold,
  }) {
    return ArcanumColors(
      canvas: canvas ?? this.canvas,
      canvasDeep: canvasDeep ?? this.canvasDeep,
      surface: surface ?? this.surface,
      surfaceRaised: surfaceRaised ?? this.surfaceRaised,
      glass: glass ?? this.glass,
      hairline: hairline ?? this.hairline,
      hairlineStrong: hairlineStrong ?? this.hairlineStrong,
      textPrimary: textPrimary ?? this.textPrimary,
      textSecondary: textSecondary ?? this.textSecondary,
      textTertiary: textTertiary ?? this.textTertiary,
      positive: positive ?? this.positive,
      negative: negative ?? this.negative,
      warning: warning ?? this.warning,
      accent: accent ?? this.accent,
      accentSoft: accentSoft ?? this.accentSoft,
      gold: gold ?? this.gold,
    );
  }

  @override
  ArcanumColors lerp(ThemeExtension<ArcanumColors>? other, double t) {
    if (other is! ArcanumColors) return this;
    return ArcanumColors(
      canvas: Color.lerp(canvas, other.canvas, t)!,
      canvasDeep: Color.lerp(canvasDeep, other.canvasDeep, t)!,
      surface: Color.lerp(surface, other.surface, t)!,
      surfaceRaised: Color.lerp(surfaceRaised, other.surfaceRaised, t)!,
      glass: Color.lerp(glass, other.glass, t)!,
      hairline: Color.lerp(hairline, other.hairline, t)!,
      hairlineStrong: Color.lerp(hairlineStrong, other.hairlineStrong, t)!,
      textPrimary: Color.lerp(textPrimary, other.textPrimary, t)!,
      textSecondary: Color.lerp(textSecondary, other.textSecondary, t)!,
      textTertiary: Color.lerp(textTertiary, other.textTertiary, t)!,
      positive: Color.lerp(positive, other.positive, t)!,
      negative: Color.lerp(negative, other.negative, t)!,
      warning: Color.lerp(warning, other.warning, t)!,
      accent: Color.lerp(accent, other.accent, t)!,
      accentSoft: Color.lerp(accentSoft, other.accentSoft, t)!,
      gold: Color.lerp(gold, other.gold, t)!,
    );
  }
}

/// Convenience accessor: `context.c` returns the Arcanum palette.
extension ArcanumContext on BuildContext {
  ArcanumColors get c =>
      Theme.of(this).extension<ArcanumColors>() ?? ArcanumColors.dark;
  TextTheme get t => Theme.of(this).textTheme;
}

/// Builds the Arcanum theme.
///
/// The app is dark-first by design — card art carries the colour, so the
/// chrome stays near-black. A light theme is provided for daytime use.
abstract final class AppTheme {
  static const _uiFont = 'Manrope';
  static const _numericFont = 'SpaceGrotesk';

  /// A text theme where every numeric display style uses tabular figures so
  /// prices do not jitter as they animate.
  static TextTheme _textTheme(ArcanumColors c) {
    TextStyle n(
      double size,
      FontWeight w, {
      double spacing = -0.02,
      Color? color,
    }) => TextStyle(
      fontFamily: _numericFont,
      fontSize: size,
      fontWeight: w,
      letterSpacing: spacing * size,
      color: color ?? c.textPrimary,
      fontFeatures: const [FontFeature.tabularFigures()],
    );
    TextStyle u(
      double size,
      FontWeight w, {
      double spacing = -0.01,
      Color? color,
    }) => TextStyle(
      fontFamily: _uiFont,
      fontSize: size,
      fontWeight: w,
      letterSpacing: spacing * size,
      color: color ?? c.textPrimary,
    );

    return TextTheme(
      displayLarge: n(52, FontWeight.w700),
      displayMedium: n(40, FontWeight.w700),
      displaySmall: n(32, FontWeight.w600),
      headlineLarge: u(28, FontWeight.w800, spacing: -0.025),
      headlineMedium: u(23, FontWeight.w800, spacing: -0.02),
      headlineSmall: u(19, FontWeight.w700),
      titleLarge: u(17, FontWeight.w700),
      titleMedium: u(15, FontWeight.w600),
      titleSmall: u(13.5, FontWeight.w600),
      bodyLarge: u(15, FontWeight.w500),
      bodyMedium: u(13.5, FontWeight.w500),
      bodySmall: u(12, FontWeight.w500, color: c.textSecondary),
      labelLarge: u(13, FontWeight.w700, spacing: 0.02),
      labelMedium: u(11.5, FontWeight.w700, spacing: 0.04),
      labelSmall: u(10.5, FontWeight.w700, spacing: 0.06),
    );
  }

  /// Builds the theme.
  ///
  /// [accent] lets the app adopt the active game's signature colour, so the
  /// Magic side reads violet and the Pokémon side reads gold. Everything else
  /// stays identical.
  static ThemeData build({
    required bool dark,
    ColorScheme? dynamicScheme,
    Color? accent,
  }) {
    var c = dark ? ArcanumColors.dark : ArcanumColors.light;
    if (accent != null) {
      c = c.copyWith(
        accent: accent,
        accentSoft: accent.withValues(alpha: 0.22),
      );
    }

    final scheme =
        (dynamicScheme ??
                ColorScheme.fromSeed(
                  seedColor: c.accent,
                  brightness: dark ? Brightness.dark : Brightness.light,
                ))
            .copyWith(surface: c.canvas, primary: c.accent, error: c.negative);

    return ThemeData(
      useMaterial3: true,
      brightness: dark ? Brightness.dark : Brightness.light,
      colorScheme: scheme,
      scaffoldBackgroundColor: c.canvas,
      canvasColor: c.canvas,
      fontFamily: _uiFont,
      textTheme: _textTheme(c),
      extensions: <ThemeExtension<dynamic>>[c],
      splashFactory: InkSparkle.splashFactory,
      visualDensity: VisualDensity.standard,
      appBarTheme: AppBarTheme(
        backgroundColor: Colors.transparent,
        surfaceTintColor: Colors.transparent,
        elevation: 0,
        scrolledUnderElevation: 0,
        centerTitle: false,
        titleTextStyle: _textTheme(c).headlineSmall,
        systemOverlayStyle: dark
            ? SystemUiOverlayStyle.light
            : SystemUiOverlayStyle.dark,
      ),
      cardTheme: CardThemeData(
        color: c.surface,
        surfaceTintColor: Colors.transparent,
        elevation: 0,
        margin: EdgeInsets.zero,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(20),
          side: BorderSide(color: c.hairline),
        ),
      ),
      dividerTheme: DividerThemeData(color: c.hairline, thickness: 1, space: 1),
      chipTheme: ChipThemeData(
        backgroundColor: c.surfaceRaised,
        side: BorderSide(color: c.hairline),
        labelStyle: _textTheme(c).labelMedium,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
      ),
      inputDecorationTheme: InputDecorationTheme(
        filled: true,
        fillColor: c.surfaceRaised,
        hintStyle: TextStyle(color: c.textTertiary, fontFamily: _uiFont),
        contentPadding: const EdgeInsets.symmetric(
          horizontal: 16,
          vertical: 14,
        ),
        border: OutlineInputBorder(
          borderRadius: BorderRadius.circular(16),
          borderSide: BorderSide(color: c.hairline),
        ),
        enabledBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(16),
          borderSide: BorderSide(color: c.hairline),
        ),
        focusedBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(16),
          borderSide: BorderSide(color: c.accent, width: 1.5),
        ),
      ),
      filledButtonTheme: FilledButtonThemeData(
        style: FilledButton.styleFrom(
          backgroundColor: c.accent,
          foregroundColor: Colors.white,
          minimumSize: const Size(0, 52),
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(16),
          ),
          textStyle: _textTheme(c).labelLarge,
        ),
      ),
      outlinedButtonTheme: OutlinedButtonThemeData(
        style: OutlinedButton.styleFrom(
          foregroundColor: c.textPrimary,
          minimumSize: const Size(0, 52),
          side: BorderSide(color: c.hairlineStrong),
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(16),
          ),
          textStyle: _textTheme(c).labelLarge,
        ),
      ),
      textButtonTheme: TextButtonThemeData(
        style: TextButton.styleFrom(
          foregroundColor: c.accent,
          textStyle: _textTheme(c).labelLarge,
        ),
      ),
      navigationBarTheme: NavigationBarThemeData(
        backgroundColor: c.surface.withValues(alpha: dark ? 0.86 : 0.96),
        surfaceTintColor: Colors.transparent,
        indicatorColor: c.accentSoft,
        elevation: 0,
        height: 68,
        labelBehavior: NavigationDestinationLabelBehavior.alwaysShow,
        labelTextStyle: WidgetStatePropertyAll(_textTheme(c).labelSmall),
      ),
      bottomSheetTheme: BottomSheetThemeData(
        backgroundColor: c.surface,
        surfaceTintColor: Colors.transparent,
        modalBackgroundColor: c.surface,
        shape: const RoundedRectangleBorder(
          borderRadius: BorderRadius.vertical(top: Radius.circular(28)),
        ),
      ),
      dialogTheme: DialogThemeData(
        backgroundColor: c.surfaceRaised,
        surfaceTintColor: Colors.transparent,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(24)),
      ),
      snackBarTheme: SnackBarThemeData(
        backgroundColor: c.surfaceRaised,
        contentTextStyle: _textTheme(c).bodyMedium,
        behavior: SnackBarBehavior.floating,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
      ),
      progressIndicatorTheme: ProgressIndicatorThemeData(
        color: c.accent,
        linearMinHeight: 3,
      ),
      listTileTheme: ListTileThemeData(
        iconColor: c.textSecondary,
        textColor: c.textPrimary,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
      ),
      sliderTheme: SliderThemeData(
        activeTrackColor: c.accent,
        inactiveTrackColor: c.hairlineStrong,
        thumbColor: c.accent,
      ),
      switchTheme: SwitchThemeData(
        thumbColor: WidgetStateProperty.resolveWith(
          (s) =>
              s.contains(WidgetState.selected) ? Colors.white : c.textTertiary,
        ),
        trackColor: WidgetStateProperty.resolveWith(
          (s) => s.contains(WidgetState.selected) ? c.accent : c.surfaceRaised,
        ),
      ),
      pageTransitionsTheme: const PageTransitionsTheme(
        builders: {
          TargetPlatform.android: PredictiveBackPageTransitionsBuilder(),
        },
      ),
    );
  }

  /// Gradients used across the app.
  static LinearGradient manaGradient(ManaColor mana) => LinearGradient(
    begin: Alignment.topLeft,
    end: Alignment.bottomRight,
    colors: [
      mana.accent.withValues(alpha: 0.85),
      mana.deep.withValues(alpha: 0.95),
    ],
  );

  static LinearGradient rarityGradient(CardRarity rarity) => LinearGradient(
    begin: Alignment.topLeft,
    end: Alignment.bottomRight,
    colors: [
      rarity.color.withValues(alpha: 0.9),
      rarity.color.withValues(alpha: 0.35),
    ],
  );

  /// The ambient background wash used behind scroll views.
  static LinearGradient backdrop(ArcanumColors c, {Color? tint}) =>
      LinearGradient(
        begin: Alignment.topCenter,
        end: Alignment.bottomCenter,
        colors: [
          (tint ?? c.accent).withValues(alpha: 0.10),
          c.canvas.withValues(alpha: 0.0),
          c.canvasDeep.withValues(alpha: 0.9),
        ],
        stops: const [0.0, 0.42, 1.0],
      );
}
