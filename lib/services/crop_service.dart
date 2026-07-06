import 'package:flutter/material.dart';
import 'package:image/image.dart' as img;

/// Recadre la photo capturée sur la zone exacte du rectangle bleu affiché
/// à l'écran.
///
/// Le calcul suit strictement :
///   GlobalKey → RenderBox → rectangle englobant (topLeft + size) → crop
///
/// Aucun offset "magique" n'est appliqué (l'ancien `+80` a été supprimé) :
/// toutes les coordonnées proviennent exclusivement du RenderBox et de la
/// mise à l'échelle photo/écran.
class CropService {
  /// Retourne l'image cropée, ou `null` si la géométrie du widget n'a pas
  /// pu être déterminée (widget pas encore posé, contexte détruit...).
  ///
  /// [expectedAspectRatio] (largeur/hauteur du rectangle bleu affiché à
  /// l'écran) permet de vérifier que le crop obtenu correspond bien à la
  /// zone attendue. Le rectangle bleu doit rester la seule source de
  /// vérité : si le ratio dévie fortement, c'est le signe d'un problème de
  /// mise à l'échelle écran/photo, à corriger avant de faire confiance à
  /// la suite du pipeline.
  img.Image? crop({
    required GlobalKey scanBoxKey,
    required img.Image fullImage,
    double? expectedAspectRatio,
  }) {
    final context = scanBoxKey.currentContext;
    if (context == null) return null;

    final renderObject = context.findRenderObject();
    if (renderObject is! RenderBox || !renderObject.hasSize) return null;

    final RenderBox box = renderObject;
    final Offset topLeft = box.localToGlobal(Offset.zero);
    final Size boxSize = box.size;
    final Size screenSize = MediaQuery.of(context).size;

    // Échelle entre la résolution réelle de la photo et la taille logique
    // (dp) de l'écran. C'est la seule transformation appliquée.
    final double scaleX = fullImage.width / screenSize.width;
    final double scaleY = fullImage.height / screenSize.height;

    final int x1 = (topLeft.dx * scaleX).round().clamp(0, fullImage.width);
    final int y1 = (topLeft.dy * scaleY).round().clamp(0, fullImage.height);
    final int x2 = ((topLeft.dx + boxSize.width) * scaleX)
        .round()
        .clamp(0, fullImage.width);
    final int y2 = ((topLeft.dy + boxSize.height) * scaleY)
        .round()
        .clamp(0, fullImage.height);

    final int cropWidth = (x2 - x1).clamp(1, fullImage.width);
    final int cropHeight = (y2 - y1).clamp(1, fullImage.height);

    final result = img.copyCrop(
      fullImage,
      x: x1,
      y: y1,
      width: cropWidth,
      height: cropHeight,
    );

    if (expectedAspectRatio != null) {
      _verifyAspectRatio(result, expectedAspectRatio);
    }

    return result;
  }

  /// Vérification de cohérence : le crop obtenu doit avoir sensiblement le
  /// même ratio largeur/hauteur que le rectangle bleu affiché à l'écran.
  /// Une déviation importante indique que le crop ne correspond plus
  /// exactement à la zone visée (marge de tolérance de 15%).
  void _verifyAspectRatio(img.Image cropped, double expectedAspectRatio) {
    final actualRatio = cropped.width / cropped.height;
    final deviation =
        (actualRatio - expectedAspectRatio).abs() / expectedAspectRatio;
    if (deviation > 0.15) {
      // ignore: avoid_print
      print('⚠️ CropService : le ratio du crop dévie fortement du '
          'rectangle attendu (attendu=${expectedAspectRatio.toStringAsFixed(2)}, '
          'obtenu=${actualRatio.toStringAsFixed(2)}).');
    }
  }
}
