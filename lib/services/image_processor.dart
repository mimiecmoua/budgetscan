import 'package:image/image.dart' as img;

/// Prépare l'image cropée pour l'OCR, en n'utilisant que le package
/// `image` (pas d'OpenCV) :
///
///   crop → grayscale → autocontraste → netteté (sharpen) → resize x2 → ML Kit
class ImageProcessor {
  /// Exécute le pipeline complet et retourne chaque étape intermédiaire
  /// (utile pour générer les images de debug demandées dans le cahier des
  /// charges).
  ProcessedImageSteps process(img.Image crop) {
    // 1. Niveaux de gris.
    final grayscale = img.grayscale(crop);
    // On garde un instantané avant l'étape suivante, car `normalize` modifie
    // l'image en place et retourne la même référence.
    final grayscaleSnapshot = img.Image.from(grayscale);

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
    );
  }
}

/// Étapes intermédiaires du prétraitement, conservées pour pouvoir générer
/// les images de debug : photo originale → crop → grayscale → sharpen → OCR.
class ProcessedImageSteps {
  final img.Image grayscale;
  final img.Image sharpened;
  final img.Image finalImage;

  ProcessedImageSteps({
    required this.grayscale,
    required this.sharpened,
    required this.finalImage,
  });
}
