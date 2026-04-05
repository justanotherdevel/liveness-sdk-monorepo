import 'dart:async';
import 'dart:io';
import 'dart:isolate';
import 'dart:ui';
import 'package:flutter/foundation.dart';
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
      debugPrint(
        "[Extraction Engine] Background Isolate: Cropping the detected face",
      );

      img.Image? decodedImage;
      if (format == InputImageFormat.bgra8888) {
        decodedImage = img.Image.fromBytes(
          width: width,
          height: height,
          bytes: rawImageData.buffer,
          order: img.ChannelOrder.bgra,
        );
      } else {
        // Fallback for NV21 and other formats. Production SDKs often write custom
        // fast C++ / Dart FFI routines for YUV to RGB conversion.
        decodedImage = img.Image.fromBytes(
          width: width,
          height: height,
          bytes: rawImageData.buffer,
        );
      }
      // Apply padding to the bounding box safely clamped to image bounds
      final int cropX =
          (boundingBox.left - (boundingBox.width * (paddingScale - 1) / 2))
              .toInt()
              .clamp(0, width);
      final int cropY =
          (boundingBox.top - (boundingBox.height * (paddingScale - 1) / 2))
              .toInt()
              .clamp(0, height);
      final int cropWidth = (boundingBox.width * paddingScale).toInt().clamp(
        0,
        width - cropX,
      );
      final int cropHeight = (boundingBox.height * paddingScale).toInt().clamp(
        0,
        height - cropY,
      );

      // Execute Crop
      final croppedImage = img.copyCrop(
        decodedImage,
        x: cropX,
        y: cropY,
        width: cropWidth,
        height: cropHeight,
      );

      // Encode back to jpg byte array
      return Uint8List.fromList(img.encodeJpg(croppedImage, quality: 90));
    });
  }

  /// Extracts a face from a static file path (e.g., from a decoded Base64 JPEG).
  Future<Uint8List?> extractFaceFromFile({
    required String filePath,
    double paddingScale = 1.2,
  }) async {
    final inputImage = InputImage.fromFilePath(filePath);

    final faces = await _faceDetector.processImage(inputImage);
    if (faces.isEmpty) return null;

    final boundingBox = faces.first.boundingBox;

    return await Isolate.run(() {
      debugPrint(
        "[Extraction Engine] Background Isolate: Cropping detected face from file",
      );
      final decodedImage = img.decodeImage(File(filePath).readAsBytesSync());
      if (decodedImage == null) return null;

      final int width = decodedImage.width;
      final int height = decodedImage.height;

      final int cropX =
          (boundingBox.left - (boundingBox.width * (paddingScale - 1) / 2))
              .toInt()
              .clamp(0, width);
      final int cropY =
          (boundingBox.top - (boundingBox.height * (paddingScale - 1) / 2))
              .toInt()
              .clamp(0, height);
      final int cropWidth = (boundingBox.width * paddingScale).toInt().clamp(
        0,
        width - cropX,
      );
      final int cropHeight = (boundingBox.height * paddingScale).toInt().clamp(
        0,
        height - cropY,
      );

      final croppedImage = img.copyCrop(
        decodedImage,
        x: cropX,
        y: cropY,
        width: cropWidth,
        height: cropHeight,
      );
      return Uint8List.fromList(img.encodeJpg(croppedImage, quality: 90));
    });
  }

  /// Runs face detection ONCE and extracts two crops in a single isolate pass:
  ///
  /// - [tightCrop]: paddingScale=1.2, suitable for ArcFace identity matching.
  /// - [livenessCrop]: paddingScale=2.7, required by MiniFASNet which needs
  ///   the forehead, ears, and background context to detect spoofs. Without
  ///   this wider crop the model only sees clean face texture and will score
  ///   even a printed photo as "live".
  ///
  /// Returns null for both if no face is detected.
  Future<FaceExtractionResult> extractDualCropFromFile({
    required String filePath,
    double tightScale = 1.2,
    double livenessScale = 2.7,
  }) async {
    final inputImage = InputImage.fromFilePath(filePath);
    final faces = await _faceDetector.processImage(inputImage);

    if (faces.isEmpty) {
      debugPrint("[Extraction Engine] No face detected in file.");
      return FaceExtractionResult(null, null);
    }

    final boundingBox = faces.first.boundingBox;

    return await Isolate.run(() {
      debugPrint(
        "[Extraction Engine] Background Isolate: Extracting dual crop (tight ${tightScale}x, liveness ${livenessScale}x)",
      );
      final rawBytes = File(filePath).readAsBytesSync();
      final decodedImage = img.decodeImage(rawBytes);
      if (decodedImage == null) return FaceExtractionResult(null, null);

      final int w = decodedImage.width;
      final int h = decodedImage.height;

      Uint8List? doCrop(double scale) {
        final int cx =
            (boundingBox.left - (boundingBox.width * (scale - 1) / 2))
                .toInt()
                .clamp(0, w);
        final int cy =
            (boundingBox.top - (boundingBox.height * (scale - 1) / 2))
                .toInt()
                .clamp(0, h);
        final int cw = (boundingBox.width * scale).toInt().clamp(1, w - cx);
        final int ch = (boundingBox.height * scale).toInt().clamp(1, h - cy);
        final cropped = img.copyCrop(
          decodedImage,
          x: cx,
          y: cy,
          width: cw,
          height: ch,
        );
        return Uint8List.fromList(img.encodeJpg(cropped, quality: 90));
      }

      return FaceExtractionResult(doCrop(tightScale), doCrop(livenessScale));
    });
  }
}

/// Result of a dual-crop extraction pass.
/// [tightCrop]    – 1.2× padded JPEG, for ArcFace / identity matching.
/// [livenessCrop] – 2.7× padded JPEG, for MiniFASNet anti-spoofing.
class FaceExtractionResult {
  final Uint8List? tightCrop;
  final Uint8List? livenessCrop;
  const FaceExtractionResult(this.tightCrop, this.livenessCrop);
}
