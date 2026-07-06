import 'dart:ui';

/// Représente un unique `TextElement` ML Kit — un token individuel : un
/// nombre isolé ("0", "75"), un symbole ("€"), un mot... — replacé dans son
/// contexte géométrique.
///
/// BudgetScan n'est pas un OCR généraliste : c'est un détecteur de prix.
/// Il n'interprète pas des phrases, il reconstruit un prix à partir de
/// fragments (ex : "0" + "75" + "€") en exploitant leur position, leur
/// taille de police estimée et leur disposition relative — exactement
/// comme le ferait un humain qui lit une étiquette où les centimes sont
/// affichés en exposant, plus petits que les euros.
class PriceElement {
  final String text;
  final Rect boundingBox;

  PriceElement({required this.text, required this.boundingBox});

  double get left => boundingBox.left;
  double get top => boundingBox.top;
  double get right => boundingBox.right;
  double get bottom => boundingBox.bottom;
  double get width => boundingBox.width;
  double get height => boundingBox.height;
  Offset get center => boundingBox.center;

  /// Hauteur du bloc utilisée comme estimation de la taille de police :
  /// un "75" en exposant (centimes) est presque toujours plus petit à
  /// l'écran que le "12" des euros affiché à sa gauche.
  double get estimatedFontSize => height;

  /// Nombre "pur" de 1 à 3 chiffres (euros, centimes...).
  bool get isPureDigits => RegExp(r'^\d{1,3}$').hasMatch(text);

  /// Symbole monétaire. ML Kit lit parfois "€" comme un "e" isolé sur les
  /// étiquettes de mauvaise qualité, d'où la tolérance minimale.
  bool get isCurrencySymbol =>
      text.trim() == '€' || text.trim().toLowerCase() == 'e';

  /// Token qui contient déjà un prix complet, ex : "1,49" ou "12.95".
  /// C'est le cas le plus simple : ML Kit a réuni euros et centimes dans
  /// un seul élément.
  bool get isDirectPriceToken => RegExp(r'^\d{1,3}[.,]\d{1,2}$').hasMatch(text);

  @override
  String toString() =>
      '"$text" (x=${left.toStringAsFixed(0)}, y=${top.toStringAsFixed(0)}, '
      'w=${width.toStringAsFixed(0)}, h=${height.toStringAsFixed(0)})';
}
