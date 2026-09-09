/// Convertit un texte brut OCR en prix (double), en n'acceptant qu'un
/// nombre volontairement restreint de formats plausibles pour un prix
/// affiché en supermarché français.
///
/// Formats acceptés (dans cet ordre de priorité) :
///   1.49    1,49    12.95   12,95   → séparateur décimal classique
///   1€49    2€75                    → € utilisé comme séparateur
///   1 49                            → espace comme séparateur
///   149                             → 3 chiffres bruts, sans séparateur
///
/// Toute autre forme de nombre (codes-barres, poids, quantités...) est
/// délibérément ignorée ici ; c'est le rôle du [PriceValidator] de rejeter
/// les faux positifs restants.
class RegexNormalizer {
  static final List<RegExp> _patterns = [
    RegExp(r'(\d{1,3})[.,](\d{2})'),
    RegExp(r'(\d{1,3})\s*[€e]\s*(\d{2})'),
    RegExp(r'(\d{1,3})\s(\d{2})\b'),
    RegExp(r'\b(\d)(\d{2})\b'),
  ];

  /// Tente d'extraire un prix depuis un texte. Retourne `null` si aucun
  /// des formats acceptés n'est trouvé.
  double? extract(String rawText) {
    final cleaned = _cleanText(rawText);

    // Format "centimes seuls" (ex : ",79" chez Lidl, quand le prix est
    // inférieur à 1€ et que le "0" des euros n'est pas affiché du tout).
    final centsOnly = RegExp(r'^[.,](\d{2})$').firstMatch(cleaned);
    if (centsOnly != null) {
      return double.tryParse('0.${centsOnly.group(1)}');
    }

    // Format "prix rond, tiret pour les centimes" (ex : "4,-€" = 4,00€).
    final noCents = RegExp(r'^€?(\d{1,3}),-€?$').firstMatch(cleaned);
    if (noCents != null) {
      return double.tryParse('${noCents.group(1)}.00');
    }

    // Format "prix rond, juste chiffres + €" (ex : "45€" = 45,00€, "119€"
    // = 119,00€, vu chez Ikea). Vérifié AVANT la boucle générique pour
    // éviter que le motif "3 chiffres bruts" plus bas interprète par
    // erreur "119€" comme "1,19€".
    final wholeEuro = RegExp(r'^(\d{1,3})€$').firstMatch(cleaned);
    if (wholeEuro != null) {
      return double.tryParse('${wholeEuro.group(1)}.00');
    }

    for (final pattern in _patterns) {
      final match = pattern.firstMatch(cleaned);
      if (match == null) continue;

      final euros = match.group(1);
      final cents = match.group(2);
      if (euros == null || cents == null) continue;

      final price = double.tryParse('$euros.$cents');
      if (price != null) return price;
    }
    return null;
  }

  /// Retire les mentions non numériques qui pourraient perturber le
  /// pattern matching (unités, devise écrite en toutes lettres...).
  String _cleanText(String text) {
    return text
        .replaceAll(RegExp(r'EUR|eur', caseSensitive: false), '')
        .replaceAll(RegExp(r'€\s*/\s*(kg|l|u)', caseSensitive: false), '')
        .trim();
  }
}
