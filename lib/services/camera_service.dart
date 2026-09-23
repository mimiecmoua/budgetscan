import 'dart:ui';

import 'package:camera/camera.dart';

/// Encapsule tout ce qui touche à la caméra : initialisation, réglages
/// automatiques (mise au point, exposition), flash et prise de photo.
///
/// Isoler cette logique permet de la remplacer ou de la tester
/// indépendamment du reste du pipeline (crop, OCR, extraction de prix).
class CameraService {
  CameraController? controller;

  bool get isReady => controller?.value.isInitialized ?? false;

  Future<void> initialize(List<CameraDescription> cameras) async {
    controller = CameraController(
      cameras.first,
      // Retour à `high` après test : les cas difficiles du jour (0€79,
      // 11€09) ont été résolus par le nettoyage des confusions OCR
      // (cleanedDigitsOnly), pas par la résolution de capture. `veryHigh`
      // ralentissait sans bénéfice prouvé — à retester plus tard si de
      // nouveaux cas d'échec semblent liés à un manque de détail brut.
      ResolutionPreset.high,
      enableAudio: false,
    );

    await controller!.initialize();

    // Mise au point et exposition automatiques et continues, réglées avant
    // toute capture. Remarque : le package `camera` ne permet pas de piloter
    // explicitement la balance des blancs ; elle reste gérée nativement par
    // le capteur du téléphone.
    await controller!.setFocusMode(FocusMode.auto);
    await controller!.setExposureMode(ExposureMode.auto);
  }

  Future<void> setFlash(bool enabled) async {
    if (controller == null) return;
    await controller!.setFlashMode(enabled ? FlashMode.torch : FlashMode.off);
  }

  /// Zoom au pincement : bornes réelles données par le matériel du
  /// téléphone (varient d'un appareil à l'autre), pour rester dans une
  /// plage que la caméra accepte vraiment.
  Future<double> getMinZoom() async {
    if (controller == null) return 1.0;
    return controller!.getMinZoomLevel();
  }

  Future<double> getMaxZoom() async {
    if (controller == null) return 1.0;
    return controller!.getMaxZoomLevel();
  }

  Future<void> setZoom(double level) async {
    if (controller == null) return;
    await controller!.setZoomLevel(level);
  }

  /// Force la mise au point ET l'exposition sur un point précis (les deux
  /// coordonnées entre 0.0 et 1.0, relatives à l'aperçu) plutôt que de
  /// laisser l'autofocus général décider — indispensable pour que la
  /// caméra vise nettement le rectangle de scan, pas "la scène" en
  /// général. Attend un court instant pour laisser la mise au point se
  /// stabiliser avant de considérer que c'est fait.
  Future<void> focusOn(Offset point) async {
    if (controller == null) return;
    await controller!.setFocusPoint(point);
    await controller!.setExposurePoint(point);
    // Laisse le temps physique au moteur de mise au point de se
    // stabiliser — sans ça, la photo peut être prise pendant que
    // l'objectif est encore en train de bouger, d'où le flou aléatoire.
    await Future.delayed(const Duration(milliseconds: 400));
  }

  /// Description de la caméra active — nécessaire pour convertir
  /// correctement les images du flux continu (orientation du capteur).
  CameraDescription? get description => controller?.description;

  bool get isStreaming => controller?.value.isStreamingImages ?? false;

  /// Démarre l'analyse en continu du flux caméra (avant toute capture) —
  /// c'est la base du guide de cadrage en direct : chaque image du flux
  /// est transmise à [onImage], qui décide quoi en faire (throttling,
  /// conversion pour l'OCR...).
  Future<void> startImageStream(void Function(CameraImage) onImage) async {
    if (controller == null || isStreaming) return;
    await controller!.startImageStream(onImage);
  }

  /// À arrêter avant takePicture() : certains téléphones n'aiment pas
  /// streamer et capturer une vraie photo en même temps.
  Future<void> stopImageStream() async {
    if (controller == null || !isStreaming) return;
    await controller!.stopImageStream();
  }

  Future<XFile> takePicture() async {
    if (controller == null) {
      throw StateError('CameraService : caméra non initialisée.');
    }
    return controller!.takePicture();
  }

  void dispose() {
    controller?.dispose();
  }
}
