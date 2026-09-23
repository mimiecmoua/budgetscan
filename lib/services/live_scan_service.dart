import 'dart:typed_data';
import 'dart:ui';

import 'package:camera/camera.dart';
import 'package:flutter/services.dart';
import 'package:google_mlkit_text_recognition/google_mlkit_text_recognition.dart';

/// Un bloc de texte détecté en direct, avec sa position dans l'image
/// caméra — sert uniquement de GUIDE visuel pendant que l'utilisatrice
/// cadre, jamais utilisé pour extraire un prix (ça reste le rôle du
/// pipeline complet déclenché par la capture).
class LiveTextBlock {
  final Rect boundingBox;
  final bool looksLikePrice;

  LiveTextBlock({required this.boundingBox, required this.looksLikePrice});
}

/// Analyse le flux caméra en continu (avant la capture) pour donner un
/// retour visuel immédiat : "voici ce que je vois comme texte, et voici
/// ce qui ressemble à un prix" — un guide de cadrage en direct, pas une
/// nouvelle façon d'extraire les prix (le pipeline complet sur la photo
/// capturée reste seul responsable de ça, avec toute sa rigueur
/// géométrique). Ce service reste volontairement simple et rapide : il
/// doit tourner plusieurs fois par seconde sans ralentir l'aperçu.
class LiveScanService {
  final TextRecognizer _recognizer = TextRecognizer(
    script: TextRecognitionScript.latin,
  );

  bool _busy = false;

  /// À appeler à chaque image du flux caméra (cf. CameraService).
  /// Ignore silencieusement les images reçues pendant qu'une analyse
  /// précédente est encore en cours (logique "drop-frame") : plus sûr et
  /// plus fluide que d'empiler les images plus vite qu'on ne les traite.
  Future<List<LiveTextBlock>> analyzeFrame(
    CameraImage image,
    CameraDescription camera,
  ) async {
    if (_busy) return [];
    _busy = true;
    try {
      final inputImage = _convert(image, camera);
      if (inputImage == null) {
        // ignore: avoid_print
        print('[LiveGuide] Conversion échouée (rotation ou format non '
            'reconnu) — image ignorée.');
        return [];
      }

      final recognizedText = await _recognizer.processImage(inputImage);
      // ignore: avoid_print
      print('[LiveGuide] ${recognizedText.blocks.length} bloc(s) détecté(s) '
          'sur cette image.');
      return recognizedText.blocks
          .map(
            (block) => LiveTextBlock(
              boundingBox: block.boundingBox,
              looksLikePrice: _looksLikePrice(block.text),
            ),
          )
          .toList();
    } catch (e) {
      // ignore: avoid_print
      print('[LiveGuide] Erreur pendant l\'analyse : $e');
      return [];
    } finally {
      _busy = false;
    }
  }

  /// Estimation très légère, volontairement plus simple que
  /// PriceDetector : sert juste à teinter un bloc différemment à
  /// l'écran, pas à décider quoi que ce soit. Un bloc avec au moins 2
  /// chiffres, ou le symbole €, "ressemble" à un prix.
  bool _looksLikePrice(String text) {
    final digitCount =
        text.split('').where((c) => RegExp(r'\d').hasMatch(c)).length;
    return digitCount >= 2 || text.contains('€');
  }

  /// Convertit une image brute du flux caméra (format YUV420/NV21 selon
  /// l'appareil) en InputImage exploitable par ML Kit. C'est la partie
  /// technique la plus délicate de ce service — bien documentée, mais
  /// spécifique à Android ici (l'app ne cible qu'Android pour l'instant).
  InputImage? _convert(CameraImage image, CameraDescription camera) {
    final rotation =
        InputImageRotationValue.fromRawValue(camera.sensorOrientation);
    if (rotation == null) {
      // ignore: avoid_print
      print('[LiveGuide] Rotation non reconnue : '
          '${camera.sensorOrientation}');
      return null;
    }

    final format = InputImageFormatValue.fromRawValue(image.format.raw);
    if (format == null) {
      // ignore: avoid_print
      print('[LiveGuide] Format image non reconnu : ${image.format.raw}');
      return null;
    }

    final writeBuffer = WriteBuffer();
    for (final plane in image.planes) {
      writeBuffer.putUint8List(plane.bytes);
    }
    final Uint8List bytes = writeBuffer.done().buffer.asUint8List();

    return InputImage.fromBytes(
      bytes: bytes,
      metadata: InputImageMetadata(
        size: Size(image.width.toDouble(), image.height.toDouble()),
        rotation: rotation,
        format: format,
        bytesPerRow: image.planes.first.bytesPerRow,
      ),
    );
  }

  void dispose() {
    _recognizer.close();
  }
}
