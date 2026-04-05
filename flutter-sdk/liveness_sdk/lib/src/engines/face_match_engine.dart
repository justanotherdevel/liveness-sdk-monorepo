import 'dart:async';
import 'dart:isolate';
import 'dart:math' as math;
import 'package:flutter/services.dart' show rootBundle;
import 'package:image/image.dart' as img;
import 'package:flutter/foundation.dart';
import 'package:onnxruntime/onnxruntime.dart';

class FaceMatchEngine {
  OrtSession? _mlSession;
  bool _isInitialized = false;

  /// Initializes the arcface ONNX model from the assets directory.
  Future<void> initialize() async {
    try {
      OrtEnv.instance.init();
      final sessionOptions = OrtSessionOptions();
      // Loading mobilefacenet model from assets
      final rawAssetFile = await rootBundle.load(
        'packages/flutter_face_auth_sdk/assets/models/mobilefacenet.onnx',
      );
      _mlSession = OrtSession.fromBuffer(
        rawAssetFile.buffer.asUint8List(),
        sessionOptions,
      );
      _isInitialized = true;
      debugPrint("[Face Match Engine] ONNX Model initialized.");
    } catch (e, stackTrace) {
      debugPrint("[Face Match Engine] Failed to initialize model: $e");
      debugPrint("[Face Match Engine] Stack trace: $stackTrace");
    }
  }

  /// Manually release C++ memory to prevent SIGSEGV leaks.
  void dispose() {
    _mlSession?.release();
  }

  /// Generates a feature embedding vector from a cropped face image using arcface.onnx
  Future<List<double>> vectorizeFace(Uint8List croppedFaceBytes) async {
    if (!_isInitialized || _mlSession == null) {
      throw Exception(
        "FaceMatchEngine is not initialized. Call initialize() first.",
      );
    }

    // Typical arcface input is 112x112
    final inputSize = 112;

    final tensorBuffer = await Isolate.run(() {
      debugPrint(
        "[Face Match Engine] Background Isolate: Decoding and resizing image to ${inputSize}x$inputSize...",
      );

      final decodedImage = img.decodeImage(croppedFaceBytes);
      if (decodedImage == null) {
        throw Exception("Failed to decode cropped face image bytes.");
      }

      final resizedImage = img.copyResize(
        decodedImage,
        width: inputSize,
        height: inputSize,
      );

      var buffer = Float32List(1 * 3 * inputSize * inputSize);
      int pixelIndex = 0;

      for (int y = 0; y < inputSize; y++) {
        for (int x = 0; x < inputSize; x++) {
          final pixel = resizedImage.getPixel(x, y);
          // Normalizing pixel value distribution depending on specific model standards
          // Commonly (pixel - 127.5) / 128.0. NHWC memory layout.
          buffer[pixelIndex] = (pixel.r - 127.5) / 128.0;
          buffer[pixelIndex + 1] = (pixel.g - 127.5) / 128.0;
          buffer[pixelIndex + 2] = (pixel.b - 127.5) / 128.0;
          pixelIndex += 3;
        }
      }
      return buffer;
    });

    final shape = [1, inputSize, inputSize, 3];
    final inputTensor = OrtValueTensor.createTensorWithDataList(
      tensorBuffer,
      shape,
    );
    final runOptions = OrtRunOptions();

    List<double> faceVector = [];

    try {
      final inputs = {'serving_default_keras_tensor:0': inputTensor};
      final outputs = _mlSession!.run(runOptions, inputs);

      if (outputs.isNotEmpty) {
        final outputTensor = outputs[0];
        if (outputTensor?.value is List) {
          final vectorList = outputTensor?.value as List;
          if (vectorList.isNotEmpty && vectorList.first is List) {
            faceVector = (vectorList.first as List)
                .map((e) => (e as num).toDouble())
                .toList();
          }
        }
      }

      // CRITICAL: Prevent ONNX memory leak
      for (var out in outputs) {
        out?.release();
      }
    } catch (e) {
      debugPrint("[Face Match Engine] ONNX Inference Error: $e");
    } finally {
      inputTensor.release();
      runOptions.release();
    }

    return faceVector;
  }

  /// Calculates cosine similarity between two face feature vectors
  Future<double> compareVectors(
    List<double> referenceVector,
    List<double> targetVector,
  ) async {
    return await Isolate.run(() {
      if (referenceVector.isEmpty ||
          targetVector.isEmpty ||
          referenceVector.length != targetVector.length) {
        return 0.0;
      }

      double dotProduct = 0.0;
      double normA = 0.0;
      double normB = 0.0;

      for (int i = 0; i < referenceVector.length; i++) {
        dotProduct += referenceVector[i] * targetVector[i];
        normA += math.pow(referenceVector[i], 2);
        normB += math.pow(targetVector[i], 2);
      }

      if (normA == 0.0 || normB == 0.0) return 0.0;

      return dotProduct / (math.sqrt(normA) * math.sqrt(normB));
    });
  }
}
