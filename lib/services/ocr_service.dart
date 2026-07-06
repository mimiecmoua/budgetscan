import 'package:google_mlkit_text_recognition/google_mlkit_text_recognition.dart';

/// Encapsule ML Kit derrière une interface minimale.
///
/// Objectif "BudgetScan V3" : pouvoir remplacer ML Kit par un modèle
/// spécialisé (YOLO GPU, TensorFlite Lite, OCR maison...) sans toucher au
/// reste du pipeline. Il suffira de fournir une nouvelle implémentation de
/// [recognize] qui retourne un objet compatible (ou d'adapter
/// [PriceDetector] pour accepter un format plus générique que
/// `RecognizedText`).
class OcrService {
  final TextRecognizer _recognizer = TextRecognizer(
    script: TextRecognitionScript.latin,
  );

  /// Lance la reconnaissance de texte sur l'image prétraitée.
  /// On conserve volontairement l'objet `RecognizedText` complet
  /// (blocks / lines / elements) : on ne travaille jamais uniquement sur
  /// `recognizedText.text`, pour permettre l'analyse spatiale des blocs.
  Future<RecognizedText> recognize(String imagePath) async {
    final inputImage = InputImage.fromFilePath(imagePath);
    return _recognizer.processImage(inputImage);
  }

  void dispose() {
    _recognizer.close();
  }
}
