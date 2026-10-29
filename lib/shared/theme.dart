import 'package:flutter/material.dart';

/// "Obsidian Dawn": obsidian surfaces, a warm coral sunrise for actions,
/// electric cyan for active/verified states and amber for urgency.
class WakeTokens extends ThemeExtension<WakeTokens> {
  const WakeTokens({
    required this.cta,
    required this.onCta,
    required this.ctaGlow,
    required this.dawn,
    required this.dawnDim,
    required this.cyan,
    required this.onCyan,
    required this.amber,
    required this.ghostBorder,
    required this.subtle,
    required this.muted,
    required this.navBar,
  });

  /// Sunrise pill fill and its dark label.
  final Color cta;
  final Color onCta;
  final Color ctaGlow;

  /// Light peach used for big clock readouts and highlights.
  final Color dawn;

  /// Section labels and AM/PM suffixes (primary-fixed-dim).
  final Color dawnDim;
  final Color cyan;
  final Color onCyan;
  final Color amber;

  /// The 1px perimeter on cards.
  final Color ghostBorder;

  /// Translucent fill for secondary pills and inactive chips.
  final Color subtle;
  final Color muted;
  final Color navBar;

  static const dark = WakeTokens(
    cta: Color(0xffff9e79),
    onCta: Color(0xff783316),
    ctaGlow: Color(0x40ff9e79),
    dawn: Color(0xffffc5b1),
    dawnDim: Color(0xffffb59a),
    cyan: Color(0xff00f1fd),
    onCyan: Color(0xff00373a),
    amber: Color(0xffff9f66),
    ghostBorder: Color(0x14ffffff),
    subtle: Color(0x14ffffff),
    muted: Color(0xffa28c85),
    navBar: Color(0xff181c22),
  );

  static const light = WakeTokens(
    cta: Color(0xffff9e79),
    onCta: Color(0xff783316),
    ctaGlow: Color(0x40ff9e79),
    dawn: Color(0xffb4532f),
    dawnDim: Color(0xffa04a28),
    cyan: Color(0xff00787e),
    onCyan: Colors.white,
    amber: Color(0xffa04b0e),
    ghostBorder: Color(0x14000000),
    subtle: Color(0x0d000000),
    muted: Color(0xff6b7280),
    navBar: Colors.white,
  );

  static WakeTokens of(BuildContext context) =>
      Theme.of(context).extension<WakeTokens>() ??
      (Theme.of(context).brightness == Brightness.light ? light : dark);

  @override
  WakeTokens copyWith() => this;

  @override
  WakeTokens lerp(WakeTokens? other, double t) {
    if (other == null) return this;
    Color mix(Color a, Color b) => Color.lerp(a, b, t)!;
    return WakeTokens(
      cta: mix(cta, other.cta),
      onCta: mix(onCta, other.onCta),
      ctaGlow: mix(ctaGlow, other.ctaGlow),
      dawn: mix(dawn, other.dawn),
      dawnDim: mix(dawnDim, other.dawnDim),
      cyan: mix(cyan, other.cyan),
      onCyan: mix(onCyan, other.onCyan),
      amber: mix(amber, other.amber),
      ghostBorder: mix(ghostBorder, other.ghostBorder),
      subtle: mix(subtle, other.subtle),
      muted: mix(muted, other.muted),
      navBar: mix(navBar, other.navBar),
    );
  }
}

class WakeTheme {
  WakeTheme._();

  static const body = 'Inter';
  static const display = 'PlusJakartaSans';
  static const tabular = [FontFeature.tabularFigures()];

  static const cardRadius = BorderRadius.all(Radius.circular(24));

  static const _darkScheme = ColorScheme(
    brightness: Brightness.dark,
    primary: Color(0xffff9e79),
    onPrimary: Color(0xff3a1405),
    primaryContainer: Color(0xff763216),
    onPrimaryContainer: Color(0xffffdbce),
    secondary: Color(0xff00f1fd),
    onSecondary: Color(0xff00373a),
    secondaryContainer: Color(0xff004f53),
    onSecondaryContainer: Color(0xff6ff6ff),
    tertiary: Color(0xffffc6a7),
    onTertiary: Color(0xff532200),
    tertiaryContainer: Color(0xffff9f66),
    onTertiaryContainer: Color(0xff773400),
    error: Color(0xffffb4ab),
    onError: Color(0xff690005),
    errorContainer: Color(0xff93000a),
    onErrorContainer: Color(0xffffdad6),
    surface: Color(0xff10141a),
    onSurface: Color(0xffdfe2eb),
    surfaceDim: Color(0xff10141a),
    surfaceBright: Color(0xff353940),
    surfaceContainerLowest: Color(0xff0a0e14),
    surfaceContainerLow: Color(0xff181c22),
    surfaceContainer: Color(0xff1c2026),
    surfaceContainerHigh: Color(0xff262a31),
    surfaceContainerHighest: Color(0xff31353c),
    onSurfaceVariant: Color(0xffdac1b9),
    outline: Color(0xffa28c85),
    outlineVariant: Color(0xff54433d),
    inverseSurface: Color(0xffdfe2eb),
    onInverseSurface: Color(0xff2d3137),
    inversePrimary: Color(0xff94492a),
    surfaceTint: Color(0xffffb59a),
    shadow: Colors.black,
    scrim: Colors.black,
  );

