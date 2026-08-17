import 'package:flutter/material.dart';

/// Design tokens for the camera UI.
///
/// The camera HUD is a dark, glass-over-imagery surface, so the palette
/// follows a 60 / 30 / 10 split: translucent black surfaces (60%), white
/// text/icons at three opacities (30%), and ONE accent for the active
/// state (10%). Red is reserved for recording and errors, green for
/// meaningful success moments (a scanner hit) — never for decoration.
abstract final class AppColors {
  /// The single accent — active mode, selected lens/chip, focus ring.
  static const Color accent = Color(0xFFFFD60A); // iOS Camera yellow
  static const Color onAccent = Color(0xFF141414);

  /// Recording state + destructive / error moments only.
  static const Color danger = Color(0xFFFF453A);

  /// Meaningful success feedback only (scanner hit, saved).
  static const Color success = Color(0xFF30D158);

  /// Glass surfaces over the live preview.
  static const Color surface = Color(0xB30E1114); // ~70% black-blue
  static const Color surfaceStrong = Color(0xE60B0E11); // ~90%
  static const Color surfaceRaised = Color(0x1AFFFFFF); // white 10%
  static const Color border = Color(0x26FFFFFF); // white 15%

  /// Text / icon ramp on dark surfaces.
  static const Color onSurface = Colors.white;
  static const Color onSurfaceMuted = Color(0xB3FFFFFF); // 70%
  static const Color onSurfaceDim = Color(0x80FFFFFF); // 50%

  /// Accent at 12% — secondary emphasis (selected chip fill, badges).
  static Color get accentSoft => accent.withValues(alpha: 0.12);
  static Color get accentBorder => accent.withValues(alpha: 0.5);
}

/// One family, four sizes, two weights. Numeric readouts use the monospace
/// variants so digits don't jitter as values change.
abstract final class AppText {
  static const String _mono = 'monospace';

  /// Large numeric readout (zoom factor, timers).
  static const TextStyle display = TextStyle(
    fontSize: 24,
    fontWeight: FontWeight.w600,
    fontFamily: _mono,
    color: AppColors.onSurface,
    height: 1.1,
  );

  /// Section titles / sheet headings.
  static const TextStyle title = TextStyle(
    fontSize: 16,
    fontWeight: FontWeight.w600,
    color: AppColors.onSurface,
    height: 1.25,
  );

  /// Body copy, values, descriptions.
  static const TextStyle body = TextStyle(
    fontSize: 13,
    fontWeight: FontWeight.w400,
    color: AppColors.onSurfaceMuted,
    height: 1.35,
  );

  /// Body with emphasis (selected value, primary label).
  static const TextStyle bodyStrong = TextStyle(
    fontSize: 13,
    fontWeight: FontWeight.w600,
    color: AppColors.onSurface,
    height: 1.35,
  );

  /// Compact HUD label — the smallest size in the app. Upper-case labels get
  /// letter-spacing so they read as labels, not shouting.
  static const TextStyle label = TextStyle(
    fontSize: 11,
    fontWeight: FontWeight.w600,
    letterSpacing: 0.8,
    color: AppColors.onSurface,
    height: 1.2,
  );

  static const TextStyle labelMuted = TextStyle(
    fontSize: 11,
    fontWeight: FontWeight.w400,
    letterSpacing: 0.8,
    color: AppColors.onSurfaceMuted,
    height: 1.2,
  );

  /// Numeric HUD value (EV, fps, ms).
  static const TextStyle mono = TextStyle(
    fontSize: 13,
    fontWeight: FontWeight.w600,
    fontFamily: _mono,
    color: AppColors.onSurface,
    height: 1.2,
  );

  static const TextStyle monoLabel = TextStyle(
    fontSize: 11,
    fontWeight: FontWeight.w600,
    fontFamily: _mono,
    letterSpacing: 0.4,
    color: AppColors.onSurface,
    height: 1.2,
  );
}

/// 8-point grid.
abstract final class AppSpace {
  static const double xs = 4;
  static const double s = 8;
  static const double m = 12;
  static const double l = 16;
  static const double xl = 24;
  static const double xxl = 32;
  static const double xxxl = 48;
}

abstract final class AppRadius {
  static const double chip = 12;
  static const double card = 16;
  static const double sheet = 24;
  static const double pill = 999;
}

/// Minimum touch target (iOS HIG / Material): 44 pt.
abstract final class AppSize {
  static const double tapMin = 44;
  static const double chipHeight = 40; // visual height; hit slop pads to 44
  static const double iconS = 18;
  static const double iconM = 22;
  static const double iconL = 28;
}

/// Soft shadows tinted to the (black) surface — never hard grey drops.
abstract final class AppShadow {
  static List<BoxShadow> get soft => [
        BoxShadow(
          color: Colors.black.withValues(alpha: 0.35),
          blurRadius: 16,
          offset: const Offset(0, 4),
        ),
      ];

  static List<BoxShadow> get raised => [
        BoxShadow(
          color: Colors.black.withValues(alpha: 0.5),
          blurRadius: 24,
          offset: const Offset(0, 8),
        ),
      ];

  /// Accent glow behind the active/primary element (blur + opacity).
  static List<BoxShadow> glow(Color color, {double alpha = 0.35}) => [
        BoxShadow(
          color: color.withValues(alpha: alpha),
          blurRadius: 20,
          spreadRadius: 1,
        ),
      ];
}

abstract final class AppMotion {
  static const Duration fast = Duration(milliseconds: 120);
  static const Duration normal = Duration(milliseconds: 220);
  static const Duration slow = Duration(milliseconds: 360);
  static const Curve curve = Curves.easeOutCubic;
  static const Curve pop = Curves.easeOutBack;
}
