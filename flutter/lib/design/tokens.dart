import 'package:flutter/material.dart';

/// Shelly Hermes design tokens.
///
/// PHASE 44: light is the first-class mode — an Apple-grade cool gray
/// canvas (#F5F5F7) with white cards, near-black ink text and hairline
/// borders. The brand blue→violet gradient is demoted to accent moments
/// (avatar, loading states); primary actions use ink instead. Dark remains
/// fully supported but secondary: three deep grays, hairline borders.
abstract final class AppColors {
  // Brand gradient (identical in both modes, accent-only usage).
  static const Color brandBlue = Color(0xFF3B82F6);
  static const Color brandViolet = Color(0xFF8B5CF6);
  static const List<Color> brandGradient = [brandBlue, brandViolet];

  /// Ink accent for primary actions in light mode (Premium palette).
  static const Color inkAccent = Color(0xFF1D1D1F);

  // Status. Light mode gets deeper, higher-contrast tones; dark keeps the
  // brighter ones.
  static const Color successLight = Color(0xFF2E7D32);
  static const Color warningLight = Color(0xFFB26A00);
  static const Color dangerLight = Color(0xFFB3261E);
  static const Color success = Color(0xFF34D399);
  static const Color warning = Color(0xFFFBBF24);
  static const Color danger = Color(0xFFF87171);

  // Dark (secondary mode).
  static const Color darkBackground = Color(0xFF0A0A0B);
  static const Color darkCard = Color(0xFF141416);
  static const Color darkFloating = Color(0xFF1E1E21);
  static const Color darkBorder = Color(0xFF26262B);
  static const Color darkTextPrimary = Color(0xFFF2F2F7);
  static const Color darkTextSecondary = Color(0xFFA0A0AA);
  static const Color darkTextTertiary = Color(0xFF6B6B74);

  // Light (first-class mode).
  static const Color lightBackground = Color(0xFFF5F5F7);
  static const Color lightCard = Color(0xFFFFFFFF);
  static const Color lightFloating = Color(0xFFECECF1);
  static const Color lightBorder = Color(0xFFE5E5EA);
  static const Color lightTextPrimary = Color(0xFF1D1D1F);
  static const Color lightTextSecondary = Color(0xFF6E6E73);
  static const Color lightTextTertiary = Color(0xFFAEAEB2);

  /// Soft ambient shadow for elevated white cards on the gray canvas.
  static List<BoxShadow> get cardShadow => [
        BoxShadow(
          color: const Color(0xFF1D1D1F).withValues(alpha: 0.04),
          blurRadius: 12,
          offset: const Offset(0, 2),
        ),
        BoxShadow(
          color: const Color(0xFF1D1D1F).withValues(alpha: 0.03),
          blurRadius: 3,
          offset: const Offset(0, 1),
        ),
      ];
}

abstract final class AppSpacing {
  static const double xs = 4;
  static const double sm = 8;
  static const double md = 12;
  static const double lg = 16;
  static const double xl = 24;
  static const double xxl = 32;
}

/// Radius discipline: three production tiers plus the pill. Cards use lg,
/// chips/small controls sm/md, sheets and hero surfaces xl, pills for
/// full-round controls only.
abstract final class AppRadius {
  static const double sm = 8;
  static const double md = 12;
  static const double lg = 18;
  static const double xl = 24;
  static const double pill = 999;
}

/// Motion tokens (motion-design discipline): animate transform/opacity
/// only, entrance curves ease-out, restraint in dense areas.
abstract final class AppMotion {
  /// Micro-interactions: buttons, switches, chips.
  static const Duration fast = Duration(milliseconds: 150);

  /// Enter/exit and floating layers.
  static const Duration normal = Duration(milliseconds: 250);

  /// Page-level transitions.
  static const Duration slow = Duration(milliseconds: 350);

  /// Premium displacement curve (ease-out, fast approach + gentle settle).
  static const Curve emphasized = Cubic(0.16, 1.0, 0.3, 1.0);

  /// Standard ease-out for entrances.
  static const Curve easeOut = Curves.easeOutCubic;

  /// Exit curve: gather energy and leave.
  static const Curve easeIn = Curves.easeInCubic;

  /// Linear — loading indicators only.
  static const Curve linear = Curves.linear;

  /// List stagger interval; orchestrate at most the first 8 items.
  static const Duration staggerInterval = Duration(milliseconds: 40);
  static const int staggerMaxItems = 8;
}

