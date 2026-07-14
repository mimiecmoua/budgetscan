import 'package:flutter/foundation.dart';
import 'package:image/image.dart' as img;

/// Prépare l'image cropée pour l'OCR, en n'utilisant que le package
/// `image` (pas d'OpenCV) :
///
///   crop → grayscale → autocontraste → netteté (sharpen) → resize x2 → ML Kit
class ImageProcessor {
  /// Exécute le pipeline complet **sur un isolate séparé** (via `compute`)
  /// plutôt que sur le fil d'exécution principal. Ce traitement est
  /// intensif en calcul (convolution, redimensionnement) : le faire sur
  /// le fil principal pouvait geler l'affichage le temps du calcul (voire
  /// déclencher "l'app ne répond pas" sur les scans les plus lourds).
  /// Ici, l'app reste réactive (animation du bouton, etc.) pendant que le
  /// calcul se fait en arrière-plan.
  Future<ProcessedImageSteps> process(img.Image crop) {
    return compute(_runImageProcessing, crop);
  }
}

/// Fonction "top-level" (hors classe) : c'est une exigence de `compute()`,
/// qui doit pouvoir l'envoyer telle quelle à l'isolate d'arrière-plan.
ProcessedImageSteps _runImageProcessing(img.Image crop) {
  // 1. Niveaux de gris.
  final grayscale = img.grayscale(crop);
  // On garde un instantané avant l'étape suivante, car `normalize` modifie
  // l'image en place et retourne la même référence.
  final grayscaleSnapshot = img.Image.from(grayscale);

  // Luminosité moyenne (0 = noir, 255 = blanc), échantillonnée plutôt que
  // calculée sur tous les pixels pour rester rapide. Sert à avertir
  // l'utilisateur quand la zone scannée est trop sombre pour un bon OCR.
  final averageBrightness = _estimateAverageBrightness(grayscaleSnapshot);

  // 2. Autocontraste : étire la plage de luminosité sur 0-255, ce qui
  // améliore le contraste entre le texte et le fond de l'étiquette.
  final autocontrast = img.normalize(grayscale, min: 0, max: 255);

  // 3. Netteté : noyau de convolution de renforcement des contours.
  // Matrice classique de sharpen 3x3 (somme des coefficients = 1).
  final sharpened = img.convolution(
    autocontrast,
    filter: <double>[0, -1, 0, -1, 5, -1, 0, -1, 0],
    div: 1,
  );
  final sharpenedSnapshot = img.Image.from(sharpened);

  // 4. Agrandissement x2 : donne plus de pixels par caractère à ML Kit,
  // ce qui améliore généralement la reconnaissance sur de petites
  // étiquettes de prix.
  final resized = img.copyResize(
    sharpened,
    width: sharpened.width * 2,
    height: sharpened.height * 2,
    interpolation: img.Interpolation.cubic,
  );

  return ProcessedImageSteps(
    grayscale: grayscaleSnapshot,
    sharpened: sharpenedSnapshot,
    finalImage: resized,
    averageBrightness: averageBrightness,
  );
}

/// Échantillonne 1 pixel sur 8 (dans les deux axes) plutôt que l'image
/// entière — largement suffisant pour estimer la luminosité globale, sans
/// alourdir le traitement.
double _estimateAverageBrightness(img.Image grayscale) {
  const stride = 8;
  double total = 0;
  int count = 0;
  for (int y = 0; y < grayscale.height; y += stride) {
    for (int x = 0; x < grayscale.width; x += stride) {
      total += grayscale.getPixel(x, y).r;
      count++;
    }
  }
  return count == 0 ? 255 : total / count;
}

/// Étapes intermédiaires du prétraitement, conservées pour pouvoir générer
/// les images de debug : photo originale → crop → grayscale → sharpen → OCR.
class ProcessedImageSteps {
  final img.Image grayscale;
  final img.Image sharpened;
  final img.Image finalImage;

  /// Luminosité moyenne de la zone scannée (0 = noir, 255 = blanc).
  /// Sous ~90, la zone est probablement trop sombre pour un bon OCR.
  final double averageBrightness;

  ProcessedImageSteps({
    required this.grayscale,
    required this.sharpened,
    required this.finalImage,
    required this.averageBrightness,
  });
}
