import 'dart:async';
import 'dart:isolate';
import 'dart:typed_data';
import 'package:flutter/services.dart' show rootBundle;
import 'package:image/image.dart' as img;
import 'package:onnxruntime/onnxruntime.dart';

class PassiveLivenessEngine {
  OrtSession? _mlSession;
  bool _isInitialized = false;

  /// Initializes the minifasnet ONNX model from the assets directory.
  Future<void> initialize() async {
    try {
      OrtEnv.instance.init();
      final sessionOptions = OrtSessionOptions();
      final rawAssetFile = await rootBundle.load('assets/models/minifasnet.onnx');
      _mlSession = OrtSession.fromBuffer(rawAssetFile.buffer.asUint8List(), sessionOptions);
      _isInitialized = true;
      print("[Passive Liveness Engine] ONNX Model initialized.");
    } catch (e) {
      print("[Passive Liveness Engine] Failed to initialize model: \$e");
    }
  }

  /// Manually release C++ memory to prevent SIGSEGV leaks.
  void dispose() {
    _mlSession?.release();
    OrtEnv.instance.release();
  }

  /// Evaluates a cropped face image utilizing the minifasnet model.
  Future<double> checkLiveness(Uint8List croppedFaceBytes) async {
    if (!_isInitialized || _mlSession == null) {
      throw Exception("PassiveLivenessEngine is not initialized. Call initialize() first.");
    }

    // 1. Threaded Image Preprocessing 
    // This is the CPU heavy part, offloaded to a background isolate.
    final inputSize = 80;
    final tensorBuffer = await Isolate.run(() {
      print("[Passive Liveness Engine] Background Isolate: Decoding and resizing image to \${inputSize}x\${inputSize}...");
      
      final decodedImage = img.decodeImage(croppedFaceBytes);
      if (decodedImage == null) throw Exception("Failed to decode cropped face image bytes.");

      final resizedImage = img.copyResize(decodedImage, width: inputSize, height: inputSize);

      var buffer = Float32List(1 * 3 * inputSize * inputSize);
      int pixelIndex = 0;
      
      for (int y = 0; y < inputSize; y++) {
        for (int x = 0; x < inputSize; x++) {
          final pixel = resizedImage.getPixel(x, y);
          buffer[pixelIndex] = pixel.r / 255.0; 
          buffer[inputSize * inputSize + pixelIndex] = pixel.g / 255.0; 
          buffer[2 * inputSize * inputSize + pixelIndex] = pixel.b / 255.0; 
          pixelIndex++;
        }
      }
      return buffer;
    });

    // 2. Run ONNX Inference
    // OrtSession.run uses FFI. Since minifasnet is extremely fast (<10ms), running on main thread 
    // shouldn't drop frames. If using a larger model, we would use a persistent Isolate to hold the session.
    final shape = [1, 3, inputSize, inputSize];
    final inputTensor = OrtValueTensor.createTensorWithDataList(tensorBuffer, shape);
    final runOptions = OrtRunOptions();
    
    double livenessScore = 0.0;
    
    try {
      // Modify 'input_1' to exactly match the input node name of minifasnet.onnx
      final inputs = {'input_1': inputTensor};
      final outputs = _mlSession!.run(runOptions, inputs);
      
      // Parse output logits
      if (outputs.isNotEmpty) {
        final outputTensor = outputs[0];
        if (outputTensor?.value is List) {
           final logits = outputTensor?.value as List;
           if (logits.isNotEmpty && logits.first is List) {
             // Example extraction logic (depends entirely on the model architecture)
             livenessScore = logits.first[0].toDouble(); 
           }
        }
      }
      
      // CRITICAL: Prevent ONNX memory leak (SIGSEGV) by strictly releasing all returned OrtValues
      for (var out in outputs) {
        out?.release();
      }
    } catch (e) {
      print("[Passive Liveness Engine] ONNX Inference Error: \$e");
    } finally {
      // CRITICAL: Must release input tensors and options to prevent unmanaged C++ memory leak
      inputTensor.release();
      runOptions.release();
    }

    return livenessScore; 
  }
}
