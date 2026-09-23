import 'dart:ui';

import 'package:camera/camera.dart';
import 'package:flutter_litert/flutter_litert.dart';

/// Le "viseur géométrique" : indique OÙ se trouve probablement le prix
/// (une boîte, en coordonnées de l'image caméra), sans jamais lire le
/// texte lui-même — ça reste entièrement le travail de ML Kit
/// (LiveScanService pour le guide en direct, OcrService pour la lecture
/// finale). Séparer les deux responsabilités, c'est tout l'intérêt de
/// cette approche par rapport à l'ancienne tentative "YOLO fait l'OCR".
///
/// !! IMPORTANT : ce service ne fait rien tant qu'un vrai modèle entraîné
/// n'est pas placé dans assets/ml/ et déclaré dans pubspec.yaml. Les
/// hypothèses ci-dessous (taille d'entrée 640×640, forme de sortie
/// [1, 5, 8400]) correspondent à un export YOLOv8n standard à une seule
/// classe — à confirmer avec les logs [PriceZone] une fois ton modèle
/// chargé, et à ajuster si les tailles réelles diffèrent.
class PriceZoneDetector {
  Interpreter? _interpreter;
  IsolateInterpreter? _isolateInterpreter;
  bool _busy = false;

  // Ton modèle existe déjà sous ce nom, et il est même déjà déclaré dans
  // pubspec.yaml depuis le tout début du projet (assets/ml/best_float32.tflite)
  // — aucune modification de pubspec.yaml nécessaire.
  static const String _modelPath = 'assets/ml/best_float32.tflite';

  // Taille d'entrée standard d'un export YOLOv8n — à vérifier avec le
  // premier print("[PriceZone] Entrée attendue : ...") une fois le
  // modèle chargé.
  static const int _inputSize = 640;

  static const double _confidenceThreshold = 0.4;

  bool get isReady => _isolateInterpreter != null;

  /// Charge le modèle — à appeler une fois, avant tout traitement
  /// d'image (typiquement en même temps que la caméra s'initialise).
  ///
  /// IsolateInterpreter (fourni nativement par flutter_litert) fait
  /// tourner l'inférence sur un isolate séparé — exactement le même
  /// principe que compute() pour ImageProcessor, mais directement
  /// intégré au package plutôt qu'à construire à la main. Sans ça,
  /// chaque inférence YOLO bloquerait le thread principal et figerait
  /// l'affichage le temps du calcul.
  Future<void> loadModel() async {
    try {
      _interpreter = await Interpreter.fromAsset(_modelPath);
      final inputShape = _interpreter!.getInputTensor(0).shape;
      final outputShape = _interpreter!.getOutputTensor(0).shape;
      // ignore: avoid_print
      print('[PriceZone] Modèle chargé — entrée : $inputShape, '
          'sortie : $outputShape');
      // ignore: avoid_print
      print('[PriceZone] Si ces tailles diffèrent de _inputSize=640 ou '
          'de [1, 5, 8400], le décodage ci-dessous doit être ajusté en '
          'conséquence.');

      _isolateInterpreter = await IsolateInterpreter.create(
        address: _interpreter!.address,
      );
    } catch (e) {
      // ignore: avoid_print
      print('[PriceZone] Échec du chargement — vérifie que '
          '"$_modelPath" existe bien et est déclaré dans pubspec.yaml. '
          'Erreur : $e');
      _interpreter = null;
      _isolateInterpreter = null;
    }
  }

