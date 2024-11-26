import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:camera/camera.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart'; // For rootBundle
import 'package:flutter_tesseract_ocr/flutter_tesseract_ocr.dart';
import 'package:image/image.dart' as img; // 'as img' to avoid name conflicts
import 'package:path_provider/path_provider.dart';
import 'package:path/path.dart' as path;

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  final cameras = await availableCameras();
  final firstCamera = cameras.first;

  runApp(
    MaterialApp(
      home: MicroOcrApp(camera: firstCamera),
    ),
  );
}

class MicroOcrApp extends StatefulWidget {
  final CameraDescription camera;

  const MicroOcrApp({Key? key, required this.camera}) : super(key: key);

  @override
  _MicroOcrAppState createState() => _MicroOcrAppState();
}

class _MicroOcrAppState extends State<MicroOcrApp> {
  late CameraController _controller;
  late Future<void> _initializeControllerFuture;
  String recognizedText = '';
  XFile? imageFile;
  File? processedImageFile; // To display the processed image
  File? rotatedImageFile; // To display the rotated image
  bool isProcessing = false;

  @override
  void initState() {
    super.initState();
    // Initialize the camera controller
    _controller = CameraController(
      widget.camera,
      ResolutionPreset.high,
    );
    _initializeControllerFuture = _controller.initialize();

    // Copy e13b.traineddata to the tessdata folder
    copyTrainedData();
  }

  Future<void> copyTrainedData() async {
    try {
      final tessdataPath = await FlutterTesseractOcr.getTessdataPath();
      final trainedDataFile = File('$tessdataPath/e13b.traineddata');

      if (!await trainedDataFile.exists()) {
        ByteData data = await rootBundle.load('assets/e13b.traineddata');
        List<int> bytes =
        data.buffer.asUint8List(data.offsetInBytes, data.lengthInBytes);
        await trainedDataFile.writeAsBytes(bytes);
        print('e13b.traineddata copied to tessdata path.');
      } else {
        print('e13b.traineddata already exists in tessdata path.');
      }
    } catch (e) {
      print('Error copying trained data: $e');
    }
  }

  @override
  void dispose() {
    // Release controller resources when the widget is removed
    _controller.dispose();
    super.dispose();
  }

  // Method to reset the state
  void resetState() {
    setState(() {
      recognizedText = '';
      imageFile = null;
      processedImageFile = null;
      rotatedImageFile = null;
      isProcessing = false;
    });
  }

  Future<void> captureAndProcessImage() async {
    try {
      setState(() {
        isProcessing = true;
        recognizedText = '';
        processedImageFile = null;
        rotatedImageFile = null;
      });

      // Ensure the camera is initialized
      await _initializeControllerFuture;

      // Capture the image
      final image = await _controller.takePicture();
      imageFile = image;
      print('Image captured: ${image.path}');

      // Check if the image file exists
      if (!await File(image.path).exists()) {
        print('Image file does not exist.');
        setState(() {
          isProcessing = false;
          recognizedText = 'Error: Image file does not exist.';
        });
        return;
      }

      // Process the image
      String ocrText = await processImage(image);

      print("OCR Text before cleaning:\n$ocrText");

      // Split the OCR text into lines
      List<String> lines = ocrText.split('\n');

      String targetLine = '';
      // Iterate over each line to find the one with 25 digits after cleaning
      for (String line in lines) {
        String cleanedLine = line.replaceAll(RegExp(r'\D'), '');
        if (cleanedLine.length == 25) {
          targetLine = cleanedLine;
          break;
        }
      }

      // If not found, concatenate all lines and clean
      if (targetLine.isEmpty) {
        String concatenatedCleanedText =
        ocrText.replaceAll(RegExp(r'\D'), '');
        if (concatenatedCleanedText.length >= 25) {
          // Take the last 25 digits (assuming MICR line is at the end)
          targetLine = concatenatedCleanedText.substring(
              concatenatedCleanedText.length - 25);
        } else {
          setState(() {
            recognizedText =
            'Error: Expected at least 25 digits, but found ${concatenatedCleanedText.length}.';
            isProcessing = false;
          });
          return;
        }
      }

      print("Cleaned MICR Line: $targetLine");

      // Split the digits into the required parts
      String chequeNo = targetLine.substring(0, 6);
      String routingCode = targetLine.substring(6, 15);
      String accountNo = targetLine.substring(15, 25);

      // Update the recognizedText to display the results
      setState(() {
        recognizedText =
        'Cheque No: $chequeNo\nRouting Code: $routingCode\nAccount No: $accountNo';
        isProcessing = false;
      });
    } catch (e) {
      print('Error in captureAndProcessImage: $e');
      setState(() {
        isProcessing = false;
        recognizedText = 'Error: $e';
      });
    }
  }


