import 'dart:math' as math;
import 'dart:ui';

import 'package:google_mlkit_text_recognition/google_mlkit_text_recognition.dart';

import '../models/composed_price.dart';
import '../models/price_element.dart';
import 'price_validator.dart';
import 'regex_normalizer.dart';

/// Résultat complet d'une détection : le prix retenu (ou `null`), tous les
/// candidats évalués (triés du meilleur au moins bon, pour les logs), et
/// des compteurs de diagnostic sur le filtrage géométrique.
class PriceDetectionResult {
  final double? price;
  final List<ComposedPrice> candidates;
  final int elementsInZone;
  final int elementsRejectedOutsideZone;

  PriceDetectionResult({
    required this.price,
    required this.candidates,
    required this.elementsInZone,
    required this.elementsRejectedOutsideZone,
  });
}

/// BudgetScan n'est pas un OCR généraliste. C'est un détecteur de prix.
///
/// Ce service ne travaille JAMAIS sur `recognizedText.text`. Il descend
/// jusqu'au niveau `TextElement` (blocks → lines → elements), vérifie que
/// chaque élément est bien à l'intérieur du rectangle bleu — seule source
/// de vérité de la détection — puis reconstruit le prix en exploitant sa
/// géométrie : taille de police estimée, position relative, proximité.
///
/// Exemple concret que ce service sait gérer et que l'ancienne version
/// (basée sur des regex globales) ne gérait pas : ML Kit renvoie "0", "75"
/// et "€" comme trois éléments séparés (le "75" étant affiché en exposant,
/// plus petit et plus haut) → le service reconstruit "0.75 €".
class PriceDetector {
  final RegexNormalizer normalizer;
  final PriceValidator validator;

  /// Marge de sécurité (fraction de la largeur/hauteur de l'image) à
  /// l'intérieur de laquelle un élément doit se trouver pour être pris en
  /// compte. Exclut le texte partiellement coupé aux bords du crop, même
  /// si le crop déborde légèrement du rectangle bleu affiché à l'écran.
  static const double _zoneMarginRatio = 0.04;

  PriceDetector({RegexNormalizer? normalizer, PriceValidator? validator})
      : normalizer = normalizer ?? RegexNormalizer(),
        validator = validator ?? PriceValidator();

  PriceDetectionResult detect(RecognizedText recognizedText, Size imageSize) {
    final Rect trustedZone = _trustedZone(imageSize);

    final allElements = _flattenElements(recognizedText);

    // Vérification géométrique post-OCR : un élément dont le centre tombe
    // hors du rectangle de confiance est totalement ignoré, même s'il a
    // été techniquement inclus dans l'image envoyée à ML Kit.
    final elementsInZone = <PriceElement>[];
    var rejectedCount = 0;
    for (final element in allElements) {
      if (trustedZone.contains(element.center)) {
        elementsInZone.add(element);
      } else {
        rejectedCount++;
      }
    }

    if (elementsInZone.isEmpty) {
      return PriceDetectionResult(
        price: null,
        candidates: [],
        elementsInZone: 0,
        elementsRejectedOutsideZone: rejectedCount,
      );
    }

    final candidates = <ComposedPrice>[];

    // Cas simple : un seul élément contient déjà un prix complet ("1,49").
    for (final element in elementsInZone) {
      if (!element.isDirectPriceToken) continue;
      final value = normalizer.extract(element.text);
      if (value == null) continue;
      candidates.add(ComposedPrice(
        value: value,
        sourceElements: [element],
        reason: 'token direct',
      ));
    }

    // Cas géométrique : reconstruction euros + centimes (+ €) à partir de
    // plusieurs éléments distincts.
    candidates.addAll(_composeFromDigitPairs(elementsInZone));

    if (candidates.isEmpty) {
      return PriceDetectionResult(
        price: null,
        candidates: [],
        elementsInZone: elementsInZone.length,
        elementsRejectedOutsideZone: rejectedCount,
      );
    }

    _scoreCandidates(candidates, imageSize);
    candidates.sort((a, b) => b.score.compareTo(a.score));

    for (final candidate in candidates) {
      final sourceText = candidate.sourceElements.map((e) => e.text).join(' ');
      if (validator.isValid(candidate.value, sourceText)) {
        return PriceDetectionResult(
          price: candidate.value,
          candidates: candidates,
          elementsInZone: elementsInZone.length,
          elementsRejectedOutsideZone: rejectedCount,
        );
      }
    }

    return PriceDetectionResult(
      price: null,
      candidates: candidates,
      elementsInZone: elementsInZone.length,
      elementsRejectedOutsideZone: rejectedCount,
    );
  }

  /// Rectangle de confiance : l'image entière (déjà cropée sur le
  /// rectangle bleu) moins une petite marge sur chaque bord, pour ignorer
  /// le texte partiellement coupé au moment du crop.
  Rect _trustedZone(Size imageSize) {
    final marginX = imageSize.width * _zoneMarginRatio;
    final marginY = imageSize.height * _zoneMarginRatio;
    return Rect.fromLTRB(
      marginX,
      marginY,
      imageSize.width - marginX,
      imageSize.height - marginY,
    );
  }

