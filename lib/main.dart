import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:camera/camera.dart';
import 'package:google_mlkit_text_recognition/google_mlkit_text_recognition.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:wakelock_plus/wakelock_plus.dart';
import 'dart:io';
import 'package:image/image.dart' as img;

late List<CameraDescription> cameras;

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  cameras = await availableCameras();
  runApp(BudgetscanApp());
}

class BudgetscanApp extends StatelessWidget {
  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      debugShowCheckedModeBanner: false,
      title: 'BudgetScan',
      theme: ThemeData.dark(),
      home: LensScreen(),
    );
  }
}

class ScannedProduct {
  final String label;
  final double price;
  final String imagePath;
  ScannedProduct({
    required this.label,
    required this.price,
    required this.imagePath,
  });
}

class LensScreen extends StatefulWidget {
  @override
  _LensScreenState createState() => _LensScreenState();
}

class _LensScreenState extends State<LensScreen> {
  CameraController? controller;
  bool isCameraReady = false;
  bool isProcessing = false;
  bool flashOn = false;
  String detectedText = 'Pointe sur un prix et appuie sur le bouton';
  double total = 0.0;
  List<ScannedProduct> products = [];
  String? lastImagePath;

  // ✅ GlobalKey pour position exacte du rectangle bleu
  final GlobalKey _scanBoxKey = GlobalKey();

  static const double scanBoxWidth = 300;
  static const double scanBoxHeight = 180;

  final TextRecognizer textRecognizer = TextRecognizer(
    script: TextRecognitionScript.latin,
  );

  @override
  void initState() {
    super.initState();
    WakelockPlus.enable();
    _initCamera();
  }

  Future<void> _initCamera() async {
    final status = await Permission.camera.request();
    if (!status.isGranted) {
      setState(() => detectedText = "Permission refusée");
      return;
    }
    controller = CameraController(
      cameras[0],
      ResolutionPreset.medium,
      enableAudio: false,
    );
    await controller!.initialize();
    if (!mounted) return;
    setState(() => isCameraReady = true);
  }

  Future<void> _toggleFlash() async {
    if (controller == null) return;
    setState(() => flashOn = !flashOn);
    await controller!.setFlashMode(flashOn ? FlashMode.torch : FlashMode.off);
  }

  // ✅ Crop universel via GlobalKey
  img.Image? _cropScanBox(img.Image fullImage) {
    try {
      final RenderBox box =
          _scanBoxKey.currentContext!.findRenderObject() as RenderBox;
      final Offset topLeft = box.localToGlobal(Offset.zero);
      final Size boxSize = box.size;
      final screenSize = MediaQuery.of(_scanBoxKey.currentContext!).size;

      final scaleX = fullImage.width / screenSize.width;
      final scaleY = fullImage.height / screenSize.height;

      final x1 = (topLeft.dx * scaleX).toInt().clamp(0, fullImage.width);
      final y1 = ((topLeft.dy + 80) * scaleY).toInt().clamp(
        0,
        fullImage.height,
      );
      final x2 = ((topLeft.dx + boxSize.width) * scaleX).toInt().clamp(
        0,
        fullImage.width,
      );
      final y2 = ((topLeft.dy + boxSize.height + 80) * scaleY).toInt().clamp(
        0,
        fullImage.height,
      );

      print(
        '✂️ Crop: ($x1,$y1) → ($x2,$y2) sur ${fullImage.width}x${fullImage.height}',
      );

      return img.copyCrop(
        fullImage,
        x: x1,
        y: y1,
        width: (x2 - x1).clamp(32, fullImage.width),
        height: (y2 - y1).clamp(32, fullImage.height),
      );
    } catch (e) {
      print('❌ Erreur crop: $e');
      return null;
    }
  }

  // ✅ Tri spatial des blocs — euros à gauche, centimes à droite
  double? _extractPriceFromBlocks(RecognizedText recognizedText) {
    // Trie les blocs par position horizontale (gauche → droite)
    List<TextBlock> blocks = recognizedText.blocks
        .where((b) => b.boundingBox != null)
        .toList();

    blocks.sort((a, b) => a.boundingBox!.left.compareTo(b.boundingBox!.left));

    // Cherche le prix dans chaque bloc du plus grand au plus petit
    List<MapEntry<TextBlock, double>> blocksWithSize = blocks
        .map((b) => MapEntry(b, b.boundingBox!.width * b.boundingBox!.height))
        .toList();
    blocksWithSize.sort((a, b) => b.value.compareTo(a.value));

    for (final entry in blocksWithSize) {
      final price = _extractPrice(entry.key.text);
      if (price != null) {
        print('💰 Prix: ${entry.key.text} → $price');
        return price;
      }
    }

    // Fallback — texte complet
    return _extractPrice(recognizedText.text);
  }

