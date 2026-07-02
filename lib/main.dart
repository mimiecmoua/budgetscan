import 'package:flutter/material.dart';
import 'package:camera/camera.dart';
import 'package:google_mlkit_text_recognition/google_mlkit_text_recognition.dart';
import 'package:permission_handler/permission_handler.dart';

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
  ScannedProduct({required this.label, required this.price});
}

class LensScreen extends StatefulWidget {
  @override
  _LensScreenState createState() => _LensScreenState();
}

class _LensScreenState extends State<LensScreen> {
  CameraController? controller;
  bool isCameraReady = false;
  bool isProcessing = false;
  String detectedText = 'Pointe sur un prix et appuie sur le bouton';
  double total = 0.0;
  List<ScannedProduct> products = [];

  final TextRecognizer textRecognizer = TextRecognizer(
    script: TextRecognitionScript.latin,
  );

  @override
  void initState() {
    super.initState();
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
      ResolutionPreset.high,
      enableAudio: false,
    );
    await controller!.initialize();
    if (!mounted) return;
    setState(() => isCameraReady = true);
  }

  double? _extractPrice(String text) {
    final patterns = [
      // Format standard : 1.25 ou 1,25
      RegExp(r'\b(\d{1,4})[.,](\d{2})\s*€?\b'),
      // Format avec € : 1€25
      RegExp(r'\b(\d{1,4})\s*€\s*(\d{2})\b'),
      // Format sans séparateur : 125 lu comme 1.25
      RegExp(r'\b([1-9])(\d{2})\b'),
    ];

    for (final regex in patterns) {
      final matches = regex.allMatches(text);
      for (final match in matches) {
        String euros = match.group(1)!;
        String cents = match.group(2)!;
        double? price = double.tryParse('$euros.$cents');
        if (price != null && price > 0 && price < 100) {
          return price;
        }
      }
    }
    return null;
  }

  Future<void> _scanPrice() async {
    if (controller == null || isProcessing) return;

    setState(() {
      isProcessing = true;
      detectedText = 'Scan en cours...';
    });

    try {
      final image = await controller!.takePicture();
      final inputImage = InputImage.fromFilePath(image.path);
      final RecognizedText recognizedText = await textRecognizer.processImage(
        inputImage,
      );

      double? price = _extractPrice(recognizedText.text);

      if (price != null) {
        setState(() {
          total += price;
          products.add(
            ScannedProduct(
              label: 'Produit ${products.length + 1}',
              price: price,
            ),
          );
          detectedText = '✅ ${price.toStringAsFixed(2)} € ajouté !';
        });
      } else {
        setState(() {
          detectedText = 'Prix non détecté — réessaie';
        });
      }
    } catch (e) {
      setState(() => detectedText = 'Erreur : $e');
    }

    setState(() => isProcessing = false);
  }

  void _removeProduct(int index) {
    setState(() {
      total -= products[index].price;
      products.removeAt(index);
    });
  }

  void _resetAll() {
    setState(() {
      total = 0.0;
      products.clear();
      detectedText = 'Pointe sur un prix et appuie sur le bouton';
    });
  }

  @override
  void dispose() {
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
                      maxLines: 2,
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
                        if (products.isNotEmpty)
                          GestureDetector(
                            onTap: _resetAll,
                            child: Container(
                              width: 48,
                              height: 48,
                              margin: EdgeInsets.only(right: 24),
                              decoration: BoxDecoration(
                                shape: BoxShape.circle,
                                border: Border.all(color: Colors.red, width: 2),
                              ),
                              child: Icon(Icons.refresh, color: Colors.red),
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