  static const _lightScheme = ColorScheme(
    brightness: Brightness.light,
    primary: Color(0xffa04a28),
    onPrimary: Colors.white,
    primaryContainer: Color(0xffffdbce),
    onPrimaryContainer: Color(0xff380d00),
    secondary: Color(0xff00696f),
    onSecondary: Colors.white,
    secondaryContainer: Color(0xffc8f8fa),
    onSecondaryContainer: Color(0xff002022),
    tertiary: Color(0xff8f4a14),
    onTertiary: Colors.white,
    tertiaryContainer: Color(0xffffdbc9),
    onTertiaryContainer: Color(0xff331200),
    error: Color(0xffba1a1a),
    onError: Colors.white,
    errorContainer: Color(0xffffdad6),
    onErrorContainer: Color(0xff410002),
    surface: Colors.white,
    onSurface: Color(0xff191c20),
    surfaceDim: Color(0xffdcd9d8),
    surfaceBright: Colors.white,
    surfaceContainerLowest: Colors.white,
    surfaceContainerLow: Color(0xfff7f4f3),
    surfaceContainer: Color(0xfff2efee),
    surfaceContainerHigh: Color(0xffece9e8),
    surfaceContainerHighest: Color(0xffe6e2e1),
    onSurfaceVariant: Color(0xff55433d),
    outline: Color(0xff85736c),
    outlineVariant: Color(0xffd8c2ba),
    inverseSurface: Color(0xff2d3137),
    onInverseSurface: Color(0xffeff0f7),
    inversePrimary: Color(0xffffb59a),
    surfaceTint: Color(0xffa04a28),
    shadow: Colors.black,
    scrim: Colors.black,
  );

  static TextTheme _text(ColorScheme scheme) {
    TextStyle d(
      double size,
      FontWeight weight,
      double height,
      double spacing,
    ) => TextStyle(
      fontFamily: display,
      fontSize: size,
      fontWeight: weight,
      height: height / size,
      letterSpacing: spacing * size,
      color: scheme.onSurface,
    );
    TextStyle b(
      double size,
      FontWeight weight,
      double height, [
      double spacing = 0,
    ]) => TextStyle(
      fontFamily: body,
      fontSize: size,
      fontWeight: weight,
      height: height / size,
      letterSpacing: spacing * size,
      color: scheme.onSurface,
    );
    return TextTheme(
      displayLarge: d(72, FontWeight.w700, 76, -0.04),
      displayMedium: d(56, FontWeight.w700, 60, -0.03),
      displaySmall: d(44, FontWeight.w700, 50, -0.03),
      headlineLarge: d(32, FontWeight.w700, 40, -0.02),
      headlineMedium: d(26, FontWeight.w700, 32, -0.02),
      headlineSmall: d(22, FontWeight.w600, 28, -0.01),
      titleLarge: d(20, FontWeight.w600, 26, -0.01),
      titleMedium: d(18, FontWeight.w600, 24, 0),
      titleSmall: b(15, FontWeight.w600, 20),
      bodyLarge: b(16, FontWeight.w400, 24),
      bodyMedium: b(14, FontWeight.w400, 20),
      bodySmall: b(12, FontWeight.w400, 16),
      labelLarge: b(16, FontWeight.w600, 22, 0.01),
      labelMedium: b(13, FontWeight.w600, 18, 0.02),
      labelSmall: b(11, FontWeight.w600, 14, 0.04),
    ).apply(bodyColor: scheme.onSurface, displayColor: scheme.onSurface);
  }

