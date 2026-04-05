import 'dart:async';
import 'dart:io';
import 'dart:isolate';
import 'dart:math' show exp;
import 'package:flutter/foundation.dart';
import 'package:image/image.dart' as img;
import 'package:onnxruntime/onnxruntime.dart';

class PassiveLivenessEngine {
  OrtSession? _mlSession;
  bool _isInitialized = false;

  /// Initializes the minifasnet ONNX model from a local [modelFile].
  /// The file is obtained from [ModelDownloadService.getModelFile].
  Future<void> initialize(File modelFile) async {
    try {
      OrtEnv.instance.init();
      final sessionOptions = OrtSessionOptions();
      _mlSession = OrtSession.fromBuffer(
        await modelFile.readAsBytes(),
        sessionOptions,
      );
      _isInitialized = true;
      debugPrint('[Passive Liveness Engine] ONNX Model initialized from ${modelFile.path}.');
    } catch (e, stackTrace) {
      debugPrint('[Passive Liveness Engine] Failed to initialize model: $e');
      debugPrint('[Passive Liveness Engine] Stack trace: $stackTrace');
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
      throw Exception(
        "PassiveLivenessEngine is not initialized. Call initialize() first.",
      );
    }

    // 1. Threaded Image Preprocessing
    // This is the CPU heavy part, offloaded to a background isolate.
    final inputSize = 128;
    final tensorBuffer = await Isolate.run(() {
      debugPrint(
        "[Passive Liveness Engine] Background Isolate: Decoding and resizing image to ${inputSize}x$inputSize...",
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
    final inputTensor = OrtValueTensor.createTensorWithDataList(
      tensorBuffer,
      shape,
    );
    final runOptions = OrtRunOptions();

    double livenessScore = 0.0;

    try {
      final inputs = {'input': inputTensor};
      final outputs = _mlSession!.run(runOptions, inputs);

      // Parse output logits: model outputs [N, 2] where idx 0=spoof, idx 1=live
      if (outputs.isNotEmpty) {
        final outputTensor = outputs[0];
        if (outputTensor?.value is List) {
          final logits = outputTensor?.value as List;
          if (logits.isNotEmpty && logits.first is List) {
            final row = logits.first as List;
            final double liveLogit = (row[0] as num).toDouble();
            final double spoofLogit = (row[1] as num).toDouble();

            // Softmax to convert logits to probabilities
            final double maxLogit = spoofLogit > liveLogit
                ? spoofLogit
                : liveLogit;
            final double expSpoof = exp(spoofLogit - maxLogit);
            final double expLive = exp(liveLogit - maxLogit);
            livenessScore = expLive / (expSpoof + expLive);

            debugPrint(
              "[Passive Liveness Engine] Logits: live=$liveLogit, spoof=$spoofLogit => liveness=$livenessScore",
            );
          }
        }
      }

      // CRITICAL: Prevent ONNX memory leak (SIGSEGV) by strictly releasing all returned OrtValues
      for (var out in outputs) {
        out?.release();
      }
    } catch (e) {
      debugPrint("[Passive Liveness Engine] ONNX Inference Error: $e");
    } finally {
      // CRITICAL: Must release input tensors and options to prevent unmanaged C++ memory leak
      inputTensor.release();
      runOptions.release();
    }

    return livenessScore;
  }
}