/// Semantic palette resolved per brightness; UI code reads colors from here
/// (via the theme extension) instead of hard-coding dark or light values.
@immutable
class AppSemanticColors extends ThemeExtension<AppSemanticColors> {
  const AppSemanticColors({
    required this.background,
    required this.card,
    required this.floating,
    required this.border,
    required this.textPrimary,
    required this.textSecondary,
    required this.textTertiary,
    required this.brandGradient,
    required this.success,
    required this.warning,
    required this.danger,
    required this.accent,
    required this.onAccent,
    required this.cardShadow,
  });

  final Color background;
  final Color card;
  final Color floating;
  final Color border;
  final Color textPrimary;
  final Color textSecondary;
  final Color textTertiary;
  final List<Color> brandGradient;

  /// Status colors resolved per brightness.
  final Color success;
  final Color warning;
  final Color danger;

  /// Primary-action accent: ink in light mode, white-ish in dark mode.
  final Color accent;
  final Color onAccent;

  /// Ambient shadow for elevated cards (empty in dark mode — hairline
  /// borders carry the hierarchy there).
  final List<BoxShadow> cardShadow;

  static const dark = AppSemanticColors(
    background: AppColors.darkBackground,
    card: AppColors.darkCard,
    floating: AppColors.darkFloating,
    border: AppColors.darkBorder,
    textPrimary: AppColors.darkTextPrimary,
    textSecondary: AppColors.darkTextSecondary,
    textTertiary: AppColors.darkTextTertiary,
    brandGradient: AppColors.brandGradient,
    success: AppColors.success,
    warning: AppColors.warning,
    danger: AppColors.danger,
    accent: AppColors.darkTextPrimary,
    onAccent: AppColors.darkBackground,
    cardShadow: [],
  );

  static final light = AppSemanticColors(
    background: AppColors.lightBackground,
    card: AppColors.lightCard,
    floating: AppColors.lightFloating,
    border: AppColors.lightBorder,
    textPrimary: AppColors.lightTextPrimary,
    textSecondary: AppColors.lightTextSecondary,
    textTertiary: AppColors.lightTextTertiary,
    brandGradient: AppColors.brandGradient,
    success: AppColors.successLight,
    warning: AppColors.warningLight,
    danger: AppColors.dangerLight,
    accent: AppColors.inkAccent,
    onAccent: Colors.white,
    cardShadow: AppColors.cardShadow,
  );

  @override
  AppSemanticColors copyWith({
    Color? background,
    Color? card,
    Color? floating,
    Color? border,
    Color? textPrimary,
    Color? textSecondary,
    Color? textTertiary,
    List<Color>? brandGradient,
    Color? success,
    Color? warning,
    Color? danger,
    Color? accent,
    Color? onAccent,
    List<BoxShadow>? cardShadow,
  }) {
    return AppSemanticColors(
      background: background ?? this.background,
      card: card ?? this.card,
      floating: floating ?? this.floating,
      border: border ?? this.border,
      textPrimary: textPrimary ?? this.textPrimary,
      textSecondary: textSecondary ?? this.textSecondary,
      textTertiary: textTertiary ?? this.textTertiary,
      brandGradient: brandGradient ?? this.brandGradient,
      success: success ?? this.success,
      warning: warning ?? this.warning,
      danger: danger ?? this.danger,
      accent: accent ?? this.accent,
      onAccent: onAccent ?? this.onAccent,
      cardShadow: cardShadow ?? this.cardShadow,
    );
  }

  @override
  AppSemanticColors lerp(ThemeExtension<AppSemanticColors>? other, double t) {
    if (other is! AppSemanticColors) return this;
    return AppSemanticColors(
      background: Color.lerp(background, other.background, t)!,
      card: Color.lerp(card, other.card, t)!,
      floating: Color.lerp(floating, other.floating, t)!,
      border: Color.lerp(border, other.border, t)!,
      textPrimary: Color.lerp(textPrimary, other.textPrimary, t)!,
      textSecondary: Color.lerp(textSecondary, other.textSecondary, t)!,
      textTertiary: Color.lerp(textTertiary, other.textTertiary, t)!,
      brandGradient: List.generate(
        brandGradient.length,
        (i) => Color.lerp(brandGradient[i], other.brandGradient[i], t)!,
      ),
      success: Color.lerp(success, other.success, t)!,
      warning: Color.lerp(warning, other.warning, t)!,
      danger: Color.lerp(danger, other.danger, t)!,
      accent: Color.lerp(accent, other.accent, t)!,
      onAccent: Color.lerp(onAccent, other.onAccent, t)!,
      cardShadow: BoxShadow.lerpList(cardShadow, other.cardShadow, t)!,
    );
  }
}
