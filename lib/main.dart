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
  final double frameAspectRatio = 1.9; // height/width ratio for the frame

  @override
  void initState() {
    super.initState();
    print('sdsd');
    // Initialize the camera controller
    _controller = CameraController(
      widget.camera,
      ResolutionPreset.high,
        enableAudio: false,
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
      String ocrResult = await processImage(image);

      setState(() {
        recognizedText = ocrResult;
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

      // Decode the image
      img.Image? originalImage = img.decodeImage(bytes);

      if (originalImage == null) {
        print('Error decoding image.');
        return 'Error decoding image';
      }
      print('Image decoded: ${originalImage.width}x${originalImage.height}');

      // Rotate the image if it's in portrait orientation
      if (originalImage.width < originalImage.height) {
        originalImage = img.copyRotate(originalImage, angle: -90);
        print('Rotated image by -90 degrees to make it landscape.');
      }

      // Save the rotated image for display
      Directory tempDir = await getTemporaryDirectory();
      String tempRotatedPath = path.join(
        tempDir.path,
        'rotated_image_${DateTime.now().millisecondsSinceEpoch}.png',
      );
      File tempRotatedFile = File(tempRotatedPath);
      await tempRotatedFile.writeAsBytes(img.encodePng(originalImage));
      print('Rotated image saved: $tempRotatedPath');

      // Display the rotated image
      setState(() {
        rotatedImageFile = tempRotatedFile;
      });

      // Try processing the image in original orientation
      String? result = await extractMicrData(originalImage, isRotated: false);

      if (result == null) {
        // Rotate the image by 180 degrees and try again
        img.Image rotated180Image = img.copyRotate(originalImage, angle: 180);
        print('Rotated image by 180 degrees to handle upside-down check.');

        // Save the 180-degree rotated image for debugging (optional)
        String tempRotated180Path = path.join(
          tempDir.path,
          'rotated180_image_${DateTime.now().millisecondsSinceEpoch}.png',
        );
        File tempRotated180File = File(tempRotated180Path);
        await tempRotated180File.writeAsBytes(img.encodePng(rotated180Image));
        print('Rotated 180 image saved: $tempRotated180Path');

        // Display the rotated 180 image (optional)
        // setState(() {
        //   rotatedImageFile = tempRotated180File;
        // });

        // Try processing the rotated image
        result = await extractMicrData(rotated180Image, isRotated: true);

        if (result == null) {
          return 'Error: Unable to extract MICR data.';
        }
      }

      return result;
    } catch (e) {
      print('Error in processImage: $e');
      return 'Error during image processing: $e';
    }
  }

  Future<String?> extractMicrData(img.Image capturedImage, {bool isRotated = false}) async {
    try {
      print('Original image size: ${capturedImage.width}x${capturedImage.height}');

      // STEP 1: Calculate frame dimensions using the same logic as in UI
      double frameWidth = capturedImage.width * 0.9; // Start with 90% of width
      double frameHeight = frameWidth * (1 / frameAspectRatio); // inverting
      
      // if height is to big recounting from height
      if (frameHeight > capturedImage.height * 0.9) {
        frameHeight = capturedImage.height * 0.9;
        frameWidth = frameHeight * frameAspectRatio;
      }
      
      // Calculate center position
      int frameX = ((capturedImage.width - frameWidth) / 2).round();
      int frameY = ((capturedImage.height - frameHeight) / 2).round();
      
      print('Calculated frame crop parameters:');
      print('frameWidth: $frameWidth, frameHeight: $frameHeight');
      print('frameX: $frameX, frameY: $frameY');

      // Crop the frame area
      img.Image framedImage = img.copyCrop(
        capturedImage,
        x: frameX,
        y: frameY,
        width: frameWidth.round(),
        height: frameHeight.round(),
      );

      print('After frame crop size: ${framedImage.width}x${framedImage.height}');

      // Debug save
      Directory tempDir = await getTemporaryDirectory();
      String framedDebugPath = path.join(
        tempDir.path,
        'framed_debug_${DateTime.now().millisecondsSinceEpoch}.png',
      );
      await File(framedDebugPath).writeAsBytes(img.encodePng(framedImage));
      print('Saved debug framed image to: $framedDebugPath');

      // Take bottom 30% of the framed image
      int bottomCropHeight = (framedImage.height * 0.30).round();
      int bottomCropY = framedImage.height - bottomCropHeight;

      img.Image bottomCroppedImage = img.copyCrop(
        framedImage,
        x: 0,
        y: bottomCropY,
        width: framedImage.width,
        height: bottomCropHeight,
      );

      print('After bottom crop size: ${bottomCroppedImage.width}x${bottomCroppedImage.height}');

      // Process the bottom-cropped image
      img.Image processedImage = img.grayscale(bottomCroppedImage);
      processedImage = img.adjustColor(processedImage, contrast: 1.5);
      img.gaussianBlur(processedImage, radius: 1);
      adaptiveThreshold(processedImage, blockSize: 15, C: 10);

      print('Final processed image size: ${processedImage.width}x${processedImage.height}');

      // Save all intermediate images for debugging
      // Save framed image
      String framedPath = path.join(
        tempDir.path,
        'framed_${DateTime.now().millisecondsSinceEpoch}.png',
      );
      await File(framedPath).writeAsBytes(img.encodePng(framedImage));
      print('Saved framed image to: $framedPath');

      // Save bottom cropped image
      String bottomCroppedPath = path.join(
        tempDir.path,
        'bottom_cropped_${DateTime.now().millisecondsSinceEpoch}.png',
      );
      await File(bottomCroppedPath).writeAsBytes(img.encodePng(bottomCroppedImage));
      print('Saved bottom cropped image to: $bottomCroppedPath');

      // Save final processed image
      String processedPath = path.join(
        tempDir.path,
        'processed_${DateTime.now().millisecondsSinceEpoch}.png',
      );
      File processedFile = File(processedPath);
      await processedFile.writeAsBytes(img.encodePng(processedImage));
      print('Saved processed image to: $processedPath');

      setState(() {
        processedImageFile = processedFile;
      });

      // Perform OCR on the processed image
      String ocrText = await FlutterTesseractOcr.extractText(
        processedPath,
        language: 'e13b',
        args: {
          // 'tessedit_char_whitelist': '0123456789⑆⑇⑈',
          'tessedit_char_whitelist': '0123456789ABCD',
          // 'tessedit_char_whitelist': '0123456789',
        },
      );

      print("OCR Text before cleaning:\n$ocrText");

      // splitting into strings
      List<String> lines = ocrText.split('\n');
      // regexp for pattern C...A...AC...C
      RegExp micrPattern = RegExp(r'C(\d+)A(\d+)AC(\d+)C');

      for (String line in lines) {
        // removing spaces
        String noSpaces = line.trim().replaceAll(' ', '');
        print("Processing line: $noSpaces");
        
        Match? match = micrPattern.firstMatch(noSpaces);
        
        if (match != null) {
          // combining digits
          String targetLine = '${match.group(1)}${match.group(2)}${match.group(3)}';
          print("MICR components found in line:");
          print(" - First part (after initial C): ${match.group(1)}");
          print(" - Second part (between A and AC): ${match.group(2)}");
          print(" - Third part (before final C): ${match.group(3)}");
          print("Combined digits: $targetLine");

          if (targetLine.length == 25) {
            // splitting apart
            String chequeNo = targetLine.substring(0, 6);
            String routingCode = targetLine.substring(6, 15);
            String accountNo = targetLine.substring(15, 25);

            String result = 'Cheque No: $chequeNo\nRouting Code: $routingCode\nAccount No: $accountNo';
            if (isRotated) {
              result += '\n(Note: Image was rotated 180 degrees to extract data)';
            }
            return result;
          }
        }
      }

      print('Error: Invalid MICR format or not 25 digits');
      return null;

    } catch (e) {
      print('Error in extractMicrData: $e');
      return null;
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
              height: MediaQuery.of(context).size.height * 0.8, // 60% высоты экрана
              child: FutureBuilder<void>(
                future: _initializeControllerFuture,
                builder: (context, snapshot) {
                  if (snapshot.connectionState == ConnectionState.done) {
                    // Display the camera preview with overlay
                    return LayoutBuilder(
                      builder: (context, constraints) {
                        double overlayHeight =
                            constraints.maxHeight * 0.9; // 90% of preview height
                        double overlayWidth = overlayHeight / frameAspectRatio;
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