  double? _extractPrice(String text) {
    String normalized = text
        .replaceAll('⁰', '0')
        .replaceAll('¹', '1')
        .replaceAll('²', '2')
        .replaceAll('³', '3')
        .replaceAll('⁴', '4')
        .replaceAll('⁵', '5')
        .replaceAll('⁶', '6')
        .replaceAll('⁷', '7')
        .replaceAll('⁸', '8')
        .replaceAll('⁹', '9')
        .replaceAll('EUR', '')
        .replaceAll('euro', '')
        .replaceAll('€/u', '')
        .replaceAll('€/l', '')
        .replaceAll('€/kg', '');

    final patterns = [
      // Format standard : 1.25, 1,25
      RegExp(r'\b(\d{1,4})[.,](\d{2})\s*€?\b'),
      // Format 1 décimale : 59.5
      RegExp(r'\b(\d{1,4})[.,](\d{1})\s*€?\b'),
      // Format € entre : 1€45
      RegExp(r'\b(\d{1,4})\s*[€e]\s*(\d{2})\b'),
      // Format avec saut de ligne : "1\n45"
      RegExp(r'(\d{1,2})\n(\d{2})\s*€?'),
      // Format exposant séparé : "0 75"
      RegExp(r'\b(\d)\s+(\d{2})\s*€?\b'),
      // Format sans séparateur : 125 → 1.25
      RegExp(r'\b([1-9])(\d{2})\b'),
      // Prix entier
      RegExp(r'\b(\d{1,3})\b'),
    ];

    List<double> prices = [];
    for (final regex in patterns) {
      for (final match in regex.allMatches(normalized)) {
        String euros = match.group(1)!;
        String cents = match.groupCount >= 2 && match.group(2) != null
            ? match.group(2)!
            : '0';
        double? price = double.tryParse('$euros.$cents');
        if (price != null && price > 0 && price < 1000) {
          prices.add(price);
        }
      }
      if (prices.isNotEmpty) break;
    }

    if (prices.isEmpty) return null;
    // Prend le plus petit — en cas de promo c'est le bon
    return prices.reduce((a, b) => a < b ? a : b);
  }

