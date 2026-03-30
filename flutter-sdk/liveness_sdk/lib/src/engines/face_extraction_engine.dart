import 'dart:async';
import 'dart:isolate';
import 'dart:typed_data';
import 'dart:ui';
import 'package:google_mlkit_face_detection/google_mlkit_face_detection.dart';
import 'package:image/image.dart' as img;

class FaceExtractionEngine {
  late final FaceDetector _faceDetector;

  FaceExtractionEngine() {
    _faceDetector = FaceDetector(
      options: FaceDetectorOptions(
        enableContours: true,
        enableClassification: false,
        enableLandmarks: true,
        performanceMode: FaceDetectorMode.fast,
      ),
    );
  }

  /// Disposes the underlying ML Kit face detector resources.
  void dispose() {
    _faceDetector.close();
  }

  /// Extracts a face from the raw image data.
  /// Works in two steps:
  /// 1. Runs ML Kit face detection natively without blocking UI.
  /// 2. Crops the image synchronously in a background Isolate.
  Future<Uint8List?> extractFace({
    required Uint8List rawImageData,
    required int width,
    required int height,
    required InputImageFormat format,
    required InputImageRotation rotation,
    required int bytesPerRow,
    double paddingScale = 1.2,
  }) async {
    // 1. Create InputImage for ML Kit
    final inputImage = InputImage.fromBytes(
      bytes: rawImageData,
      metadata: InputImageMetadata(
        size: Size(width.toDouble(), height.toDouble()),
        rotation: rotation,
        format: format,
        bytesPerRow: bytesPerRow,
      ),
    );

    // 2. Detect faces. ML Kit natively runs this on a background thread.
    final faces = await _faceDetector.processImage(inputImage);
    if (faces.isEmpty) {
      return null;
    }

    // Usually, we pick the most prominent face.
    final face = faces.first;
    final boundingBox = face.boundingBox;

    // 3. Spawning Isolate to crop the image buffer so we don't block the UI thread doing math
    return await Isolate.run(() {
      print("[Extraction Engine] Background Isolate: Cropping the detected face");

      img.Image? decodedImage;
      if (format == InputImageFormat.bgra8888) {
        decodedImage = img.Image.fromBytes(
            width: width, 
            height: height, 
            bytes: rawImageData.buffer, 
            order: img.ChannelOrder.bgra);
      } else {
        // Fallback for NV21 and other formats. Production SDKs often write custom 
        // fast C++ / Dart FFI routines for YUV to RGB conversion.
        decodedImage = img.Image.fromBytes(
            width: width, 
            height: height, 
            bytes: rawImageData.buffer);
      }

      if (decodedImage == null) return null;

      // Apply padding to the bounding box safely clamped to image bounds
      final int cropX = (boundingBox.left - (boundingBox.width * (paddingScale - 1) / 2)).toInt().clamp(0, width);
      final int cropY = (boundingBox.top - (boundingBox.height * (paddingScale - 1) / 2)).toInt().clamp(0, height);
      final int cropWidth = (boundingBox.width * paddingScale).toInt().clamp(0, width - cropX);
      final int cropHeight = (boundingBox.height * paddingScale).toInt().clamp(0, height - cropY);

      // Execute Crop
      final croppedImage = img.copyCrop(decodedImage, x: cropX, y: cropY, width: cropWidth, height: cropHeight);
      
      // Encode back to jpg byte array
      return Uint8List.fromList(img.encodeJpg(croppedImage, quality: 90));
    });
  }
}
