/// Catalogue des conventions d'affichage de prix observées sur le terrain,
/// enseigne par enseigne. Ne remplace ni la reconstruction géométrique
/// (`PriceDetector`) ni la normalisation regex (`RegexNormalizer`) : sert
/// de couche de validation *a posteriori*, pour confirmer qu'un prix
/// reconstruit correspond bien à une forme réellement rencontrée sur le
/// marché plutôt qu'à une coïncidence géométrique isolée.
///
/// Ce catalogue est volontairement un simple tableau déclaratif : chaque
/// nouvelle enseigne testée qui révèle une forme non couverte peut être
/// ajoutée ici en une ligne, sans toucher au reste du pipeline.
class PriceFormatProfile {
  final String label;
  final bool Function(String rawText) matches;

  const PriceFormatProfile({required this.label, required this.matches});
}

class KnownPriceFormats {
  static final List<PriceFormatProfile> profiles = [
    PriceFormatProfile(
      label: 'standard virgule/point (ex : 12,95 ou 12.95)',
      matches: (t) => RegExp(r'^\d{1,3}[.,]\d{2}$').hasMatch(t),
    ),
    PriceFormatProfile(
      label: 'euro comme séparateur (ex : 1€49)',
      matches: (t) => RegExp(r'^\d{1,3}[€e]\d{2}$').hasMatch(t),
    ),
    PriceFormatProfile(
      label: 'espace comme séparateur (ex : 1 49)',
      matches: (t) => RegExp(r'^\d{1,3}\s\d{2}$').hasMatch(t),
    ),
    PriceFormatProfile(
      label: 'centimes seuls, style Lidl (ex : ,79 → 0,79)',
      matches: (t) => RegExp(r'^[.,]\d{2}$').hasMatch(t),
    ),
    PriceFormatProfile(
      label:
          'juxtaposition sans séparateur, style Action (gros chiffre + petit chiffre accolés)',
      matches: (t) => RegExp(r'^\d{1,3}\d{2}$').hasMatch(t),
    ),
  ];

  /// Retourne le libellé du premier profil connu qui correspond au texte
  /// donné, ou `null` si aucune convention cataloguée ne correspond.
  static String? identify(String rawText) {
    final trimmed = rawText.trim();
    for (final profile in profiles) {
      if (profile.matches(trimmed)) return profile.label;
    }
    return null;
  }
}