  /// Descend jusqu'au niveau TextElement : blocks → lines → elements.
  /// On ne travaille jamais sur `recognizedText.text`.
  List<PriceElement> _flattenElements(RecognizedText recognizedText) {
    final elements = <PriceElement>[];
    for (final block in recognizedText.blocks) {
      for (final line in block.lines) {
        for (final element in line.elements) {
          elements.add(PriceElement(
            text: element.text,
            boundingBox: element.boundingBox,
          ));
        }
      }
    }
    return elements;
  }

  /// Reconstruit un prix à partir de deux éléments numériques distincts :
  /// un "grand nombre" (euros) et un "petit nombre" positionné à sa droite
  /// et/ou plus haut (centimes en exposant) — confirmé si possible par un
  /// symbole € à proximité.
  List<ComposedPrice> _composeFromDigitPairs(List<PriceElement> elements) {
    final digitElements = elements.where((e) => e.isPureDigits).toList();
    final currencyElements =
        elements.where((e) => e.isCurrencySymbol).toList();

    final composed = <ComposedPrice>[];

    for (final euros in digitElements) {
      // Un nombre "euros" plausible fait au plus 3 chiffres (évite les
      // codes-barres, poids, quantités en grammes...).
      if (euros.text.length > 3) continue;

      for (final cents in digitElements) {
        if (identical(euros, cents)) continue;
        if (cents.text.length > 2) continue;

        // Règles géométriques (cahier des charges v2, point 16) :
        //   - petit nombre, à droite, plus haut  → centimes
        //   - grand nombre                        → euros
        final isToTheRight = cents.left >= euros.right - (euros.width * 0.2);
        final isSmallerFont =
            cents.estimatedFontSize < euros.estimatedFontSize * 0.85;
        final isHigher = cents.top < euros.top - (euros.height * 0.1);
        final maxNeighbourDistance = euros.height * 3;
        final distance = (cents.center - euros.center).distance;

        if (!isToTheRight) continue;
        if (!(isSmallerFont || isHigher)) continue;
        if (distance > maxNeighbourDistance) continue;

        // Un seul chiffre de centimes est traité comme un dixième
        // (ex : "59" + "5" → 59.50), cas plus rare mais déjà vu sur des
        // étiquettes promotionnelles.
        final centsText = cents.text.length == 1 ? '${cents.text}0' : cents.text;
        final value = double.tryParse('${euros.text}.$centsText');
        if (value == null) continue;

        // € à proximité : renforce la confiance sans être obligatoire
        // (ML Kit le rate souvent sur les petites étiquettes).
        PriceElement? nearbyCurrency;
        for (final currency in currencyElements) {
          if ((currency.center - cents.center).distance <=
              maxNeighbourDistance) {
            nearbyCurrency = currency;
            break;
          }
        }

        composed.add(ComposedPrice(
          value: value,
          sourceElements: [
            euros,
            cents,
            if (nearbyCurrency != null) nearbyCurrency,
          ],
          reason: nearbyCurrency != null
              ? 'euros+centimes+€ (géométrie)'
              : 'euros+centimes (géométrie)',
        ));
      }
    }

    return composed;
  }

  /// Score de confiance :
  ///   - Token direct déjà combiné ("1,49")        → base 50 (très fiable)
  ///   - Sinon (reconstruction géométrique) :
  ///       +40 si un symbole € a été trouvé à proximité
  ///       +20 si le nombre "euros" a une police nettement plus grande
  ///       +10 si les deux éléments sont verticalement proches
  ///   - Commun aux deux cas :
  ///       +25 si le candidat est proche du centre du rectangle de scan
  void _scoreCandidates(List<ComposedPrice> candidates, Size imageSize) {
    final center = Offset(imageSize.width / 2, imageSize.height / 2);
    final maxDistance = math.sqrt(
          imageSize.width * imageSize.width +
              imageSize.height * imageSize.height,
        ) /
        2;

    for (final candidate in candidates) {
      int score = 0;
      final elements = candidate.sourceElements;

      if (candidate.reason == 'token direct') {
        score += 50;
      } else {
        if (elements.any((e) => e.isCurrencySymbol)) score += 40;

        if (elements.length >= 2) {
          final euros = elements[0];
          final cents = elements[1];
          if (euros.estimatedFontSize > cents.estimatedFontSize * 1.15) {
            score += 20;
          }
          final verticalGap = (euros.center.dy - cents.center.dy).abs();
          if (verticalGap < euros.height * 1.5) score += 10;
        }
      }

      final avgCenter = _averageCenter(elements);
      final distance = (avgCenter - center).distance;
      final proximity = 1 - (distance / (maxDistance == 0 ? 1 : maxDistance));
      if (proximity > 0.6) score += 25;

      candidate.score = score;
    }
  }

  Offset _averageCenter(List<PriceElement> elements) {
    double x = 0, y = 0;
    for (final e in elements) {
      x += e.center.dx;
      y += e.center.dy;
    }
    return Offset(x / elements.length, y / elements.length);
  }
}
