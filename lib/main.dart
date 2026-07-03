import 'package:flutter/material.dart';
import 'package:camera/camera.dart';
import 'package:google_mlkit_text_recognition/google_mlkit_text_recognition.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:flutter_litert/flutter_litert.dart';
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
  Interpreter? _interpreter;
  String? lastImagePath;

  final TextRecognizer textRecognizer = TextRecognizer(
    script: TextRecognitionScript.latin,
  );

  @override
  void initState() {
    super.initState();
    _initCamera();
    _loadModel();
  }

  Future<void> _loadModel() async {
    try {
      _interpreter = await Interpreter.fromAsset(
        'assets/ml/best_float32.tflite',
      );
      print('✅ Modèle YOLO chargé');
    } catch (e) {
      print('❌ Erreur chargement YOLO : $e');
    }
  }

  Future<void> _initCamera() async {
    final status = await Permission.camera.request();
    if (!status.isGranted) {
      setState(() => detectedText = "Permission refusée");
      return;
    }
    controller = CameraController(
      cameras[0],
      ResolutionPreset.medium, // ✅ Réduit pour plus de vitesse
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

  List<List<List<List<double>>>> _prepareImage(img.Image image) {
    final resized = img.copyResize(image, width: 640, height: 640);
    return List.generate(
      1,
      (_) => List.generate(
        640,
        (y) => List.generate(640, (x) {
          final pixel = resized.getPixel(x, y);
          return [pixel.r / 255.0, pixel.g / 255.0, pixel.b / 255.0];
        }),
      ),
    );
  }

  Map<String, double>? _detectPriceTag(img.Image image) {
    if (_interpreter == null) return null;
    final input = _prepareImage(image);
    final output = List.generate(
      1,
      (_) => List.generate(5, (_) => List.filled(8400, 0.0)),
    );
    _interpreter!.run(input, output);

    double bestConf = 0.3;
    int bestIdx = -1;
    for (int i = 0; i < 8400; i++) {
      if (output[0][4][i] > bestConf) {
        bestConf = output[0][4][i];
        bestIdx = i;
      }
    }
    if (bestIdx == -1) return null;

    final imgW = image.width.toDouble();
    final imgH = image.height.toDouble();
    final xc = output[0][0][bestIdx] / 640 * imgW;
    final yc = output[0][1][bestIdx] / 640 * imgH;
    final w = output[0][2][bestIdx] / 640 * imgW;
    final h = output[0][3][bestIdx] / 640 * imgH;

    return {
      'x1': (xc - w / 2).clamp(0, imgW),
      'y1': (yc - h / 2).clamp(0, imgH),
      'x2': (xc + w / 2).clamp(0, imgW),
      'y2': (yc + h / 2).clamp(0, imgH),
      'conf': bestConf,
    };
  }

  // ✅ Regex corrigée - prend le plus petit prix en cas de promo
  double? _extractPrice(String text) {
    final patterns = [
      RegExp(r'\b(\d{1,4})[.,](\d{2})\s*€?\b'),
      RegExp(r'\b(\d{1,4})[.,](\d{1})\s*€?\b'),
      RegExp(r'\b(\d{1,4})\s*€\s*(\d{2})\b'),
      RegExp(r'\b([1-9])(\d{2})\b'),
      RegExp(r'\b(\d{1,3})\b'),
    ];

    List<double> prices = [];

    for (final regex in patterns) {
      for (final match in regex.allMatches(text)) {
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
    // ✅ Prend le plus petit prix — en cas de promo c'est le bon
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
      final image = img.decodeImage(imageBytes)!;
      String scanPath = imageFile.path;

      if (_interpreter != null) {
        final bbox = _detectPriceTag(image);
        if (bbox != null) {
          final margin = 10.0;
          final x1 = (bbox['x1']! - margin)
              .clamp(0, image.width.toDouble())
              .toInt();
          final y1 = (bbox['y1']! - margin)
              .clamp(0, image.height.toDouble())
              .toInt();
          final x2 = (bbox['x2']! + margin)
              .clamp(0, image.width.toDouble())
              .toInt();
          final y2 = (bbox['y2']! + margin)
              .clamp(0, image.height.toDouble())
              .toInt();

          final cropWidth = x2 - x1;
          final cropHeight = y2 - y1;

          // ✅ Fix crop trop petit
          if (cropWidth >= 32 && cropHeight >= 32) {
            final cropped = img.copyCrop(
              image,
              x: x1,
              y: y1,
              width: cropWidth,
              height: cropHeight,
            );
            final cropPath = imageFile.path.replaceAll('.jpg', '_crop.jpg');
            await File(cropPath).writeAsBytes(img.encodeJpg(cropped));
            scanPath = cropPath;
            setState(
              () => detectedText =
                  'Étiquette trouvée (${(bbox['conf']! * 100).toInt()}%) — lecture...',
            );
          } else {
            setState(() => detectedText = 'Zone trop petite — OCR direct...');
          }
        } else {
          setState(
            () => detectedText = 'Étiquette non trouvée — OCR direct...',
          );
        }
      }

      final inputImage = InputImage.fromFilePath(scanPath);
      final RecognizedText recognizedText = await textRecognizer.processImage(
        inputImage,
      );
      double? price = _extractPrice(recognizedText.text);

      if (price != null) {
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
                'Lorem ipsum dolor sit amet, consectetur adipiscing elit. Sed do eiusmod tempor incididunt ut labore et dolore magna aliqua.',
              );
            },
          ),
          ListTile(
            leading: Icon(Icons.mail_outline, color: Colors.blue),
            title: Text('Contact', style: TextStyle(color: Colors.white)),
            onTap: () {
              Navigator.pop(context);
              _showPage(
                'Contact',
                'Pour nous contacter : contact@weboara.fr\n\nLorem ipsum dolor sit amet.',
              );
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
    controller?.dispose();
    textRecognizer.close();
    _interpreter?.close();
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

          // 🔳 Cadre de scan
          Center(
            child: Container(
              width: 300,
              height: 180,
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
