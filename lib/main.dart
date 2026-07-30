import 'dart:async';
import 'dart:io';
import 'dart:typed_data';
import 'dart:ui';

import 'package:camera/camera.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:image/image.dart' as img;
import 'package:path_provider/path_provider.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:wakelock_plus/wakelock_plus.dart';

import 'models/scanned_product.dart';
import 'services/camera_service.dart';
import 'services/crop_service.dart';
import 'services/image_processor.dart';
import 'services/ocr_service.dart';
import 'services/price_detector.dart';
import 'theme/app_theme.dart';

late List<CameraDescription> cameras;

/// Fonction "top-level" (hors classe) : requis par `compute()`. Réduit la
/// photo complète à une miniature (plus grande dimension ramenée à 300px)
/// et compressée — c'est tout ce dont l'historique a besoin, puisqu'elle
/// n'est jamais affichée qu'en petit. Remplace le stockage de la photo en
/// pleine résolution caméra, gardée indéfiniment pour rien.
Uint8List _makeThumbnail(img.Image source) {
  final resized = img.copyResize(
    source,
    width: source.width >= source.height ? 300 : null,
    height: source.width >= source.height ? null : 300,
    interpolation: img.Interpolation.average,
  );
  return img.encodeJpg(resized, quality: 80);
}

/// Fonction "top-level" (hors classe) : requis par `compute()`, qui doit
/// pouvoir l'envoyer telle quelle à l'isolate d'arrière-plan. Qualité 85
/// plutôt que 100 : cette image ne sert qu'à l'OCR, jamais affichée.
Uint8List _encodeJpgAt85(img.Image image) {
  return img.encodeJpg(image, quality: 85);
}

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  cameras = await availableCameras();
  runApp(const BudgetscanApp());
}

class BudgetscanApp extends StatelessWidget {
  const BudgetscanApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      debugShowCheckedModeBanner: false,
      title: 'BudgetScan',
      theme: ThemeData.dark().copyWith(
        scaffoldBackgroundColor: AppColors.bgBottom,
        colorScheme: ThemeData.dark().colorScheme.copyWith(
          primary: AppColors.emerald,
          secondary: AppColors.cyan,
          error: AppColors.danger,
        ),
        textTheme: GoogleFonts.interTextTheme(ThemeData.dark().textTheme),
      ),
      home: LensScreen(),
    );
  }
}

class LensScreen extends StatefulWidget {
  @override
  _LensScreenState createState() => _LensScreenState();
}

class _LensScreenState extends State<LensScreen> with WidgetsBindingObserver {
  // --- Services du pipeline (chacun isolé et remplaçable indépendamment) ---
  final CameraService cameraService = CameraService();
  final CropService cropService = CropService();
  final ImageProcessor imageProcessor = ImageProcessor();
  final OcrService ocrService = OcrService();
  final PriceDetector priceDetector = PriceDetector();

  bool isCameraReady = false;
  bool isProcessing = false;
  bool flashOn = false;
  String detectedText = 'Pointe sur un prix et appuie sur le bouton';
  double total = 0.0;
  List<ScannedProduct> products = [];
  String? lastImagePath;

  // Journal de debug qui s'accumule sur toute la session (le plus récent
  // en premier), lisible directement sur le téléphone en magasin, sans
  // avoir besoin d'un copier-coller après chaque scan.
  final List<String> sessionDebugLog = [];

  // GlobalKey utilisé par le CropService pour retrouver la position exacte
  // du rectangle bleu à l'écran (RenderBox → rectangle englobant → crop).
  final GlobalKey _scanBoxKey = GlobalKey();

  // GlobalKey posée sur le panneau du bas, pour MESURER sa hauteur réelle
  // après chaque frame plutôt que de la deviner. Un calcul basé sur une
  // supposition (hauteur d'écran, hauteur max du panneau) peut se tromper
  // selon l'appareil ; mesurer la vraie taille rendue ne se trompe jamais.
  final GlobalKey _panelKey = GlobalKey();

  // Hauteur mesurée du panneau, mise à jour après chaque frame. Valeur de
  // départ prudente (360) tant que la première mesure n'a pas eu lieu.
  double _panelHeight = 360;

  // Rectangle agrandi (ancien : 300x180) pour laisser plus de marge autour
  // du prix et limiter les coupures de texte lors du crop.
  static const double scanBoxWidth = 420;

  /// En dessous de ce score, on ne fait plus confiance silencieusement :
  /// on demande une confirmation avant d'ajouter le prix au panier. Vu en
  /// conditions réelles (Lidl) : deux scans à score 35 et 65 ont ajouté un
  /// prix barré/faux par élimination, sans jamais prévenir l'utilisatrice.
  static const int _confidenceThreshold = 70;
  static const double scanBoxHeight = 240;

