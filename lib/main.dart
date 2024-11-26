import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:camera/camera.dart';
import 'package:exif/exif.dart';
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
  File? processedImageFile; // Для отображения обработанного изображения
  File? rotatedImageFile; // Для отображения изображения после поворота
  bool isProcessing = false;

  @override
  void initState() {
    super.initState();
    // Инициализация контроллера камеры
    _controller = CameraController(
      widget.camera,
      ResolutionPreset.high,
    );
    _initializeControllerFuture = _controller.initialize();

    // Копирование e13b.traineddata в папку tessdata
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
    // Освобождение ресурсов контроллера при удалении виджета
    _controller.dispose();
    super.dispose();
  }

  // Метод сброса состояния
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

      // Убедиться, что камера инициализирована
      await _initializeControllerFuture;

      // Захват изображения
      final image = await _controller.takePicture();
      imageFile = image;
      print('Image captured: ${image.path}');

      // Проверка существования файла изображения
      if (!await File(image.path).exists()) {
        print('Image file does not exist.');
        setState(() {
          isProcessing = false;
          recognizedText = 'Error: Image file does not exist.';
        });
        return;
      }

      // Обработка изображения
      String ocrText = await processImage(image);

      setState(() {
        recognizedText = ocrText;
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

    // Возвращаем результат
    image
      ..data = result.data
      ..frames = result.frames;
  }


  Future<String> processImage(XFile image) async {
    try {
      // Чтение байтов изображения
      final bytes = await image.readAsBytes();
      print('Image bytes length: ${bytes.length}');

      // Чтение данных EXIF для получения ориентации
      img.Image? capturedImage = img.decodeImage(bytes);

      if (capturedImage == null) {
        print('Error decoding image.');
        return 'Error decoding image';
      }
      print('Image decoded: ${capturedImage.width}x${capturedImage.height}');

      // Поворот изображения, если оно в портретной ориентации
      if (capturedImage.width < capturedImage.height) {
        capturedImage = img.copyRotate(capturedImage, angle: -90);
        print('Rotated image by -90 degrees to make it landscape.');
      }

      // Сохранение повернутого изображения для отображения
      Directory tempDir = await getTemporaryDirectory();
      String tempRotatedPath = path.join(
        tempDir.path,
        'rotated_image_${DateTime.now().millisecondsSinceEpoch}.png',
      );
      File tempRotatedFile = File(tempRotatedPath);
      await tempRotatedFile.writeAsBytes(img.encodePng(capturedImage));
      print('Rotated image saved: $tempRotatedPath');

      // Отображение повернутого изображения
      setState(() {
        rotatedImageFile = tempRotatedFile;
      });

      // Теперь изображение должно быть правильно ориентировано.

      // Кадрирование нижних 30% изображения
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

      // Преобразование в градации серого
      img.Image grayscaleImage = img.grayscale(croppedImage);

      // Применение гистограммной эквализации
      // img.equalize(grayscaleImage);

      // Улучшение контрастности
      img.Image contrastEnhancedImage =
      img.adjustColor(grayscaleImage, contrast: 1.5);

      // Применение размытия Гаусса для уменьшения шума
      img.gaussianBlur(contrastEnhancedImage, radius: 1);

      // Применение адаптивного порогового преобразования
      adaptiveThreshold(contrastEnhancedImage, blockSize: 15, C: 10);

      // Использование обработанного изображения для OCR
      img.Image processedImage = contrastEnhancedImage;

      // Сохранение обработанного изображения
      String tempPath = path.join(
        tempDir.path,
        'processed_image_${DateTime.now().millisecondsSinceEpoch}.png',
      );
      File tempFile = File(tempPath);
      await tempFile.writeAsBytes(img.encodePng(processedImage));
      print('Processed image saved: $tempPath');

      // Отображение обработанного изображения
      setState(() {
        processedImageFile = tempFile;
      });

      // Выполнение OCR
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
            // Предварительный просмотр камеры с наложением прямоугольника
            Container(
              height: 500, // Отрегулируйте высоту по необходимости
              child: FutureBuilder<void>(
                future: _initializeControllerFuture,
                builder: (context, snapshot) {
                  if (snapshot.connectionState == ConnectionState.done) {
                    // Отображение предварительного просмотра камеры с наложением
                    return LayoutBuilder(
                      builder: (context, constraints) {
                        double overlayHeight =
                            constraints.maxHeight * .9; // 90% от высоты превью
                        double overlayWidth = overlayHeight /
                            1.7; // Ширина на основе соотношения сторон
                        double left =
                            (constraints.maxWidth - overlayWidth) / 2;
                        double top =
                            (constraints.maxHeight - overlayHeight) / 2;

                        return Stack(
                          fit: StackFit.expand,
                          children: [
                            CameraPreview(_controller),
                            // Прямоугольник для позиционирования
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
                    // Индикатор загрузки
                    return Center(child: CircularProgressIndicator());
                  }
                },
              ),
            ),
            // Отображение захваченного изображения
            if (imageFile != null)
              Column(
                children: [
                  Text('Captured Image:'),
                  Image.file(File(imageFile!.path)),
                ],
              ),
            // Отображение повернутого изображения
            if (rotatedImageFile != null)
              Column(
                children: [
                  Text('Rotated Image:'),
                  Image.file(rotatedImageFile!),
                ],
              ),
            // Отображение обработанного изображения
            if (processedImageFile != null)
              Column(
                children: [
                  Text('Processed Image:'),
                  Image.file(processedImageFile!),
                ],
              ),
            // Индикатор обработки
            if (isProcessing)
              Padding(
                padding: const EdgeInsets.all(8.0),
                child: CircularProgressIndicator(),
              ),
            // Отображение распознанного текста
            if (!isProcessing && recognizedText.isNotEmpty)
              Padding(
                padding: const EdgeInsets.all(8.0),
                child: Text(
                  'Recognized MICR Line:\n$recognizedText',
                  style: TextStyle(fontSize: 16),
                ),
              ),
            // Кнопки управления
            Padding(
              padding: const EdgeInsets.all(8.0),
              child: Column(
                children: [
                  // Кнопка захвата и обработки
                  ElevatedButton(
                    onPressed: isProcessing ? null : captureAndProcessImage,
                    child: Text('Capture and Process'),
                  ),
                  // Кнопка сброса (отображается только после обработки)
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
