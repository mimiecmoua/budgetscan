import 'package:flutter/material.dart';
import 'package:flutter/foundation.dart';
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
  bool _isScanning = false;
  String detectedText = 'Pointe sur un prix...';
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
    _startLiveScanning();
  }

  void _startLiveScanning() {
    controller!.startImageStream((CameraImage image) async {
      if (_isScanning) return;
      _isScanning = true;

      try {
        final WriteBuffer allBytes = WriteBuffer();
        for (final Plane plane in image.planes) {
          allBytes.putUint8List(plane.bytes);
        }
        final bytes = allBytes.done().buffer.asUint8List();

        final inputImage = InputImage.fromBytes(
          bytes: bytes,
          metadata: InputImageMetadata(
            size: Size(image.width.toDouble(), image.height.toDouble()),
            rotation: InputImageRotation.rotation0deg,
            format: InputImageFormat.nv21,
            bytesPerRow: image.planes[0].bytesPerRow,
          ),
        );

        final RecognizedText recognizedText = await textRecognizer.processImage(
          inputImage,
        );

        if (recognizedText.text.isNotEmpty) {
          double? price = _extractPrice(recognizedText.text);
          if (price != null && mounted) {
            setState(() {
              total += price;
              products.add(
                ScannedProduct(
                  label: 'Produit ${products.length + 1}',
                  price: price,
                ),
              );
              detectedText = '✅ Prix détecté : ${price.toStringAsFixed(2)} €';
            });
            await Future.delayed(Duration(seconds: 3));
          }
        }
      } catch (e) {
        print('Erreur scan live : $e');
      }

      await Future.delayed(Duration(milliseconds: 500));
      _isScanning = false;
    });
  }

  double? _extractPrice(String text) {
    final regex = RegExp(r'\b(\d{1,4}[.,]\d{2})\s*€?\b', caseSensitive: false);
    final matches = regex.allMatches(text);
    if (matches.isEmpty) return null;
    String priceStr = matches.first.group(1)!;
    priceStr = priceStr.replaceAll(',', '.');
    return double.tryParse(priceStr);
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
      detectedText = 'Pointe sur un prix...';
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
              width: 280,
              height: 160,
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
              constraints: BoxConstraints(maxHeight: 320),
              decoration: BoxDecoration(
                color: Colors.black.withOpacity(0.85),
                borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
              ),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Padding(
                    padding: EdgeInsets.all(12),
                    child: Text(
                      detectedText,
                      style: TextStyle(color: Colors.white, fontSize: 13),
                      textAlign: TextAlign.center,
                    ),
                  ),
                  if (products.isNotEmpty)
                    SizedBox(
                      height: 120,
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
                                fontSize: 13,
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
                                  ),
                                ),
                                IconButton(
                                  icon: Icon(
                                    Icons.delete,
                                    color: Colors.red,
                                    size: 18,
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
                    margin: EdgeInsets.symmetric(horizontal: 16, vertical: 8),
                    padding: EdgeInsets.symmetric(horizontal: 20, vertical: 12),
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
                    padding: EdgeInsets.only(bottom: 16),
                    child: Row(
                      mainAxisAlignment: MainAxisAlignment.center,
                      children: [
                        if (products.isNotEmpty)
                          GestureDetector(
                            onTap: _resetAll,
                            child: Container(
                              width: 48,
                              height: 48,
                              margin: EdgeInsets.only(right: 20),
                              decoration: BoxDecoration(
                                shape: BoxShape.circle,
                                border: Border.all(color: Colors.red, width: 2),
                              ),
                              child: Icon(Icons.refresh, color: Colors.red),
                            ),
                          ),
                        GestureDetector(
                          onTap: () async {
                            if (controller == null) return;
                            try {
                              final image = await controller!.takePicture();
                              final inputImage = InputImage.fromFilePath(
                                image.path,
                              );
                              final RecognizedText recognizedText =
                                  await textRecognizer.processImage(inputImage);
                              double? price = _extractPrice(
                                recognizedText.text,
                              );
                              if (price != null) {
                                setState(() {
                                  total += price;
                                  products.add(
                                    ScannedProduct(
                                      label: 'Produit ${products.length + 1}',
                                      price: price,
                                    ),
                                  );
                                  detectedText =
                                      '✅ Prix : ${price.toStringAsFixed(2)} €';
                                });
                              } else {
                                setState(
                                  () => detectedText = 'Pas de prix trouvé',
                                );
                              }
                            } catch (e) {
                              setState(() => detectedText = 'Erreur : $e');
                            }
                          },
                          child: Container(
                            width: 70,
                            height: 70,
                            decoration: BoxDecoration(
                              shape: BoxShape.circle,
                              border: Border.all(color: Colors.white, width: 4),
                            ),
                            child: Icon(Icons.camera_alt, color: Colors.white),
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