  /// Après chaque frame, remesure la hauteur réelle du panneau du bas et
  /// ajuste la position du rectangle en conséquence — au lieu de deviner,
  /// on constate. Ne redéclenche un rebuild que si la valeur a vraiment
  /// changé (évite toute boucle infinie).
  void _measurePanelHeight(Duration _) {
    final renderObject = _panelKey.currentContext?.findRenderObject();
    if (renderObject is! RenderBox || !renderObject.hasSize) return;
    final measured = renderObject.size.height;
    if ((measured - _panelHeight).abs() > 1 && mounted) {
      setState(() => _panelHeight = measured);
    }
  }

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    WakelockPlus.enable();
    _initCamera();
  }

  /// La caméra doit être libérée quand l'app passe en arrière-plan (sinon
  /// le capteur reste verrouillé par l'app même invisible), et
  /// ré-initialisée au retour — sans ça, l'écran caméra reste noir après
  /// être revenu d'une autre app (mail, etc.).
  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (cameraService.controller == null ||
        !cameraService.controller!.value.isInitialized) {
      return;
    }

    if (state == AppLifecycleState.inactive ||
        state == AppLifecycleState.paused) {
      cameraService.dispose();
      setState(() => isCameraReady = false);
    } else if (state == AppLifecycleState.resumed) {
      _initCamera();
    }
  }

  Future<void> _initCamera() async {
    final status = await Permission.camera.request();
    if (!status.isGranted) {
      setState(() => detectedText = 'Permission refusée');
      return;
    }
    await cameraService.initialize(cameras);
    if (!mounted) return;
    setState(() => isCameraReady = true);
  }

  Future<void> _toggleFlash() async {
    setState(() => flashOn = !flashOn);
    await cameraService.setFlash(flashOn);
  }

  /// Pipeline complet, conforme au schéma du cahier des charges :
  ///   Camera → Photo HD → Crop → Prétraitement → OCR → Analyse spatiale
  ///   → Score → Extraction du prix
  Future<void> _scanPrice() async {
    if (isProcessing) return;
    setState(() {
      isProcessing = true;
      detectedText = 'Scan en cours...';
    });

    try {
      // 1. Photo HD.
      final xfile = await cameraService.takePicture();
      final bytes = await File(xfile.path).readAsBytes();
      final fullImage = img.decodeImage(bytes);
      if (fullImage == null) {
        throw Exception('Image illisible après capture');
      }

      // 2. Crop précis du rectangle bleu (aucun offset magique).
      final cropped = cropService.crop(
        scanBoxKey: _scanBoxKey,
        fullImage: fullImage,
        expectedAspectRatio: scanBoxWidth / scanBoxHeight,
      );
      if (cropped == null) {
        throw Exception('Zone de scan introuvable (rectangle non posé)');
      }

      // 2bis. Miniature compressée pour l'historique — on n'a jamais
      // besoin de la photo en pleine résolution caméra une fois le crop
      // fait, seulement d'un aperçu visuel pour "s'y retrouver" plus
      // tard. On génère cette miniature maintenant (fullImage est encore
      // en mémoire), puis on supprime la photo d'origine du disque.
      final thumbnailPath = await _saveThumbnail(fullImage);
      unawaited(_deleteQuietly(xfile.path));

      // 3. Prétraitement : grayscale → autocontraste → sharpen → resize x2.
      final steps = await imageProcessor.process(cropped);

      // 4. Sauvegarde de l'image finale uniquement — c'est la seule dont
      // ML Kit a réellement besoin (il lit depuis un fichier, pas depuis
      // la mémoire). Les 4 autres étapes (original/crop/grayscale/sharpen)
      // ne sont jamais consultées en pratique et alourdissaient chaque
      // scan de 4 écritures JPG inutiles sur le fil principal — cause
      // probable des blocages "BudgetScan ne répond pas".
      final finalImagePath = await _saveFinalImage(steps.finalImage);

      // 5. OCR sur l'image finale prétraitée.
      final recognizedText = await ocrService.recognize(finalImagePath);

      // 6. Analyse spatiale des blocs + score + extraction du prix.
      final result = priceDetector.detect(
        recognizedText,
        Size(
          steps.finalImage.width.toDouble(),
          steps.finalImage.height.toDouble(),
        ),
      );

      // Le numéro de produit est calculé ici, avant le log, pour que le
      // journal affiche "Produit 3" au lieu de juste l'heure — plus
      // facile de faire le lien avec le panier. Reste `null` si aucun
      // prix n'a été trouvé (pas de produit ajouté dans ce cas).
      final productLabel =
          result.price != null ? 'Produit ${products.length + 1}' : null;
      _logDetection(result, productLabel: productLabel);

      if (result.price != null) {
        final score = result.winningScore ?? 0;
        if (score < _confidenceThreshold) {
          // Score bas : on ne fait plus confiance aveuglément. On montre
          // ce qui a été trouvé et on demande une confirmation en un tap
          // — ou une correction manuelle si le prix est faux — plutôt
          // que d'ajouter silencieusement un prix potentiellement erroné.
          await _confirmLowConfidencePrice(
            detectedPrice: result.price!,
            score: score,
            imagePath: thumbnailPath,
            productLabel: productLabel!,
          );
        } else {
          _addProduct(result.price!, thumbnailPath, productLabel!);
        }
      } else {
        HapticFeedback.lightImpact();
        // Zone trop sombre ET flash pas encore activé : c'est le cas où
        // un simple "réessaie" n'aide pas l'utilisateur à comprendre quoi
        // faire différemment — on suggère explicitement le flash.
        final isTooDark = steps.averageBrightness < 90 && !flashOn;
        setState(() {
          detectedText = isTooDark
              ? "💡 Zone sombre — essaie d'activer le flash"
              : 'Prix non détecté — réessaie';
        });
        if (isTooDark && mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(
              content: Text(
                "Lumière insuffisante pour bien lire le prix. "
                "Active le flash (icône en haut à gauche) et réessaie.",
              ),
              duration: Duration(seconds: 3),
            ),
          );
        }
      }
    } catch (e) {
      setState(() => detectedText = 'Erreur : $e');
    }
    setState(() => isProcessing = false);
  }

  /// Ajoute effectivement un prix au panier — utilisé aussi bien pour un
  /// scan à haute confiance (silencieux) que pour un prix confirmé ou
  /// corrigé à la main après une demande de confirmation.
  void _addProduct(double price, String imagePath, String productLabel) {
    HapticFeedback.mediumImpact();
    setState(() {
      total += price;
      lastImagePath = imagePath;
      products.add(
        ScannedProduct(
          label: productLabel,
          price: price,
          imagePath: imagePath,
        ),
      );
      detectedText = '✅ ${price.toStringAsFixed(2)} € ajouté !';
    });
  }

  /// Filet de sécurité pour les scans à faible confiance : montre le prix
  /// détecté et demande une confirmation en un tap, avec une option de
  /// correction manuelle si le prix est faux. Ne bloque jamais la caméra
  /// plus que nécessaire — l'utilisatrice choisit en 1-2 gestes.
  Future<void> _confirmLowConfidencePrice({
    required double detectedPrice,
    required int score,
    required String imagePath,
    required String productLabel,
  }) async {
    final controller = TextEditingController(
      text: detectedPrice.toStringAsFixed(2),
    );
    bool isEditing = false;

    final confirmedPrice = await showDialog<double>(
      context: context,
      barrierDismissible: false,
      builder: (context) => StatefulBuilder(
        builder: (context, setDialogState) => AlertDialog(
          backgroundColor: const Color(0xF20A0F1E),
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(20),
            side: const BorderSide(color: AppColors.glassBorder),
          ),
          title: Text(
            isEditing ? 'Corriger le prix' : 'Prix peu certain',
            style: AppText.display(size: 16),
          ),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              if (File(imagePath).existsSync())
                Padding(
                  padding: const EdgeInsets.only(bottom: 12),
                  child: ClipRRect(
                    borderRadius: BorderRadius.circular(10),
                    child: Image.file(
                      File(imagePath),
                      height: 90,
                      fit: BoxFit.cover,
                    ),
                  ),
                ),
              if (isEditing)
                TextField(
                  controller: controller,
                  autofocus: true,
                  keyboardType: const TextInputType.numberWithOptions(
                    decimal: true,
                  ),
                  style: AppText.display(size: 22),
                  decoration: InputDecoration(
                    suffixText: '€',
                    suffixStyle: AppText.body(color: AppColors.textSecondary),
                    enabledBorder: const UnderlineInputBorder(
                      borderSide: BorderSide(color: AppColors.glassBorder),
                    ),
                  ),
                )
              else ...[
                GradientText(
                  '${detectedPrice.toStringAsFixed(2)} €',
                  style: AppText.display(size: 30),
                ),
                const SizedBox(height: 6),
                Text(
                  'Confiance : $score/100',
                  style: AppText.body(color: AppColors.textMuted, size: 13),
                ),
              ],
            ],
          ),
          actions: isEditing
              ? [
                  TextButton(
                    onPressed: () => Navigator.pop(context),
                    child: Text(
                      'Annuler',
                      style: AppText.body(color: AppColors.textMuted),
                    ),
                  ),
                  TextButton(
                    onPressed: () {
                      final parsed = double.tryParse(
                        controller.text.replaceAll(',', '.'),
                      );
                      if (parsed != null) Navigator.pop(context, parsed);
                    },
                    child: Text(
                      'Valider',
                      style: AppText.body(color: AppColors.emerald),
                    ),
                  ),
                ]
              : [
                  TextButton(
                    onPressed: () => setDialogState(() => isEditing = true),
                    child: Text(
                      '✏️ Corriger',
                      style: AppText.body(color: AppColors.gold),
                    ),
                  ),
                  TextButton(
                    onPressed: () => Navigator.pop(context, detectedPrice),
                    child: Text(
                      '✓ Confirmer',
                      style: AppText.body(color: AppColors.emerald),
                    ),
                  ),
                ],
        ),
      ),
    );

    if (confirmedPrice != null) {
      _addProduct(confirmedPrice, imagePath, productLabel);
    } else {
      setState(() => detectedText = 'Scan annulé — réessaie');
    }
  }

  /// Écrit uniquement l'image finale prétraitée sur le disque — c'est le
  /// seul fichier dont ML Kit a besoin (il lit depuis un chemin, pas
  /// depuis la mémoire). Si tu as besoin d'inspecter les étapes
  /// intermédiaires (crop, grayscale, sharpen) pour du debug visuel plus
  /// tard, on pourra les réactiver ponctuellement plutôt qu'à chaque scan.
  /// Génère et sauvegarde une miniature compressée de la photo complète —
  /// tout ce dont l'historique a besoin, au lieu de garder la photo en
  /// pleine résolution caméra indéfiniment sur le disque.
  Future<String> _saveThumbnail(img.Image fullImage) async {
    final dir = await getTemporaryDirectory();
    final stamp = DateTime.now().millisecondsSinceEpoch;
    final path = '${dir.path}/thumb_$stamp.jpg';
    final bytes = await compute(_makeThumbnail, fullImage);
    await File(path).writeAsBytes(bytes);
    return path;
  }

  /// Supprime un fichier sans bloquer ni faire planter le scan si ça
  /// échoue (fichier déjà supprimé par le système, permissions...) — la
  /// miniature suffit désormais, la photo d'origine n'est plus utile.
  Future<void> _deleteQuietly(String path) async {
    try {
      final file = File(path);
      if (await file.exists()) await file.delete();
    } catch (_) {
      // Pas grave : le système nettoiera le dossier temporaire de toute
      // façon, on n'interrompt pas l'utilisateur pour ça.
    }
  }

  Future<String> _saveFinalImage(img.Image finalImage) async {
    final dir = await getTemporaryDirectory();
    final stamp = DateTime.now().millisecondsSinceEpoch;
    final path = '${dir.path}/scan_$stamp.jpg';
    // Qualité 85 plutôt que 100 (valeur par défaut) : cette image ne sert
    // qu'à l'OCR, jamais affichée à l'utilisateur — inutile de payer le
    // coût d'encodage d'une qualité photo pour de la simple lecture de
    // caractères. Encodage toujours déplacé sur un isolate séparé.
    final bytes = await compute(_encodeJpgAt85, finalImage);
    await File(path).writeAsBytes(bytes);
    return path;
  }

  /// Affiche dans la console le détail de la détection, ET ajoute un
  /// rapport horodaté au journal de session — consultable directement sur
  /// le téléphone via le bouton "Debug", sans avoir besoin de la console
  /// VSCode (utile en magasin). Le journal s'accumule scan après scan.
  ///
  /// [productLabel] : "Produit N" si un prix a été trouvé (fait le lien
  /// avec le panier), sinon `null` pour un scan raté.
  void _logDetection(PriceDetectionResult result, {String? productLabel}) {
    final buffer = StringBuffer();
    final now = TimeOfDay.now();
    final timestamp =
        '${now.hour.toString().padLeft(2, '0')}:${now.minute.toString().padLeft(2, '0')}';

    buffer.writeln(
      productLabel != null
          ? '=== $productLabel — $timestamp ==='
          : '=== Scan $timestamp (non détecté) ===',
    );
    buffer.writeln(
      '🔎 Éléments retenus : ${result.elementsInZone} '
      '(${result.elementsRejectedOutsideZone} rejetés hors zone)',
    );

    // Détail brut de ce que l'OCR a réellement lu (texte + position),
    // indispensable pour comprendre POURQUOI un prix visible à l'écran
    // n'a pas été reconstruit — sans ça on ne peut que deviner.
    if (result.retainedElements.isNotEmpty) {
      buffer.writeln('--- Éléments OCR bruts ---');
      for (final element in result.retainedElements) {
        buffer.writeln('  $element');
      }
    }

    if (result.candidates.isEmpty) {
      buffer.writeln('Aucun candidat de prix trouvé.');
    }

    for (var i = 0; i < result.candidates.length; i++) {
      buffer.writeln('Candidat ${i + 1} | ${result.candidates[i]}');
    }

    final report = buffer.toString();
    // ignore: avoid_print
    print(report);

    // Le plus récent en tête de liste : pas besoin de scroller en magasin.
    setState(() => sessionDebugLog.insert(0, report));
  }

  void _removeProduct(int index) {
    setState(() {
      total -= products[index].price;
      if (products[index].imagePath == lastImagePath) lastImagePath = null;
      products.removeAt(index);
      if (products.isNotEmpty) lastImagePath = products.last.imagePath;
    });
  }

  void _resetAll() {
    setState(() {
      total = 0.0;
      products.clear();
      lastImagePath = null;
      detectedText = 'Pointe sur un prix et appuie sur le bouton';
    });
  }

  void _showHistory() {
    showModalBottomSheet(
      context: context,
      backgroundColor: Colors.transparent,
      // isScrollControlled : autorise le panneau à dépasser la moitié
      // d'écran par défaut — nécessaire pour DraggableScrollableSheet.
      isScrollControlled: true,
      builder: (context) => DraggableScrollableSheet(
        // Quasi plein écran d'entrée, redimensionnable entre 0.5 et 0.95
        // en faisant glisser la poignée du haut.
        initialChildSize: 0.92,
        minChildSize: 0.5,
        maxChildSize: 0.95,
        expand: false,
        builder: (context, scrollController) => ClipRRect(
          borderRadius: const BorderRadius.vertical(top: Radius.circular(28)),
          child: BackdropFilter(
            filter: ImageFilter.blur(sigmaX: 24, sigmaY: 24),
            child: Container(
              decoration: BoxDecoration(
                color: const Color(0xF20A0F1E),
                borderRadius: const BorderRadius.vertical(
                  top: Radius.circular(28),
                ),
                border: const Border(
                  top: BorderSide(color: AppColors.glassBorder),
                ),
              ),
              child: Column(
                children: [
                  Container(
                    margin: const EdgeInsets.only(top: 10),
                    width: 40,
                    height: 4,
                    decoration: BoxDecoration(
                      gradient: AppColors.primaryGradient,
                      borderRadius: BorderRadius.circular(4),
                    ),
                  ),
                  Padding(
                    padding: const EdgeInsets.all(16),
                    child: GradientText(
                      'Historique (${products.length} scan'
                      '${products.length > 1 ? 's' : ''})',
                      style: AppText.display(size: 17),
                    ),
                  ),
                  Expanded(
                    child: products.isEmpty
                        ? Center(
                            child: Text(
                              'Aucun scan cette session',
                              style:
                                  AppText.body(color: AppColors.textMuted),
                            ),
                          )
                        // Grille plutôt que liste : 3 colonnes, bien plus
                        // dense — on voit d'un coup d'œil beaucoup plus de
                        // produits qu'avec une ligne par produit. Le
                        // scrollController vient du DraggableScrollableSheet
                        // : plus de conflit avec le geste de fermeture.
                        : GridView.builder(
                            controller: scrollController,
                            padding: const EdgeInsets.all(12),
                            gridDelegate:
                                const SliverGridDelegateWithFixedCrossAxisCount(
                              crossAxisCount: 3,
                              crossAxisSpacing: 10,
                              mainAxisSpacing: 10,
                              childAspectRatio: 0.68,
                            ),
                            itemCount: products.length,
                            itemBuilder: (context, index) {
                              final p = products[index];
                              return Container(
                                padding: const EdgeInsets.all(8),
                                decoration: glassDecoration(radius: 14),
                                child: Column(
                                  crossAxisAlignment:
                                      CrossAxisAlignment.center,
                                  children: [
                                    Expanded(
                                      child: ClipRRect(
                                        borderRadius:
                                            BorderRadius.circular(10),
                                        child: File(p.imagePath).existsSync()
                                            ? Image.file(
                                                File(p.imagePath),
                                                width: double.infinity,
                                                fit: BoxFit.cover,
                                              )
                                            : const Icon(
                                                Icons.image_outlined,
                                                color: AppColors.textMuted,
                                              ),
                                      ),
                                    ),
                                    const SizedBox(height: 4),
                                    Text(
                                      p.label,
                                      style: AppText.body(
                                        size: 11,
                                        color: AppColors.textMuted,
                                      ),
                                      maxLines: 1,
                                      overflow: TextOverflow.ellipsis,
                                    ),
                                    const SizedBox(height: 2),
                                    GradientText(
                                      '${p.price.toStringAsFixed(2)} €',
                                      style: AppText.mono(
                                        size: 14,
                                        weight: FontWeight.w700,
                                      ),
                                    ),
                                  ],
                                ),
                              );
                            },
                          ),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }

  void _showMenu(BuildContext context) {
    Widget menuTile(
      IconData icon,
      Color iconColor,
      String label,
      VoidCallback onTap,
    ) {
      return ListTile(
        leading: Icon(icon, color: iconColor, size: 20),
        title: Text(label, style: AppText.body(color: AppColors.textPrimary)),
        onTap: onTap,
      );
    }

    showModalBottomSheet(
      context: context,
      backgroundColor: Colors.transparent,
      builder: (context) => ClipRRect(
        borderRadius: const BorderRadius.vertical(top: Radius.circular(28)),
        child: BackdropFilter(
          filter: ImageFilter.blur(sigmaX: 24, sigmaY: 24),
          child: Container(
            decoration: BoxDecoration(
              color: const Color(0xF20A0F1E),
              borderRadius: const BorderRadius.vertical(
                top: Radius.circular(28),
              ),
              border: const Border(
                top: BorderSide(color: AppColors.glassBorder),
              ),
            ),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Container(
                  margin: const EdgeInsets.symmetric(vertical: 10),
                  width: 40,
                  height: 4,
                  decoration: BoxDecoration(
                    gradient: AppColors.primaryGradient,
                    borderRadius: BorderRadius.circular(4),
                  ),
                ),
                menuTile(
                  Icons.bug_report_outlined,
                  AppColors.gold,
                  'Debug session',
                  () {
                    Navigator.pop(context);
                    _showDebugReport();
                  },
                ),
                menuTile(
                  Icons.info_outline_rounded,
                  AppColors.cyan,
                  'À propos',
                  () {
                    Navigator.pop(context);
                    _showPage(
                      'À propos',
                      'BudgetScan est une application de scan de prix privacy-first. Aucune donnée collectée, aucun compte requis.',
                    );
                  },
                ),
                menuTile(
                  Icons.gavel_rounded,
                  AppColors.cyan,
                  "Conditions d'utilisation",
                  () {
                    Navigator.pop(context);
                    _showPage(
                      "Conditions d'utilisation",
                      'Lorem ipsum dolor sit amet, consectetur adipiscing elit.',
                    );
                  },
                ),
                menuTile(
                  Icons.mail_outline_rounded,
                  AppColors.cyan,
                  'Contact',
                  () {
                    Navigator.pop(context);
                    _showPage(
                      'Contact',
                      'Pour nous contacter : contact@weboara.fr',
                    );
                  },
                ),
                const SizedBox(height: 8),
              ],
            ),
          ),
        ),
      ),
    );
  }

  void _showDebugReport() {
    showDialog(
      context: context,
      builder: (context) => AlertDialog(
        backgroundColor: const Color(0xF20A0F1E),
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(20),
          side: const BorderSide(color: AppColors.glassBorder),
        ),
        title: Text(
          'Debug session (${sessionDebugLog.length} scan${sessionDebugLog.length > 1 ? 's' : ''})',
          style: AppText.display(size: 15),
        ),
        content: SizedBox(
          width: double.maxFinite,
          child: SingleChildScrollView(
            child: SelectableText(
              sessionDebugLog.isEmpty
                  ? 'Aucun scan effectué pour le moment.'
                  : sessionDebugLog.join('\n'),
              style: TextStyle(
                color: AppColors.emerald,
                fontSize: 12,
                fontFamily: GoogleFonts.spaceGrotesk().fontFamily,
              ),
            ),
          ),
        ),
        actions: [
          TextButton(
            onPressed: sessionDebugLog.isEmpty
                ? null
                : () {
                    setState(() => sessionDebugLog.clear());
                    Navigator.pop(context);
                  },
            child: Text(
              'Effacer',
              style: AppText.body(color: AppColors.danger),
            ),
          ),
          TextButton(
            onPressed: sessionDebugLog.isEmpty
                ? null
                : () {
                    Clipboard.setData(
                      ClipboardData(text: sessionDebugLog.join('\n')),
                    );
                    ScaffoldMessenger.of(context).showSnackBar(
                      const SnackBar(content: Text('Journal complet copié')),
                    );
                  },
            child: Text(
              'Copier tout',
              style: AppText.body(color: AppColors.gold),
            ),
          ),
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: Text('Fermer', style: AppText.body(color: AppColors.cyan)),
          ),
        ],
      ),
    );
  }

  void _showPage(String title, String content) {
    showDialog(
      context: context,
      builder: (context) => AlertDialog(
        backgroundColor: const Color(0xF20A0F1E),
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(20),
          side: const BorderSide(color: AppColors.glassBorder),
        ),
        title: Text(title, style: AppText.display(size: 16)),
        content: Text(
          content,
          style: AppText.body(color: AppColors.textSecondary),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: Text('Fermer', style: AppText.body(color: AppColors.cyan)),
          ),
        ],
      ),
    );
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    WakelockPlus.disable();
    cameraService.dispose();
    ocrService.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    // Remesure la hauteur réelle du panneau après CE frame (dès qu'il est
    // posé à l'écran) — capture les changements dus à l'ajout/suppression
    // de produits, à l'apparition du bandeau "prix ajouté", etc.
    WidgetsBinding.instance.addPostFrameCallback(_measurePanelHeight);

    if (!isCameraReady || cameraService.controller == null) {
      return Scaffold(
        backgroundColor: AppColors.bgBottom,
        body: Container(
          decoration: const BoxDecoration(gradient: AppColors.bgGradient),
          child: Center(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                const CircularProgressIndicator(color: AppColors.emerald),
                const SizedBox(height: 16),
                Text(
                  'Initialisation de la caméra…',
                  style: AppText.body(color: AppColors.textSecondary),
                ),
              ],
            ),
          ),
        ),
      );
    }

    return Scaffold(
      body: Stack(
        children: [
          CameraPreview(cameraService.controller!),
          // Voile graphite dégradé (haut plus sombre, bas plus sombre encore)
          // pour un rendu "fintech premium" plutôt qu'un simple assombrissement.
          Container(
            decoration: const BoxDecoration(
              gradient: LinearGradient(
                begin: Alignment.topCenter,
                end: Alignment.bottomCenter,
                colors: [
                  Color(0x99050810),
                  Color(0x33050810),
                  Color(0xB3050810),
                ],
                stops: [0.0, 0.45, 1.0],
              ),
            ),
          ),

          // Header — bandeau verre dépoli, logo en dégradé émeraude/cyan.
          Positioned(
            top: 0,
            left: 0,
            right: 0,
            child: SafeArea(
              child: Padding(
                padding: const EdgeInsets.fromLTRB(16, 10, 16, 0),
                child: ClipRRect(
                  borderRadius: BorderRadius.circular(20),
                  child: BackdropFilter(
                    filter: ImageFilter.blur(sigmaX: 16, sigmaY: 16),
                    child: Container(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 10,
                        vertical: 8,
                      ),
                      decoration: glassDecoration(radius: 20),
                      child: Row(
                        mainAxisAlignment: MainAxisAlignment.spaceBetween,
                        children: [
                          _GlassIconButton(
                            icon: flashOn ? Icons.flash_on : Icons.flash_off,
                            iconColor: flashOn
                                ? AppColors.gold
                                : AppColors.textPrimary,
                            onTap: _toggleFlash,
                          ),
                          Row(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              GradientText(
                                'BudgetScan',
                                style: AppText.display(size: 19),
                              ),
                            ],
                          ),
                          _GlassIconButton(
                            icon: Icons.more_vert,
                            onTap: () => _showMenu(context),
                          ),
                        ],
                      ),
                    ),
                  ),
                ),
              ),
            ),
          ),

          // Zone de scan — coins néon façon scanner high-tech
          // (seule la zone à l'intérieur est analysée).
          // Position calculée à partir de _panelHeight — la hauteur RÉELLE
          // mesurée du panneau du bas (cf. _measurePanelHeight), pas une
          // supposition. Garantit qu'il ne peut plus jamais être recouvert,
          // quel que soit l'appareil ou le nombre de produits affichés.
          Positioned(
            top: (MediaQuery.of(context).size.height -
                    _panelHeight -
                    scanBoxHeight -
                    24)
                .clamp(110.0, double.infinity),
            left: 0,
            right: 0,
            child: Center(
              child: SizedBox(
                key: _scanBoxKey,
                width: scanBoxWidth,
                height: scanBoxHeight,
                child: CustomPaint(painter: _ScanCornersPainter()),
              ),
            ),
          ),

          // Panneau bas — verre dépoli premium avec liseré dégradé en tête.
          Positioned(
            bottom: 0,
            left: 0,
            right: 0,
            child: ClipRRect(
              borderRadius: const BorderRadius.vertical(
                top: Radius.circular(28),
              ),
              child: BackdropFilter(
                filter: ImageFilter.blur(sigmaX: 24, sigmaY: 24),
                child: Container(
                  key: _panelKey,
                  constraints: const BoxConstraints(maxHeight: 360),
                  decoration: BoxDecoration(
                    color: const Color(0xE60A0F1E),
                    borderRadius: const BorderRadius.vertical(
                      top: Radius.circular(28),
                    ),
                    border: const Border(
                      top: BorderSide(color: AppColors.glassBorder, width: 1),
                    ),
                  ),
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      // Liseré dégradé décoratif (poignée du panneau).
                      Container(
                        margin: const EdgeInsets.only(top: 10),
                        width: 40,
                        height: 4,
                        decoration: BoxDecoration(
                          gradient: AppColors.primaryGradient,
                          borderRadius: BorderRadius.circular(4),
                        ),
                      ),
                      Padding(
                        padding: const EdgeInsets.fromLTRB(16, 12, 16, 4),
                        child: Text(
                          detectedText,
                          style: AppText.body(
                            size: 12.5,
                            color: AppColors.textSecondary,
                          ),
                          textAlign: TextAlign.center,
                          maxLines: 3,
                          overflow: TextOverflow.ellipsis,
                        ),
                      ),
                      if (products.isNotEmpty)
                        SizedBox(
                          // Hauteur proportionnelle au nombre réel de
                          // produits (jusqu'à 104 max, ~2 lignes visibles
                          // avant de devoir scroller) — plus de bande
                          // vide réservée pour rien quand il n'y a qu'un
                          // ou deux produits dans le panier.
                          height: (products.length * 56.0).clamp(0.0, 104.0),
                          child: ListView.builder(
                            itemCount: products.length,
                            itemBuilder: (context, index) {
                              final p = products[index];
                              return Container(
                                margin: const EdgeInsets.symmetric(
                                  horizontal: 16,
                                  vertical: 3,
                                ),
                                padding: const EdgeInsets.symmetric(
                                  horizontal: 12,
                                  vertical: 2,
                                ),
                                decoration: glassDecoration(radius: 12),
                                child: ListTile(
                                  dense: true,
                                  contentPadding: EdgeInsets.zero,
                                  title: Text(
                                    p.label,
                                    style: AppText.body(
                                      size: 13,
                                      color: AppColors.textPrimary,
                                    ),
                                  ),
                                  trailing: Row(
                                    mainAxisSize: MainAxisSize.min,
                                    children: [
                                      GradientText(
                                        '${p.price.toStringAsFixed(2)} €',
                                        style: AppText.mono(
                                          size: 14,
                                          weight: FontWeight.w700,
                                        ),
                                      ),
                                      IconButton(
                                        icon: const Icon(
                                          Icons.close_rounded,
                                          color: AppColors.danger,
                                          size: 16,
                                        ),
                                        onPressed: () => _removeProduct(index),
                                      ),
                                    ],
                                  ),
                                ),
                              );
                            },
                          ),
                        ),
                      Container(
                        margin: const EdgeInsets.fromLTRB(16, 8, 16, 6),
                        padding: const EdgeInsets.symmetric(
                          horizontal: 20,
                          vertical: 14,
                        ),
                        decoration: BoxDecoration(
                          gradient: LinearGradient(
                            begin: Alignment.topLeft,
                            end: Alignment.bottomRight,
                            colors: [
                              AppColors.emerald.withOpacity(0.16),
                              AppColors.cyan.withOpacity(0.10),
                            ],
                          ),
                          borderRadius: BorderRadius.circular(20),
                          border: Border.all(
                            color: AppColors.emerald.withOpacity(0.4),
                          ),
                        ),
                        child: Row(
                          mainAxisAlignment: MainAxisAlignment.spaceBetween,
                          children: [
                            Text('TOTAL', style: AppText.label(size: 12)),
                            GradientText(
                              '${total.toStringAsFixed(2)} €',
                              style: AppText.display(size: 24),
                            ),
                          ],
                        ),
                      ),
                      Padding(
                        padding: const EdgeInsets.only(bottom: 20, top: 6),
                        child: Row(
                          mainAxisAlignment: MainAxisAlignment.center,
                          children: [
                            GestureDetector(
                              onTap: _showHistory,
                              child: Container(
                                width: 48,
                                height: 48,
                                margin: const EdgeInsets.only(right: 26),
                                decoration: glassDecoration(radius: 24),
                                child:
                                    lastImagePath != null &&
                                        File(lastImagePath!).existsSync()
                                    ? ClipOval(
                                        child: Image.file(
                                          File(lastImagePath!),
                                          fit: BoxFit.cover,
                                        ),
                                      )
                                    : const Icon(
                                        Icons.history_rounded,
                                        color: AppColors.textPrimary,
                                        size: 21,
                                      ),
                              ),
                            ),
                            GestureDetector(
                              onTap: _scanPrice,
                              child: Container(
                                width: 76,
                                height: 76,
                                decoration: BoxDecoration(
                                  shape: BoxShape.circle,
                                  gradient: isProcessing
                                      ? null
                                      : AppColors.primaryGradient,
                                  color: isProcessing
                                      ? AppColors.textMuted
                                      : null,
                                  boxShadow: isProcessing
                                      ? []
                                      : [
                                          BoxShadow(
                                            color: AppColors.emerald
                                                .withOpacity(0.45),
                                            blurRadius: 22,
                                            spreadRadius: 1,
                                          ),
                                        ],
                                ),
                                child: isProcessing
                                    ? const Padding(
                                        padding: EdgeInsets.all(16),
                                        child: CircularProgressIndicator(
                                          color: Colors.white,
                                          strokeWidth: 2.4,
                                        ),
                                      )
                                    : const Icon(
                                        Icons.camera_alt_rounded,
                                        color: Color(0xFF04101B),
                                        size: 32,
                                      ),
                              ),
                            ),
                            if (products.isNotEmpty)
                              GestureDetector(
                                onTap: _resetAll,
                                child: Container(
                                  width: 48,
                                  height: 48,
                                  margin: const EdgeInsets.only(left: 26),
                                  decoration: glassDecoration(
                                    radius: 24,
                                    borderColor: AppColors.danger.withOpacity(
                                      0.5,
                                    ),
                                  ),
                                  child: const Icon(
                                    Icons.refresh_rounded,
                                    color: AppColors.danger,
                                    size: 20,
                                  ),
                                ),
                              ),
                          ],
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

/// Bouton circulaire en verre dépoli utilisé dans le header.
class _GlassIconButton extends StatelessWidget {
  final IconData icon;
  final Color iconColor;
  final VoidCallback onTap;

  const _GlassIconButton({
    required this.icon,
    required this.onTap,
    this.iconColor = AppColors.textPrimary,
  });

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: onTap,
      child: Container(
        width: 38,
        height: 38,
        decoration: glassDecoration(radius: 19),
        child: Icon(icon, color: iconColor, size: 19),
      ),
    );
  }
}

/// Dessine les 4 coins néon (dégradé émeraude → cyan) de la zone de scan,
/// pour un rendu "scanner" haut de gamme plutôt qu'un simple cadre plein.
class _ScanCornersPainter extends CustomPainter {
  static const double _cornerLength = 28;
  static const double _strokeWidth = 3.5;
  static const double _radius = 16;

  @override
  void paint(Canvas canvas, Size size) {
    final rect = Offset.zero & size;

    // Contour discret sur toute la zone (transparence).
    final basePaint = Paint()
      ..color = AppColors.glassStroke
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1.2;
    canvas.drawRRect(
      RRect.fromRectAndRadius(rect, const Radius.circular(_radius)),
      basePaint,
    );

    final gradientPaint = Paint()
      ..shader = AppColors.primaryGradient.createShader(rect)
      ..style = PaintingStyle.stroke
      ..strokeWidth = _strokeWidth
      ..strokeCap = StrokeCap.round;

    void corner(Offset start, Offset mid, Offset end) {
      final path = Path()
        ..moveTo(start.dx, start.dy)
        ..lineTo(mid.dx, mid.dy)
        ..lineTo(end.dx, end.dy);
      canvas.drawPath(path, gradientPaint);
    }

    // Haut-gauche.
    corner(
      Offset(0, _cornerLength + _radius),
      Offset(0, _radius),
      Offset(_radius, 0),
    );
    corner(Offset(_radius, 0), Offset(_radius, 0), Offset(_cornerLength, 0));
    // Haut-droite.
    corner(
      Offset(size.width - _cornerLength, 0),
      Offset(size.width - _radius, 0),
      Offset(size.width, _radius),
    );
    canvas.drawLine(
      Offset(size.width, _radius),
      Offset(size.width, _cornerLength + _radius),
      gradientPaint,
    );
    // Bas-gauche.
    canvas.drawLine(
      Offset(0, size.height - _cornerLength - _radius),
      Offset(0, size.height - _radius),
      gradientPaint,
    );
    corner(
      Offset(0, size.height - _radius),
      Offset(0, size.height),
      Offset(_cornerLength, size.height),
    );
    // Bas-droite.
    canvas.drawLine(
      Offset(size.width, size.height - _cornerLength - _radius),
      Offset(size.width, size.height - _radius),
      gradientPaint,
    );
    corner(
      Offset(size.width - _cornerLength, size.height),
      Offset(size.width, size.height),
      Offset(size.width, size.height - _radius),
    );
  }

  @override
  bool shouldRepaint(covariant CustomPainter oldDelegate) => false;
}