  Future<void> _scanPrice() async {
    if (controller == null || isProcessing) return;
    setState(() {
      isProcessing = true;
      detectedText = 'Scan en cours...';
    });

    try {
      final imageFile = await controller!.takePicture();
      final imageBytes = await File(imageFile.path).readAsBytes();
      final fullImage = img.decodeImage(imageBytes)!;

      // ✅ Crop du rectangle bleu via GlobalKey
      final boxCrop = _cropScanBox(fullImage);
      String scanPath = imageFile.path;

      if (boxCrop != null) {
        final boxCropPath = imageFile.path.replaceAll('.jpg', '_box.jpg');
        await File(boxCropPath).writeAsBytes(img.encodeJpg(boxCrop));
        scanPath = boxCropPath;
      }

      // ✅ OCR sur la zone cropée
      final inputImage = InputImage.fromFilePath(scanPath);
      final RecognizedText recognizedText = await textRecognizer.processImage(
        inputImage,
      );

      print('📝 OCR: ${recognizedText.text}');

      // ✅ Extraction avec tri spatial
      double? price = _extractPriceFromBlocks(recognizedText);

      if (price != null) {
        HapticFeedback.mediumImpact();
        setState(() {
          total += price;
          lastImagePath = imageFile.path;
          products.add(
            ScannedProduct(
              label: 'Produit ${products.length + 1}',
              price: price,
              imagePath: imageFile.path,
            ),
          );
          detectedText = '✅ ${price.toStringAsFixed(2)} € ajouté !';
        });
      } else {
        HapticFeedback.lightImpact();
        setState(() => detectedText = 'Prix non détecté — réessaie');
      }
    } catch (e) {
      setState(() => detectedText = 'Erreur : $e');
    }
    setState(() => isProcessing = false);
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
      backgroundColor: Colors.grey[900],
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
      ),
      builder: (context) => Column(
        children: [
          Padding(
            padding: EdgeInsets.all(16),
            child: Text(
              'Historique de la session',
              style: TextStyle(
                color: Colors.white,
                fontSize: 16,
                fontWeight: FontWeight.bold,
              ),
            ),
          ),
          Expanded(
            child: products.isEmpty
                ? Center(
                    child: Text(
                      'Aucun scan cette session',
                      style: TextStyle(color: Colors.grey),
                    ),
                  )
                : ListView.builder(
                    itemCount: products.length,
                    itemBuilder: (context, index) {
                      final p = products[index];
                      return ListTile(
                        leading: File(p.imagePath).existsSync()
                            ? ClipRRect(
                                borderRadius: BorderRadius.circular(8),
                                child: Image.file(
                                  File(p.imagePath),
                                  width: 50,
                                  height: 50,
                                  fit: BoxFit.cover,
                                ),
                              )
                            : Icon(Icons.image, color: Colors.grey),
                        title: Text(
                          p.label,
                          style: TextStyle(color: Colors.white),
                        ),
                        trailing: Text(
                          '${p.price.toStringAsFixed(2)} €',
                          style: TextStyle(
                            color: Colors.blue,
                            fontWeight: FontWeight.bold,
                          ),
                        ),
                      );
                    },
                  ),
          ),
        ],
      ),
    );
  }

  void _showMenu(BuildContext context) {
    showModalBottomSheet(
      context: context,
      backgroundColor: Colors.grey[900],
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
      ),
      builder: (context) => Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          ListTile(
            leading: Icon(Icons.info_outline, color: Colors.blue),
            title: Text('À propos', style: TextStyle(color: Colors.white)),
            onTap: () {
              Navigator.pop(context);
              _showPage(
                'À propos',
                'BudgetScan est une application de scan de prix privacy-first. Aucune donnée collectée, aucun compte requis.',
              );
            },
          ),
          ListTile(
            leading: Icon(Icons.gavel, color: Colors.blue),
            title: Text(
              "Conditions d'utilisation",
              style: TextStyle(color: Colors.white),
            ),
            onTap: () {
              Navigator.pop(context);
              _showPage(
                "Conditions d'utilisation",
                'Lorem ipsum dolor sit amet, consectetur adipiscing elit.',
              );
            },
          ),
          ListTile(
            leading: Icon(Icons.mail_outline, color: Colors.blue),
            title: Text('Contact', style: TextStyle(color: Colors.white)),
            onTap: () {
              Navigator.pop(context);
              _showPage('Contact', 'Pour nous contacter : contact@weboara.fr');
            },
          ),
        ],
      ),
    );
  }

  void _showPage(String title, String content) {
    showDialog(
      context: context,
      builder: (context) => AlertDialog(
        backgroundColor: Colors.grey[900],
        title: Text(title, style: TextStyle(color: Colors.white)),
        content: Text(content, style: TextStyle(color: Colors.grey[300])),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: Text('Fermer', style: TextStyle(color: Colors.blue)),
          ),
        ],
      ),
    );
  }

  @override
  void dispose() {
    WakelockPlus.disable();
    controller?.dispose();
    textRecognizer.close();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    if (!isCameraReady) {
      return Scaffold(
        backgroundColor: Colors.black,
        body: Center(child: CircularProgressIndicator()),
      );
    }

    return Scaffold(
      body: Stack(
        children: [
          CameraPreview(controller!),
          Container(color: Colors.black.withOpacity(0.3)),

          // 🔝 Header
          Positioned(
            top: 0,
            left: 0,
            right: 0,
            child: SafeArea(
              child: Padding(
                padding: EdgeInsets.symmetric(horizontal: 16, vertical: 8),
                child: Row(
                  mainAxisAlignment: MainAxisAlignment.spaceBetween,
                  children: [
                    GestureDetector(
                      onTap: _toggleFlash,
                      child: Container(
                        width: 40,
                        height: 40,
                        decoration: BoxDecoration(
                          color: Colors.black.withOpacity(0.5),
                          shape: BoxShape.circle,
                        ),
                        child: Icon(
                          flashOn ? Icons.flash_on : Icons.flash_off,
                          color: flashOn ? Colors.yellow : Colors.white,
                          size: 20,
                        ),
                      ),
                    ),
                    Text(
                      'BudgetScan',
                      style: TextStyle(
                        color: Colors.white,
                        fontSize: 18,
                        fontWeight: FontWeight.bold,
                      ),
                    ),
                    GestureDetector(
                      onTap: () => _showMenu(context),
                      child: Container(
                        width: 40,
                        height: 40,
                        decoration: BoxDecoration(
                          color: Colors.black.withOpacity(0.5),
                          shape: BoxShape.circle,
                        ),
                        child: Icon(
                          Icons.more_vert,
                          color: Colors.white,
                          size: 20,
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),

          // ✅ Rectangle bleu avec GlobalKey
          Center(
            child: Container(
              key: _scanBoxKey,
              width: scanBoxWidth,
              height: scanBoxHeight,
              decoration: BoxDecoration(
                border: Border.all(color: Colors.blue, width: 2),
                borderRadius: BorderRadius.circular(12),
              ),
            ),
          ),

          // 📋 Panel bas
          Positioned(
            bottom: 0,
            left: 0,
            right: 0,
            child: Container(
              constraints: BoxConstraints(maxHeight: 350),
              decoration: BoxDecoration(
                color: Colors.black.withOpacity(0.85),
                borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
              ),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Padding(
                    padding: EdgeInsets.fromLTRB(12, 12, 12, 4),
                    child: Text(
                      detectedText,
                      style: TextStyle(color: Colors.white, fontSize: 12),
                      textAlign: TextAlign.center,
                      maxLines: 3,
                      overflow: TextOverflow.ellipsis,
                    ),
                  ),
                  if (products.isNotEmpty)
                    SizedBox(
                      height: 100,
                      child: ListView.builder(
                        itemCount: products.length,
                        itemBuilder: (context, index) {
                          final p = products[index];
                          return ListTile(
                            dense: true,
                            title: Text(
                              p.label,
                              style: TextStyle(
                                color: Colors.white,
                                fontSize: 12,
                              ),
                            ),
                            trailing: Row(
                              mainAxisSize: MainAxisSize.min,
                              children: [
                                Text(
                                  '${p.price.toStringAsFixed(2)} €',
                                  style: TextStyle(
                                    color: Colors.blue,
                                    fontWeight: FontWeight.bold,
                                    fontSize: 13,
                                  ),
                                ),
                                IconButton(
                                  icon: Icon(
                                    Icons.delete,
                                    color: Colors.red,
                                    size: 16,
                                  ),
                                  onPressed: () => _removeProduct(index),
                                ),
                              ],
                            ),
                          );
                        },
                      ),
                    ),
                  Container(
                    margin: EdgeInsets.symmetric(horizontal: 16, vertical: 6),
                    padding: EdgeInsets.symmetric(horizontal: 20, vertical: 10),
                    decoration: BoxDecoration(
                      color: Colors.blue.withOpacity(0.2),
                      borderRadius: BorderRadius.circular(30),
                      border: Border.all(color: Colors.blue),
                    ),
                    child: Row(
                      mainAxisAlignment: MainAxisAlignment.spaceBetween,
                      children: [
                        Text(
                          'Total',
                          style: TextStyle(
                            color: Colors.white,
                            fontSize: 18,
                            fontWeight: FontWeight.bold,
                          ),
                        ),
                        Text(
                          '${total.toStringAsFixed(2)} €',
                          style: TextStyle(
                            color: Colors.blue,
                            fontSize: 18,
                            fontWeight: FontWeight.bold,
                          ),
                        ),
                      ],
                    ),
                  ),
                  Padding(
                    padding: EdgeInsets.only(bottom: 16, top: 4),
                    child: Row(
                      mainAxisAlignment: MainAxisAlignment.center,
                      children: [
                        GestureDetector(
                          onTap: _showHistory,
                          child: Container(
                            width: 48,
                            height: 48,
                            margin: EdgeInsets.only(right: 24),
                            decoration: BoxDecoration(
                              shape: BoxShape.circle,
                              border: Border.all(color: Colors.white, width: 2),
                              color: Colors.grey[800],
                            ),
                            child:
                                lastImagePath != null &&
                                    File(lastImagePath!).existsSync()
                                ? ClipOval(
                                    child: Image.file(
                                      File(lastImagePath!),
                                      fit: BoxFit.cover,
                                    ),
                                  )
                                : Icon(
                                    Icons.history,
                                    color: Colors.white,
                                    size: 22,
                                  ),
                          ),
                        ),
                        GestureDetector(
                          onTap: _scanPrice,
                          child: Container(
                            width: 72,
                            height: 72,
                            decoration: BoxDecoration(
                              shape: BoxShape.circle,
                              color: isProcessing ? Colors.grey : Colors.blue,
                              border: Border.all(color: Colors.white, width: 3),
                            ),
                            child: isProcessing
                                ? Padding(
                                    padding: EdgeInsets.all(14),
                                    child: CircularProgressIndicator(
                                      color: Colors.white,
                                      strokeWidth: 2,
                                    ),
                                  )
                                : Icon(
                                    Icons.camera_alt,
                                    color: Colors.white,
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
                              margin: EdgeInsets.only(left: 24),
                              decoration: BoxDecoration(
                                shape: BoxShape.circle,
                                border: Border.all(color: Colors.red, width: 2),
                              ),
                              child: Icon(Icons.refresh, color: Colors.red),
                            ),
                          ),
                      ],
                    ),
                  ),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }
}
