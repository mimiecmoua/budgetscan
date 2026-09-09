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

  static final RegExp _decimalToken = RegExp(r'^€?\d{1,3}[.,]\d{1,2}€?$');
  static final RegExp _euroSeparatorToken = RegExp(r'^\d{1,3}[€e]\d{2}$');
  static final RegExp _noCentsToken = RegExp(r'^€?\d{1,3},-€?$');
  // Prix rond, juste un nombre suivi de € — vu chez Ikea (45€, 119€), sans
  // virgule ni point du tout. Volontairement séparé de la reconstruction
  // "3-5 chiffres = derniers 2 en centimes" (cleanedDigitsOnly) : ce
  // raccourci aurait lu "119€" comme 1,19€, une erreur grossière — ici on
  // sait explicitement qu'il n'y a pas de centimes, donc pas de calcul à
  // deviner.
  static final RegExp _wholeEuroToken = RegExp(r'^\d{1,3}€$');

  /// Token qui contient déjà un prix complet. Couvre :
  ///   - séparateur classique, avec ou sans € collé : "1,49", "12,40€", "€12.99"
  ///   - € utilisé comme séparateur décimal : "2€49", "5€99"
  ///   - prix rond, tiret pour les centimes : "4,-€" (= 4,00€)
  ///   - prix rond, juste chiffres + € : "45€", "119€" (= 45,00€, 119,00€)
  /// C'est le cas le plus simple : ML Kit a réuni euros et centimes (et
  /// parfois le symbole €) dans un seul élément.
  bool get isDirectPriceToken =>
      _decimalToken.hasMatch(text) ||
      _euroSeparatorToken.hasMatch(text) ||
      _noCentsToken.hasMatch(text) ||
      _wholeEuroToken.hasMatch(text);

  /// Un fragment "99€" : des chiffres de centimes directement collés au
  /// symbole €, sans espace ni exposant — vu chez Ikea, où le prix est
  /// parfois éclaté en deux éléments séparés ("9" pour les euros, "99€"
  /// pour les centimes+devise). Retourne les chiffres seuls si le motif
  /// correspond, pour servir de candidat "centimes" dans la
  /// reconstruction géométrique.
  String? get centsFusedWithCurrency {
    final match = RegExp(r'^(\d{1,2})€$').firstMatch(text);
    return match?.group(1);
  }

  /// Version tolérante de [isPureDigits] : accepte aussi un nombre isolé
  /// mal lu à cause d'une confusion OCR classique (la lettre "O" pour le
  /// chiffre "0", "l"/"I" pour "1"), un fragment de symbole parasite resté
  /// collé ("o`" au lieu de "0", "]43" au lieu de "43"), ou un point/une
  /// virgule isolé devant les centimes (".99" au lieu de "99", vu chez
  /// King Jouet où les centimes sont écrits ainsi, positionnés en dessous
  /// du prix plutôt qu'à droite). Retourne la version corrigée si
  /// exploitable, sinon `null`.
  String? get normalizedDigits {
    final cleaned = text
        .replaceAll(RegExp(r'''[°'`ʻ´\[\]().,"]'''), '')
        .replaceAll(RegExp(r'[oO]'), '0')
        .replaceAll(RegExp(r'[lI]'), '1');
    return RegExp(r'^\d{1,3}$').hasMatch(cleaned) ? cleaned : null;
  }

  /// Tente de corriger les confusions OCR classiques rencontrées quand un
  /// petit exposant (€, virgule) fusionne avec les chiffres au lieu
  /// d'être ignoré : la lettre "o"/"O" est presque toujours un "0" mal lu,
  /// "l"/"I" un "1" mal lu, et les apostrophes/guillemets courbes/degrés/
  /// crochets/points-virgules parasites remplacent souvent le symbole
  /// fondu. Ex : "o`79" → "079", "1lo9" → "1109", "199o0" → "19900"
  /// (= 199,00€), "339." → "339" (= 3,39€, le petit exposant des
  /// centimes n'a laissé qu'un point parasite derrière lui).
  ///
  /// Ne retourne un résultat que si, une fois nettoyé, le token est un
  /// nombre pur de 3 à 5 chiffres (sinon on risque de corrompre un vrai
  /// mot) — jamais utilisé pour des tokens qui ne ressemblent déjà pas à
  /// un prix fusionné. 5 chiffres couvre les prix à 3 chiffres d'euros
  /// fusionnés avec 2 chiffres de centimes (ex : 199,00€).
  String? get cleanedDigitsOnly {
    final cleaned = text
        .replaceAll(RegExp(r'''[°'`ʻ´\[\]().,"]'''), '')
        .replaceAll(RegExp(r'[oO]'), '0')
        .replaceAll(RegExp(r'[lI]'), '1');
    return RegExp(r'^\d{3,5}$').hasMatch(cleaned) ? cleaned : null;
  }

  @override
  String toString() =>
      '"$text" (x=${left.toStringAsFixed(0)}, y=${top.toStringAsFixed(0)}, '
      'w=${width.toStringAsFixed(0)}, h=${height.toStringAsFixed(0)})';
}