  void adaptiveThreshold(img.Image image, {int blockSize = 15, double C = 10}) {
    int width = image.width;
    int height = image.height;
    img.Image result = img.Image.from(image);

    for (int y = 0; y < height; y++) {
      for (int x = 0; x < width; x++) {
        int x0 = (x - blockSize ~/ 2).clamp(0, width - 1);
        int x1 = (x + blockSize ~/ 2).clamp(0, width - 1);
        int y0 = (y - blockSize ~/ 2).clamp(0, height - 1);
        int y1 = (y + blockSize ~/ 2).clamp(0, height - 1);

        double sum = 0;
        int count = 0;

        for (int j = y0; j <= y1; j++) {
          for (int i = x0; i <= x1; i++) {
            img.Pixel p = image.getPixel(i, j);
            sum += p.luminanceNormalized;
            count++;
          }
        }

        double mean = sum / count;
        img.Pixel pixel = image.getPixel(x, y);
        if (pixel.luminanceNormalized < mean - C / 255.0) {
          result.setPixelRgb(x, y, 0, 0, 0);
        } else {
          result.setPixelRgb(x, y, 255, 255, 255);
        }
      }
    }

    // Return the result
    image
      ..data = result.data
      ..frames = result.frames;
  }

  Future<String> processImage(XFile image) async {
    try {
      // Read the image bytes
      final bytes = await image.readAsBytes();
      print('Image bytes length: ${bytes.length}');

      // Read EXIF data to get orientation
      img.Image? capturedImage = img.decodeImage(bytes);

      if (capturedImage == null) {
        print('Error decoding image.');
        return 'Error decoding image';
      }
      print('Image decoded: ${capturedImage.width}x${capturedImage.height}');

      // Rotate the image if it's in portrait orientation
      if (capturedImage.width < capturedImage.height) {
        capturedImage = img.copyRotate(capturedImage, angle: -90);
        print('Rotated image by -90 degrees to make it landscape.');
      }

      // Save the rotated image for display
      Directory tempDir = await getTemporaryDirectory();
      String tempRotatedPath = path.join(
        tempDir.path,
        'rotated_image_${DateTime.now().millisecondsSinceEpoch}.png',
      );
      File tempRotatedFile = File(tempRotatedPath);
      await tempRotatedFile.writeAsBytes(img.encodePng(capturedImage));
      print('Rotated image saved: $tempRotatedPath');

      // Display the rotated image
      setState(() {
        rotatedImageFile = tempRotatedFile;
      });

      // Now the image should be properly oriented.

      // Crop the bottom 30% of the image
      int cropHeight = (capturedImage.height * 0.30).toInt();
      int yOffset = capturedImage.height - cropHeight;

      img.Image croppedImage = img.copyCrop(
        capturedImage,
        x: 0,
        y: yOffset,
        width: capturedImage.width,
        height: cropHeight,
      );
      print('Image cropped: ${croppedImage.width}x${croppedImage.height}');

      // Convert to grayscale
      img.Image grayscaleImage = img.grayscale(croppedImage);

      // Enhance contrast
      img.Image contrastEnhancedImage =
      img.adjustColor(grayscaleImage, contrast: 1.5);

      // Apply Gaussian blur to reduce noise
      img.gaussianBlur(contrastEnhancedImage, radius: 1);

      // Apply adaptive thresholding
      adaptiveThreshold(contrastEnhancedImage, blockSize: 15, C: 10);

      // Use the processed image for OCR
      img.Image processedImage = contrastEnhancedImage;

      // Save the processed image
      String tempPath = path.join(
        tempDir.path,
        'processed_image_${DateTime.now().millisecondsSinceEpoch}.png',
      );
      File tempFile = File(tempPath);
      await tempFile.writeAsBytes(img.encodePng(processedImage));
      print('Processed image saved: $tempPath');

      // Display the processed image
      setState(() {
        processedImageFile = tempFile;
      });

      // Perform OCR
      print('Starting OCR...');
      String recognizedText = await FlutterTesseractOcr.extractText(
        tempPath,
        language: 'e13b',
        args: {
          'tessedit_char_whitelist': '0123456789ABCD',
        },
      );
      print('OCR completed. Recognized Text: $recognizedText');

      return recognizedText;
    } catch (e) {
      print('Error in processImage: $e');
      return 'Error during image processing: $e';
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: Text('MICR OCR App'),
      ),
      body: SingleChildScrollView(
        child: Column(
          children: [
            // Camera preview with overlay rectangle
            Container(
              height: 500, // Adjust the height as needed
              child: FutureBuilder<void>(
                future: _initializeControllerFuture,
                builder: (context, snapshot) {
                  if (snapshot.connectionState == ConnectionState.done) {
                    // Display the camera preview with overlay
                    return LayoutBuilder(
                      builder: (context, constraints) {
                        double overlayHeight =
                            constraints.maxHeight * .9; // 90% of preview height
                        double overlayWidth = overlayHeight /
                            1.7; // Width based on aspect ratio
                        double left =
                            (constraints.maxWidth - overlayWidth) / 2;
                        double top =
                            (constraints.maxHeight - overlayHeight) / 2;

                        return Stack(
                          fit: StackFit.expand,
                          children: [
                            CameraPreview(_controller),
                            // Rectangle for positioning
                            Positioned(
                              left: left,
                              top: top,
                              child: Container(
                                width: overlayWidth,
                                height: overlayHeight,
                                decoration: BoxDecoration(
                                  border: Border.all(
                                    color: Colors.red,
                                    width: 2,
                                  ),
                                ),
                              ),
                            ),
                          ],
                        );
                      },
                    );
                  } else {
                    // Loading indicator
                    return Center(child: CircularProgressIndicator());
                  }
                },
              ),
            ),
            // Display the captured image
            if (imageFile != null)
              Column(
                children: [
                  Text('Captured Image:'),
                  Image.file(File(imageFile!.path)),
                ],
              ),
            // Display the rotated image
            if (rotatedImageFile != null)
              Column(
                children: [
                  Text('Rotated Image:'),
                  Image.file(rotatedImageFile!),
                ],
              ),
            // Display the processed image
            if (processedImageFile != null)
              Column(
                children: [
                  Text('Processed Image:'),
                  Image.file(processedImageFile!),
                ],
              ),
            // Processing indicator
            if (isProcessing)
              Padding(
                padding: const EdgeInsets.all(8.0),
                child: CircularProgressIndicator(),
              ),
            // Display the recognized text
            if (!isProcessing && recognizedText.isNotEmpty)
              Padding(
                padding: const EdgeInsets.all(8.0),
                child: Text(
                  recognizedText,
                  style: TextStyle(fontSize: 16),
                ),
              ),
            // Control buttons
            Padding(
              padding: const EdgeInsets.all(8.0),
              child: Column(
                children: [
                  // Capture and process button
                  ElevatedButton(
                    onPressed: isProcessing ? null : captureAndProcessImage,
                    child: Text('Capture and Process'),
                  ),
                  // Reset button (only displayed after processing)
                  if (!isProcessing &&
                      (imageFile != null || recognizedText.isNotEmpty))
                    ElevatedButton(
                      onPressed: resetState,
                      child: Text('Reset'),
                      style: ElevatedButton.styleFrom(),
                    ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}
