import 'dart:math' as math;
import 'dart:ui';

import 'package:google_mlkit_text_recognition/google_mlkit_text_recognition.dart';

import '../models/composed_price.dart';
import '../models/price_element.dart';
import 'known_price_formats.dart';
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
  final List<PriceElement> retainedElements;

  PriceDetectionResult({
    required this.price,
    required this.candidates,
    required this.elementsInZone,
    required this.elementsRejectedOutsideZone,
    this.retainedElements = const [],
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
        retainedElements: [],
      );
    }

    final candidates = <ComposedPrice>[];

    // Cas simple : un seul élément contient déjà un prix complet ("1,49").
    for (final element in elementsInZone) {
      if (element.isDirectPriceToken) {
        final value = normalizer.extract(element.text);
        if (value == null) continue;

        // Confronte la forme brute au catalogue des conventions connues
        // (cf. KnownPriceFormats) : un prix qui correspond à une forme
        // réellement observée sur le marché est plus fiable qu'une simple
        // coïncidence de regex.
        final knownFormat = KnownPriceFormats.identify(element.text);

        candidates.add(ComposedPrice(
          value: value,
          sourceElements: [element],
          reason: knownFormat != null
              ? 'token direct — format connu : $knownFormat'
              : 'token direct — format non catalogué',
        ));
        continue;
      }

      // Cas "confusion OCR" : le petit exposant (€, virgule) a fusionné
      // avec les chiffres et les a fait mal lire ("o`79" au lieu de
      // "0,79"). On tente une correction des confusions classiques avant
      // d'abandonner ce token.
      final cleaned = element.cleanedDigitsOnly;
      if (cleaned == null) continue;

      final centsStr = cleaned.substring(cleaned.length - 2);
      final eurosStr = cleaned.substring(0, cleaned.length - 2);
      final value = double.tryParse('$eurosStr.$centsStr');
      if (value == null) continue;

      candidates.add(ComposedPrice(
        value: value,
        sourceElements: [element],
        reason: 'token direct — caractères ambigus corrigés '
            '("${element.text}" → "$cleaned")',
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
        retainedElements: elementsInZone,
      );
    }

    _scoreCandidates(candidates, imageSize);
    // En cas d'égalité de score, le tri de Dart n'est pas garanti stable
    // — un token déjà complet ("13.99") doit toujours l'emporter sur un
    // assemblage géométrique de plusieurs éléments, même à score égal :
    // c'est structurellement une lecture plus sûre qu'une reconstruction.
    // Vu en conditions réelles : "13,99€" et un "760,60€" assemblé à
    // partir de fragments non liés, à égalité parfaite (score 90/90).
    candidates.sort((a, b) {
      final scoreDiff = b.score.compareTo(a.score);
      if (scoreDiff != 0) return scoreDiff;
      final aIsDirect = a.reason.startsWith('token direct') ? 0 : 1;
      final bIsDirect = b.reason.startsWith('token direct') ? 0 : 1;
      return aIsDirect.compareTo(bIsDirect);
    });

    for (final candidate in candidates) {
      final sourceText = candidate.sourceElements.map((e) => e.text).join(' ');
      if (validator.isValid(candidate.value, sourceText)) {
        return PriceDetectionResult(
          price: candidate.value,
          candidates: candidates,
          elementsInZone: elementsInZone.length,
          elementsRejectedOutsideZone: rejectedCount,
          retainedElements: elementsInZone,
        );
      }
    }

    return PriceDetectionResult(
      price: null,
      candidates: candidates,
      elementsInZone: elementsInZone.length,
      elementsRejectedOutsideZone: rejectedCount,
      retainedElements: elementsInZone,
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
    // On indexe chaque élément par sa version "chiffres corrigés" plutôt
    // que son texte brut : un "0" lu comme la lettre "O" doit quand même
    // pouvoir jouer le rôle du nombre "euros" dans la reconstruction.
    final digitElements = <PriceElement, String>{};
    for (final element in elements) {
      final normalized = element.normalizedDigits;
      if (normalized != null) digitElements[element] = normalized;
    }
    final currencyElements =
        elements.where((e) => e.isCurrencySymbol).toList();

    final composed = <ComposedPrice>[];

    for (final euros in digitElements.keys) {
      final eurosDigits = digitElements[euros]!;
      // Un nombre "euros" plausible fait au plus 3 chiffres (évite les
      // codes-barres, poids, quantités en grammes...).
      if (eurosDigits.length > 3) continue;

      for (final cents in digitElements.keys) {
        if (identical(euros, cents)) continue;
        final centsDigits = digitElements[cents]!;
        if (centsDigits.length > 2) continue;

        // Règles géométriques (cahier des charges v2, point 16) :
        //   - petit nombre, à droite, plus haut  → centimes en exposant
        //   - grand nombre                        → euros
        //   - OU : même taille, même ligne, juste séparés par un espace
        //     (ex : "8 99 €") — cas fréquent qu'une simple comparaison de
        //     taille de police ne peut pas capturer, car les deux nombres
        //     sont visuellement identiques.
        final isToTheRight = cents.left >= euros.right - (euros.width * 0.2);
        final isSmallerFont =
            cents.estimatedFontSize < euros.estimatedFontSize * 0.85;
        final isHigher = cents.top < euros.top - (euros.height * 0.1);
        final isSameLineSameSize = _isSameLineSameSize(euros, cents);
        final maxNeighbourDistance = euros.height * 3;
        final distance = (cents.center - euros.center).distance;

        if (!isToTheRight) continue;
        if (!(isSmallerFont || isHigher || isSameLineSameSize)) continue;
        if (distance > maxNeighbourDistance) continue;

        // Un seul chiffre de centimes est traité comme un dixième
        // (ex : "59" + "5" → 59.50), cas plus rare mais déjà vu sur des
        // étiquettes promotionnelles.
        final centsText = centsDigits.length == 1 ? '${centsDigits}0' : centsDigits;
        final value = double.tryParse('$eurosDigits.$centsText');
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
  ///       + 15 supplémentaires si sa forme correspond à une convention
  ///         cataloguée dans KnownPriceFormats (ex : style Lidl, Action...)
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

      if (candidate.reason.startsWith('token direct')) {
        if (candidate.reason.contains('corrigés')) {
          // Un prix à 3 chiffres d'euros (donc 5 chiffres fusionnés à
          // l'origine, ex : "34500" → 345,00€) ressemble beaucoup à un
          // code postal ou une référence produit — vu en conditions
          // réelles (34500 = code postal de Béziers, confondu un instant
          // avec un prix). On le score plus bas par prudence, sans
          // l'interdire complètement.
          score += candidate.value >= 100 ? 20 : 35;
        } else {
          score += 50;
          if (candidate.reason.contains('format connu')) score += 15;
        }
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

          // Même taille, même ligne (ex : "8 99 €") : signal fiable même
          // sans différence de police, on lui donne aussi du crédit.
          if (_isSameLineSameSize(euros, cents)) score += 15;
        }
      }

      final avgCenter = _averageCenter(elements);
      final distance = (avgCenter - center).distance;
      final proximity = 1 - (distance / (maxDistance == 0 ? 1 : maxDistance));
      if (proximity > 0.6) score += 25;

      candidate.score = score;
    }
  }

  /// Détecte le cas "8 99 €" : deux nombres de taille comparable, dont les
  /// hauteurs se chevauchent fortement (même ligne visuelle), séparés
  /// seulement par un espace — sans différence de taille de police ni
  /// décalage vertical notable.
  bool _isSameLineSameSize(PriceElement euros, PriceElement cents) {
    final overlapTop = math.max(euros.top, cents.top);
    final overlapBottom = math.min(euros.bottom, cents.bottom);
    final overlap = math.max(0.0, overlapBottom - overlapTop);
    final smallerHeight = math.min(euros.height, cents.height);
    if (smallerHeight <= 0) return false;

    final verticalOverlapRatio = overlap / smallerHeight;
    final sizeRatio = cents.estimatedFontSize / euros.estimatedFontSize;

    return verticalOverlapRatio > 0.6 && sizeRatio > 0.7 && sizeRatio < 1.3;
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