  /// Analyse une image du flux caméra et retourne la zone la plus
  /// probable du prix (en coordonnées de l'image d'origine), ou `null`
  /// si rien d'assez confiant n'a été trouvé. Même logique "drop-frame"
  /// que LiveScanService : une image reçue pendant qu'une analyse
  /// précédente tourne encore est simplement ignorée.
  Future<Rect?> detectZone(
    CameraImage image,
    CameraDescription camera,
  ) async {
    if (_isolateInterpreter == null || _busy) return null;
    _busy = true;
    try {
      final input = _prepareInput(image);

      // Sortie YOLOv8n à 1 classe, format standard [1, 5, N] : pour
      // chacune des N prédictions (8400 par défaut en 640×640),
      // [x_centre, y_centre, largeur, hauteur, confiance] — tout est
      // exprimé en pixels du repère 640×640 de l'entrée.
      const numAnchors = 8400;
      final output = List.generate(
        1,
        (_) => List.generate(5, (_) => List.filled(numAnchors, 0.0)),
      );

      // .run() sur IsolateInterpreter est asynchrone : le calcul se fait
      // sur l'isolate séparé, le thread principal reste libre pendant ce
      // temps (contrairement à interpreter.run(), synchrone et bloquant).
      await _isolateInterpreter!.run(input, output);

      // On ne garde que la MEILLEURE confiance : on ne cherche qu'UNE
      // seule zone de prix à la fois, pas plusieurs objets — pas besoin
      // de suppression non-maximale (NMS) ici.
      double bestConfidence = _confidenceThreshold;
      int bestIndex = -1;
      for (var i = 0; i < numAnchors; i++) {
        final confidence = output[0][4][i];
        if (confidence > bestConfidence) {
          bestConfidence = confidence;
          bestIndex = i;
        }
      }
      if (bestIndex == -1) return null;

      final cx = output[0][0][bestIndex];
      final cy = output[0][1][bestIndex];
      final w = output[0][2][bestIndex];
      final h = output[0][3][bestIndex];

      // Reconvertit du repère 640×640 (entrée du modèle) vers le repère
      // réel de l'image caméra.
      final scaleX = image.width / _inputSize;
      final scaleY = image.height / _inputSize;

      return Rect.fromCenter(
        center: Offset(cx * scaleX, cy * scaleY),
        width: w * scaleX,
        height: h * scaleY,
      );
    } catch (e) {
      // ignore: avoid_print
      print('[PriceZone] Erreur pendant l\'inférence : $e');
      return null;
    } finally {
      _busy = false;
    }
  }

  /// Convertit l'image caméra (YUV420, le format brut standard sur
  /// Android) en tenseur d'entrée normalisé 640×640×3, valeurs 0.0-1.0 —
  /// le format d'entrée standard d'un export YOLOv8n en float32.
  ///
  /// Point de performance important : on échantillonne DIRECTEMENT aux
  /// 640×640 positions dont on a besoin dans l'image source, plutôt que
  /// de convertir l'image entière (souvent bien plus grande, ex.
  /// 1920×1080) puis la redimensionner après coup. Ça évite de calculer
  /// des millions de pixels inutiles à chaque image du flux — exactement
  /// le genre de calcul superflu qui avait fait chauffer/planter l'app
  /// quand cette fonction ne faisait encore rien d'utile.
  List<List<List<List<double>>>> _prepareInput(CameraImage image) {
    final yPlane = image.planes[0];
    final uPlane = image.planes[1];
    final vPlane = image.planes[2];

    final yRowStride = yPlane.bytesPerRow;
    final yPixelStride = yPlane.bytesPerPixel ?? 1;
    final uvRowStride = uPlane.bytesPerRow;
    final uvPixelStride = uPlane.bytesPerPixel ?? 1;

    final srcWidth = image.width;
    final srcHeight = image.height;

    return List.generate(
      1,
      (_) => List.generate(_inputSize, (row) {
        final srcY = (row * srcHeight / _inputSize)
            .floor()
            .clamp(0, srcHeight - 1);
        return List.generate(_inputSize, (col) {
          final srcX = (col * srcWidth / _inputSize)
              .floor()
              .clamp(0, srcWidth - 1);

          final yIndex = srcY * yRowStride + srcX * yPixelStride;
          final uvX = srcX ~/ 2;
          final uvY = srcY ~/ 2;
          final uvIndex = uvY * uvRowStride + uvX * uvPixelStride;

          final yVal = yPlane.bytes[yIndex].toDouble();
          final uVal = uPlane.bytes[uvIndex].toDouble();
          final vVal = vPlane.bytes[uvIndex].toDouble();

          // Conversion YUV → RGB standard (BT.601).
          final r = (yVal + 1.402 * (vVal - 128)).clamp(0, 255);
          final g = (yVal -
                  0.344136 * (uVal - 128) -
                  0.714136 * (vVal - 128))
              .clamp(0, 255);
          final b = (yVal + 1.772 * (uVal - 128)).clamp(0, 255);

          return [r / 255.0, g / 255.0, b / 255.0];
        });
      }),
    );
  }

  void dispose() {
    _isolateInterpreter?.close();
    _interpreter?.close();
  }
}
