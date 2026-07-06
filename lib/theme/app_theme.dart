import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';

/// Palette "fintech premium" : fond graphite profond, verre dépoli
/// (transparence), accents néon émeraude/cyan (dynamisme, tendance),
/// touche or discrète pour le côté "sérieux / haut de gamme".
class AppColors {
  AppColors._();

  static const Color bgTop = Color(0xFF0A0F1E);
  static const Color bgBottom = Color(0xFF050810);

  static const Color glassFill = Color(0x14FFFFFF); // blanc ~8%
  static const Color glassBorder = Color(0x26FFFFFF); // blanc ~15%
  static const Color glassStroke = Color(0x40FFFFFF);

  static const Color emerald = Color(0xFF00F5A0);
  static const Color cyan = Color(0xFF00D2FF);
  static const Color gold = Color(0xFFE7C873);
  static const Color danger = Color(0xFFFF5C7A);

  static const Color textPrimary = Color(0xFFF4F6FA);
  static const Color textSecondary = Color(0xFF9AA5B8);
  static const Color textMuted = Color(0xFF5C6478);

  static const LinearGradient primaryGradient = LinearGradient(
    begin: Alignment.topLeft,
    end: Alignment.bottomRight,
    colors: [emerald, cyan],
  );

  static const LinearGradient goldGradient = LinearGradient(
    begin: Alignment.topLeft,
    end: Alignment.bottomRight,
    colors: [Color(0xFFF3DA9C), gold],
  );

  static const LinearGradient bgGradient = LinearGradient(
    begin: Alignment.topCenter,
    end: Alignment.bottomCenter,
    colors: [bgTop, bgBottom],
  );
}

/// Typo "chic / hightech / futuriste" : Space Grotesk pour les titres et
/// les chiffres (géométrique, contemporain), Inter pour le texte courant
/// (lisibilité, sobriété).
class AppText {
  AppText._();

  static TextStyle display({
    double size = 28,
    Color color = AppColors.textPrimary,
    FontWeight weight = FontWeight.w700,
    double? letterSpacing,
  }) => GoogleFonts.spaceGrotesk(
    fontSize: size,
    fontWeight: weight,
    color: color,
    letterSpacing: letterSpacing ?? -0.2,
  );

  static TextStyle mono({
    double size = 14,
    Color color = AppColors.textPrimary,
    FontWeight weight = FontWeight.w500,
  }) => GoogleFonts.spaceGrotesk(
    fontSize: size,
    fontWeight: weight,
    color: color,
  );

  static TextStyle body({
    double size = 14,
    Color color = AppColors.textPrimary,
    FontWeight weight = FontWeight.w400,
  }) => GoogleFonts.inter(fontSize: size, fontWeight: weight, color: color);

  static TextStyle label({
    double size = 11,
    Color color = AppColors.textSecondary,
    double letterSpacing = 1.6,
  }) => GoogleFonts.inter(
    fontSize: size,
    fontWeight: FontWeight.w600,
    color: color,
    letterSpacing: letterSpacing,
  );
}

/// Décoration "verre dépoli" réutilisable pour panneaux et cartes.
BoxDecoration glassDecoration({
  double radius = 20,
  Color? borderColor,
  double borderWidth = 1,
  Color fill = AppColors.glassFill,
}) {
  return BoxDecoration(
    color: fill,
    borderRadius: BorderRadius.circular(radius),
    border: Border.all(
      color: borderColor ?? AppColors.glassBorder,
      width: borderWidth,
    ),
  );
}

/// Texte à dégradé (utilisé pour le logo et le total).
class GradientText extends StatelessWidget {
  final String text;
  final TextStyle style;
  final Gradient gradient;
  const GradientText(
    this.text, {
    super.key,
    required this.style,
    this.gradient = AppColors.primaryGradient,
  });

  @override
  Widget build(BuildContext context) {
    return ShaderMask(
      shaderCallback: (bounds) => gradient.createShader(
        Rect.fromLTWH(0, 0, bounds.width, bounds.height),
      ),
      child: Text(text, style: style.copyWith(color: Colors.white)),
    );
  }
}
