import 'price_element.dart';

/// Un prix reconstruit à partir d'un ou plusieurs [PriceElement].
///
/// Peut provenir d'un seul token déjà complet ("1,49"), ou de la
/// composition géométrique de plusieurs tokens séparés ("0" + "75" + "€").
/// [reason] et [sourceElements] sont conservés uniquement pour les logs de
/// debug (comprendre pourquoi ce prix a été retenu).
class ComposedPrice {
  final double value;
  final List<PriceElement> sourceElements;
  final String reason;
  int score;

  ComposedPrice({
    required this.value,
    required this.sourceElements,
    required this.reason,
    this.score = 0,
  });

  @override
  String toString() {
    final tokens = sourceElements.map((e) => '"${e.text}"').join(' + ');
    return 'prix=${value.toStringAsFixed(2)}€ | score=$score | '
        'tokens=$tokens | ($reason)';
  }
}
