/// Valide qu'un prix candidat est plausible en tant que prix principal
/// d'un produit, et rejette les faux positifs fréquents : codes-barres,
/// poids, mentions "prix au kg", "ancien prix", etc.
class PriceValidator {
  static const List<String> _forbiddenKeywords = [
    'prix',
    'kg',
    'lot',
    'promo',
    'ancien prix',
    'au litre',
    "l'unité",
  ];

  /// Un prix plausible est strictement positif et inférieur à 1000 €.
  bool _isPlausibleRange(double price) => price > 0 && price < 1000;

  /// Rejette les nombres bruts trop longs (codes-barres, références) ou
  /// composés d'un seul chiffre répété (ex : 111111, 987654 étant un cas
  /// à part géré par la longueur).
  bool _looksLikeJunkNumber(String sourceText) {
    final digitsOnly = sourceText.replaceAll(RegExp(r'[^\d]'), '');
    if (digitsOnly.length >= 6) return true;
    if (digitsOnly.length >= 4 && RegExp(r'^(\d)\1+$').hasMatch(digitsOnly)) {
      return true;
    }
    return false;
  }

  bool _containsForbiddenKeyword(String sourceText) {
    final lower = sourceText.toLowerCase();
    return _forbiddenKeywords.any(lower.contains);
  }

  /// Retourne `true` si [price], extrait depuis [sourceText], peut être
  /// retenu comme prix principal.
  bool isValid(double price, String sourceText) {
    if (!_isPlausibleRange(price)) return false;
    if (_looksLikeJunkNumber(sourceText)) return false;
    if (_containsForbiddenKeyword(sourceText)) return false;
    return true;
  }
}