  static ThemeData of(Brightness brightness) {
    final light = brightness == Brightness.light;
    final scheme = light ? _lightScheme : _darkScheme;
    final tokens = light ? WakeTokens.light : WakeTokens.dark;
    final text = _text(scheme);
    final cardColor = light ? Colors.white : scheme.surfaceContainer;
    const stadium = StadiumBorder();
    final pillText = text.labelLarge!;

    return ThemeData(
      useMaterial3: true,
      brightness: brightness,
      colorScheme: scheme,
      fontFamily: body,
      textTheme: text,
      extensions: [tokens],
      scaffoldBackgroundColor: scheme.surface,
      canvasColor: scheme.surface,
      splashFactory: InkSparkle.splashFactory,
      appBarTheme: AppBarTheme(
        backgroundColor: scheme.surface,
        foregroundColor: scheme.onSurface,
        surfaceTintColor: Colors.transparent,
        scrolledUnderElevation: 0,
        elevation: 0,
        centerTitle: false,
        titleTextStyle: text.titleLarge,
      ),
      bottomSheetTheme: BottomSheetThemeData(
        backgroundColor: scheme.surface,
        modalBackgroundColor: scheme.surface,
        surfaceTintColor: Colors.transparent,
        dragHandleColor: scheme.outlineVariant,
        shape: const RoundedRectangleBorder(
          borderRadius: BorderRadius.vertical(top: Radius.circular(32)),
        ),
      ),
      cardTheme: CardThemeData(
        color: cardColor,
        surfaceTintColor: Colors.transparent,
        elevation: 0,
        margin: EdgeInsets.zero,
        shape: RoundedRectangleBorder(
          borderRadius: cardRadius,
          side: BorderSide(color: tokens.ghostBorder),
        ),
      ),
      dividerTheme: DividerThemeData(
        color: tokens.ghostBorder,
        thickness: 1,
        space: 1,
      ),
      navigationBarTheme: NavigationBarThemeData(
        backgroundColor: tokens.navBar,
        surfaceTintColor: Colors.transparent,
        indicatorColor: Colors.transparent,
        height: 68,
        elevation: 8,
        shadowColor: Colors.black,
        labelTextStyle: WidgetStateProperty.resolveWith(
          (states) => text.labelSmall!.copyWith(
            letterSpacing: 0.4,
            color: states.contains(WidgetState.selected)
                ? (light ? scheme.primary : tokens.cta)
                : scheme.onSurfaceVariant,
          ),
        ),
        iconTheme: WidgetStateProperty.resolveWith(
          (states) => IconThemeData(
            size: 24,
            color: states.contains(WidgetState.selected)
                ? (light ? scheme.primary : tokens.cta)
                : scheme.onSurfaceVariant,
          ),
        ),
      ),
      filledButtonTheme: FilledButtonThemeData(
        style: FilledButton.styleFrom(
          backgroundColor: tokens.cta,
          foregroundColor: tokens.onCta,
          disabledBackgroundColor: scheme.onSurface.withValues(alpha: 0.12),
          minimumSize: const Size(64, 56),
          padding: const EdgeInsets.symmetric(horizontal: 24),
          shape: stadium,
          textStyle: pillText,
        ),
      ),
      outlinedButtonTheme: OutlinedButtonThemeData(
        style: OutlinedButton.styleFrom(
          foregroundColor: scheme.onSurface,
          backgroundColor: tokens.subtle,
          minimumSize: const Size(64, 52),
          padding: const EdgeInsets.symmetric(horizontal: 20),
          shape: stadium,
          side: BorderSide(color: tokens.ghostBorder),
          textStyle: pillText,
        ),
      ),
      textButtonTheme: TextButtonThemeData(
        style: TextButton.styleFrom(
          foregroundColor: light ? scheme.primary : tokens.dawn,
          minimumSize: const Size(48, 44),
          shape: stadium,
          textStyle: text.labelLarge,
        ),
      ),
      elevatedButtonTheme: ElevatedButtonThemeData(
        style: ElevatedButton.styleFrom(
          backgroundColor: scheme.surfaceContainerHigh,
          foregroundColor: scheme.onSurface,
          minimumSize: const Size(64, 52),
          shape: stadium,
          elevation: 0,
          textStyle: pillText,
        ),
      ),
      segmentedButtonTheme: SegmentedButtonThemeData(
        style: ButtonStyle(
          shape: const WidgetStatePropertyAll(stadium),
          minimumSize: const WidgetStatePropertyAll(Size(48, 48)),
          side: WidgetStatePropertyAll(BorderSide(color: tokens.ghostBorder)),
          textStyle: WidgetStatePropertyAll(text.labelMedium),
          backgroundColor: WidgetStateProperty.resolveWith(
            (states) => states.contains(WidgetState.selected)
                ? tokens.cta
                : scheme.surfaceContainerLow,
          ),
          foregroundColor: WidgetStateProperty.resolveWith(
            (states) => states.contains(WidgetState.selected)
                ? tokens.onCta
                : scheme.onSurface,
          ),
          iconColor: WidgetStateProperty.resolveWith(
            (states) => states.contains(WidgetState.selected)
                ? tokens.onCta
                : scheme.onSurface,
          ),
        ),
      ),
      chipTheme: ChipThemeData(
        shape: stadium,
        side: BorderSide(color: tokens.ghostBorder),
        backgroundColor: scheme.surfaceContainerHigh,
        selectedColor: tokens.cta,
        checkmarkColor: tokens.onCta,
        labelStyle: text.labelMedium,
        secondaryLabelStyle: text.labelMedium!.copyWith(color: tokens.onCta),
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
      ),
      switchTheme: SwitchThemeData(
        thumbColor: WidgetStateProperty.resolveWith((states) {
          if (states.contains(WidgetState.disabled)) {
            return scheme.onSurface.withValues(alpha: 0.38);
          }
          return states.contains(WidgetState.selected)
              ? (light ? Colors.white : const Color(0xff783316))
              : scheme.outline;
        }),
        trackColor: WidgetStateProperty.resolveWith((states) {
          if (states.contains(WidgetState.selected)) {
            return states.contains(WidgetState.disabled)
                ? tokens.cta.withValues(alpha: 0.4)
                : tokens.cta;
          }
          return scheme.surfaceContainerHighest;
        }),
        trackOutlineColor: const WidgetStatePropertyAll(Colors.transparent),
        // An (empty) icon keeps the thumb full-size when off, like the design.
        thumbIcon: const WidgetStatePropertyAll(Icon(null)),
      ),
      listTileTheme: ListTileThemeData(
        iconColor: scheme.onSurfaceVariant,
        titleTextStyle: text.titleSmall,
        subtitleTextStyle: text.bodySmall!.copyWith(
          color: scheme.onSurfaceVariant,
        ),
        shape: const RoundedRectangleBorder(borderRadius: cardRadius),
      ),
      floatingActionButtonTheme: FloatingActionButtonThemeData(
        backgroundColor: tokens.cta,
        foregroundColor: tokens.onCta,
        shape: stadium,
        extendedTextStyle: pillText,
      ),
      progressIndicatorTheme: ProgressIndicatorThemeData(
        color: light ? scheme.primary : tokens.cta,
        linearTrackColor: scheme.surfaceContainerHighest,
      ),
      snackBarTheme: SnackBarThemeData(
        behavior: SnackBarBehavior.floating,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
        backgroundColor: light
            ? scheme.inverseSurface
            : scheme.surfaceContainerHighest,
      ),
      dialogTheme: DialogThemeData(
        backgroundColor: light ? Colors.white : scheme.surfaceContainerHigh,
        surfaceTintColor: Colors.transparent,
        shape: const RoundedRectangleBorder(borderRadius: cardRadius),
      ),
      popupMenuTheme: PopupMenuThemeData(
        color: light ? Colors.white : scheme.surfaceContainerHigh,
        surfaceTintColor: Colors.transparent,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
      ),
      timePickerTheme: TimePickerThemeData(
        backgroundColor: light ? Colors.white : scheme.surfaceContainerHigh,
        shape: const RoundedRectangleBorder(borderRadius: cardRadius),
        // displayLarge (72) is too wide for the picker's fixed hour/minute
        // boxes: with larger system text "00" wraps and shows as "0".
        hourMinuteTextStyle: const TextStyle(
          fontFamily: display,
          fontSize: 48,
          fontWeight: FontWeight.w700,
          fontFeatures: tabular,
        ),
      ),
      inputDecorationTheme: InputDecorationTheme(
        filled: true,
        fillColor: light ? scheme.surfaceContainerLow : scheme.surfaceContainer,
        border: OutlineInputBorder(
          borderRadius: BorderRadius.circular(20),
          borderSide: BorderSide(color: tokens.ghostBorder),
        ),
        enabledBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(20),
          borderSide: BorderSide(color: tokens.ghostBorder),
        ),
        focusedBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(20),
          borderSide: BorderSide(
            color: light ? scheme.primary : tokens.cta,
            width: 1.5,
          ),
        ),
      ),
    );
  }
}
