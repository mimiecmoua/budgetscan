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
      // Haute résolution : nécessaire pour que l'OCR dispose de suffisamment
      // de détail sur le prix après crop. À comparer avec `veryHigh` sur
      // Samsung A13 (compromis qualité / latence / taille de fichier).
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
