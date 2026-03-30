import 'dart:async';
import 'dart:isolate';
import 'dart:typed_data';
import 'dart:math' as math;
import 'package:flutter/services.dart' show rootBundle;
import 'package:image/image.dart' as img;
import 'package:onnxruntime/onnxruntime.dart';

class FaceMatchEngine {
  OrtSession? _mlSession;
  bool _isInitialized = false;

  /// Initializes the arcface ONNX model from the assets directory.
  Future<void> initialize() async {
    try {
      OrtEnv.instance.init();
      final sessionOptions = OrtSessionOptions();
      // TODO: Place arcface.onnx in assets/models/
      final rawAssetFile = await rootBundle.load('assets/models/arcface.onnx');
      _mlSession = OrtSession.fromBuffer(rawAssetFile.buffer.asUint8List(), sessionOptions);
      _isInitialized = true;
      print("[Face Match Engine] ONNX Model initialized.");
    } catch (e) {
      print("[Face Match Engine] Failed to initialize model: \$e");
    }
  }

  /// Manually release C++ memory to prevent SIGSEGV leaks.
  void dispose() {
    _mlSession?.release();
  }

  /// Generates a feature embedding vector from a cropped face image using arcface.onnx
  Future<List<double>> vectorizeFace(Uint8List croppedFaceBytes) async {
    if (!_isInitialized || _mlSession == null) {
      throw Exception("FaceMatchEngine is not initialized. Call initialize() first.");
    }

    // Typical arcface input is 112x112
    final inputSize = 112;
    
    final tensorBuffer = await Isolate.run(() {
      print("[Face Match Engine] Background Isolate: Decoding and resizing image to \${inputSize}x\${inputSize}...");
      
      final decodedImage = img.decodeImage(croppedFaceBytes);
      if (decodedImage == null) throw Exception("Failed to decode cropped face image bytes.");

      final resizedImage = img.copyResize(decodedImage, width: inputSize, height: inputSize);

      var buffer = Float32List(1 * 3 * inputSize * inputSize);
      int pixelIndex = 0;
      
      for (int y = 0; y < inputSize; y++) {
        for (int x = 0; x < inputSize; x++) {
          final pixel = resizedImage.getPixel(x, y);
          // Normalizing pixel value distribution depending on specific arcface standards 
          // Frequently: (pixel - 127.5) / 128.0
          buffer[pixelIndex] = (pixel.r - 127.5) / 128.0; 
          buffer[inputSize * inputSize + pixelIndex] = (pixel.g - 127.5) / 128.0; 
          buffer[2 * inputSize * inputSize + pixelIndex] = (pixel.b - 127.5) / 128.0; 
          pixelIndex++;
        }
      }
      return buffer;
    });

    final shape = [1, 3, inputSize, inputSize];
    final inputTensor = OrtValueTensor.createTensorWithDataList(tensorBuffer, shape);
    final runOptions = OrtRunOptions();
    
    List<double> faceVector = [];

    try {
      // Modify 'data' to exactly match the input node name of arcface.onnx
      final inputs = {'data': inputTensor};
      final outputs = _mlSession!.run(runOptions, inputs);
      
      if (outputs.isNotEmpty) {
        final outputTensor = outputs[0];
        if (outputTensor?.value is List) {
           final vectorList = outputTensor?.value as List;
           if (vectorList.isNotEmpty && vectorList.first is List) {
             faceVector = (vectorList.first as List).map((e) => (e as num).toDouble()).toList();
           }
        }
      }
      
      // CRITICAL: Prevent ONNX memory leak
      for (var out in outputs) {
        out?.release();
      }
    } catch (e) {
      print("[Face Match Engine] ONNX Inference Error: \$e");
    } finally {
      inputTensor.release();
      runOptions.release();
    }

    return faceVector;
  }

  /// Calculates cosine similarity between two face feature vectors
  Future<double> compareVectors(List<double> referenceVector, List<double> targetVector) async {
    return await Isolate.run(() {
      if (referenceVector.isEmpty || targetVector.isEmpty || referenceVector.length != targetVector.length) {
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
