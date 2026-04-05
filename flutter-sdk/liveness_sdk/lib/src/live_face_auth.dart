import 'dart:convert';
import 'dart:io';
import 'package:flutter/foundation.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:http/http.dart' as http;
import 'package:path_provider/path_provider.dart';

import 'engines/face_extraction_engine.dart';
import 'engines/passive_liveness_engine.dart';
import 'engines/face_match_engine.dart';

class FaceAuthResult {
  final bool success;
  final bool strong;
  final bool? passiveLivenessResult;
  final bool? activeLivenessResult;

  FaceAuthResult({
    required this.success,
    this.strong = true,
    this.passiveLivenessResult,
    this.activeLivenessResult,
  });
}

class EnrollResult {
  final Uint8List? croppedFace;
  final List<double>? faceVector;

  EnrollResult({this.croppedFace, this.faceVector});
}

class LiveFaceAuth {
  final FlutterSecureStorage _storage = const FlutterSecureStorage();

  late final FaceExtractionEngine _extractionEngine;
  late final PassiveLivenessEngine _passiveLivenessEngine;
  late final FaceMatchEngine _faceMatchEngine;

  final String _serverBaseUrl =
      "http://192.168.88.7:8000"; // Changed to local IP as per user configuration
  String? _apiKey;

  // Private constructor
  LiveFaceAuth._();

  /// Initializes the SDK and validates the API key offline/online appropriately.
  static Future<LiveFaceAuth> initialize({required String apiKey}) async {
    final sdk = LiveFaceAuth._();
    sdk._apiKey = apiKey;

    sdk._extractionEngine = FaceExtractionEngine();
    sdk._passiveLivenessEngine = PassiveLivenessEngine();
    sdk._faceMatchEngine = FaceMatchEngine();

    // Initialize models
    await sdk._passiveLivenessEngine.initialize();
    await sdk._faceMatchEngine.initialize();

    // API Key caching and validation logic
    await sdk._validateKey(apiKey);

    return sdk;
  }

  Future<void> _validateKey(String apiKey) async {
    final lastValidation = await _storage.read(key: "key_validated_at");
    bool needsValidation = true;

    if (lastValidation != null) {
      final lastDate = DateTime.tryParse(lastValidation);
      if (lastDate != null && DateTime.now().difference(lastDate).inDays < 1) {
        needsValidation = false;
      }
    }

    if (needsValidation) {
      try {
        final response = await http.post(
          Uri.parse("$_serverBaseUrl/validate_key"),
          headers: {"Content-Type": "application/json"},
          body: jsonEncode({"api_key": apiKey}),
        );
        if (response.statusCode == 200) {
          final data = jsonDecode(response.body);
          if (data['is_valid'] == true) {
            await _storage.write(
              key: "key_validated_at",
              value: DateTime.now().toIso8601String(),
            );
          } else {
            // Server responded but explicitly rejected the key — hard fail.
            final reason = data['message'] ?? 'invalid or inactive';
            throw Exception("API Key rejected by server: $reason");
          }
        } else {
          // Non-200 from validate_key endpoint — treat as hard fail.
          throw Exception(
            "API Key validation failed with status ${response.statusCode}",
          );
        }
      } on SocketException catch (e) {
        // Network unreachable — use cached validation if available.
        if (lastValidation == null) {
          throw Exception(
            "No network and no previously validated key. Cannot initialize SDK.",
          );
        }
        debugPrint(
          "[LiveFaceAuth] Network unavailable, using cached key validation: $e",
        );
      } on http.ClientException catch (e) {
        // HTTP-level connectivity error — same offline fallback.
        if (lastValidation == null) {
          throw Exception(
            "No network and no previously validated key. Cannot initialize SDK.",
          );
        }
        debugPrint(
          "[LiveFaceAuth] HTTP error during key validation, using cache: $e",
        );
      }
    }
  }

  Future<String> _writeBase64ToTempFile(String base64String) async {
    final tempDirPath = (await getTemporaryDirectory()).path;
    final tempFile = File(
      "$tempDirPath/temp_${DateTime.now().microsecondsSinceEpoch}.jpg",
    );
    await tempFile.writeAsBytes(base64Decode(base64String));
    return tempFile.path;
  }

  /// Check Passive Liveness from a Base64 string directly
  Future<bool> checkPassiveLiveness({required String imageBase64}) async {
    final tempFilePath = await _writeBase64ToTempFile(imageBase64);

    try {
      final croppedFace = await _extractionEngine.extractFaceFromFile(
        filePath: tempFilePath,
      );
      if (croppedFace == null) return false;

      final livenessScore = await _passiveLivenessEngine.checkLiveness(
        croppedFace,
      );
      return livenessScore > 0.8; // Configurable safe threshold
    } finally {
      // Clean up storage
      File(tempFilePath).deleteSync();
    }
  }

  /// Headless Face Enrollment logic
  Future<EnrollResult> enrollFaceImage({
    required String imageBase64,
    bool saveReference = false,
  }) async {
    final tempFilePath = await _writeBase64ToTempFile(imageBase64);

    try {
      final croppedFace = await _extractionEngine.extractFaceFromFile(
        filePath: tempFilePath,
      );
      if (croppedFace == null) return EnrollResult();

      final faceVector = await _faceMatchEngine.vectorizeFace(croppedFace);

      if (saveReference) {
        await _storage.write(
          key: "saved_reference_image",
          value: base64Encode(croppedFace),
        );
        await _storage.write(
          key: "saved_reference_vector",
          value: jsonEncode(faceVector),
        );
      }

      return EnrollResult(croppedFace: croppedFace, faceVector: faceVector);
    } finally {
      File(tempFilePath).deleteSync();
    }
  }

  /// Clears saved reference entirely
  Future<void> clearReference() async {
    await _storage.delete(key: "saved_reference_image");
    await _storage.delete(key: "saved_reference_vector");
  }

  /// Checks if a reference face is currently enrolled/saved in secure storage
  Future<bool> isFaceEnrolled() async {
    final savedImage = await _storage.read(key: "saved_reference_image");
    final savedVectorStr = await _storage.read(key: "saved_reference_vector");
    return savedImage != null && savedVectorStr != null;
  }

  /// Full Headless Facial Auth Pipeline
  Future<FaceAuthResult> checkFaceAuth({
    String? referenceImageBase64,
    bool useReference = false,
    required String targetImageBase64,
    bool passiveLiveness = true,
    double threshold = 0.80,
    bool proceedIfLivenessFail = false,
  }) async {
    Uint8List? refCropped;
    List<double>? refVector;

    bool?
    activeLivenessResult; // Passed internally if integrated into UI streams
    bool? passiveLivenessResult;

    // Load from storage or extract fresh
    if (useReference) {
      final savedImage = await _storage.read(key: "saved_reference_image");
      final savedVectorStr = await _storage.read(key: "saved_reference_vector");
      if (savedImage != null && savedVectorStr != null) {
        refCropped = base64Decode(savedImage);
        final List<dynamic> decoded = jsonDecode(savedVectorStr);
        refVector = decoded.map((e) => (e as num).toDouble()).toList();
      } else {
        return FaceAuthResult(
          success: false,
          strong: false,
        ); // No securely saved reference available
      }
    } else if (referenceImageBase64 != null) {
      final enrollResult = await enrollFaceImage(
        imageBase64: referenceImageBase64,
        saveReference: false,
      );
      refCropped = enrollResult.croppedFace;
      refVector = enrollResult.faceVector;
    }

    if (refCropped == null || refVector == null) {
      return FaceAuthResult(
        success: false,
        strong: false,
      ); // Failed to generate reference
    }

    final tempFilePath = await _writeBase64ToTempFile(targetImageBase64);
    try {
      // Single detection pass, two crops:
      //  - tightCrop (1.2×) → ArcFace identity matching
      //  - livenessCrop (2.7×) → MiniFASNet spoofing detection
      final extraction = await _extractionEngine.extractDualCropFromFile(
        filePath: tempFilePath,
      );

      final targetCropped = extraction.tightCrop;
      final livenessCrop = extraction.livenessCrop;

      if (targetCropped == null || livenessCrop == null) {
        debugPrint("[LiveFaceAuth] No face detected in target image.");
        return FaceAuthResult(success: false);
      }

      // --- DEBUG: Save crops to device storage ---
      if (kDebugMode) {
        final docsDir = await getApplicationDocumentsDirectory();
        final ts = DateTime.now().millisecondsSinceEpoch;
        final refPath = '${docsDir.path}/debug_ref_$ts.jpg';
        final tgtPath = '${docsDir.path}/debug_tgt_tight_$ts.jpg';
        final livPath = '${docsDir.path}/debug_tgt_liveness_$ts.jpg';
        await File(refPath).writeAsBytes(refCropped);
        await File(tgtPath).writeAsBytes(targetCropped);
        await File(livPath).writeAsBytes(livenessCrop);
        debugPrint('[LiveFaceAuth][DEBUG] Reference crop saved:      $refPath');
        debugPrint('[LiveFaceAuth][DEBUG] Target tight crop saved:   $tgtPath');
        debugPrint(
          '[LiveFaceAuth][DEBUG] Target liveness crop saved: $livPath',
        );
      }
      // -------------------------------------------

      // Step 2: Passive Liveness — uses the WIDE 2.7× crop
      if (passiveLiveness) {
        final score = await _passiveLivenessEngine.checkLiveness(livenessCrop);
        passiveLivenessResult = score > 0.8;
        debugPrint(
          "[LiveFaceAuth] Passive liveness score: $score => passed: $passiveLivenessResult",
        );

        if (!passiveLivenessResult && !proceedIfLivenessFail) {
          debugPrint("[LiveFaceAuth] Spoof detected. Returning early.");
          return FaceAuthResult(
            success: false,
            strong: false,
            passiveLivenessResult: passiveLivenessResult,
          );
        }
      }

      // Step 3: Local Face Matching — uses the TIGHT 1.2× crop
      final targetVector = await _faceMatchEngine.vectorizeFace(targetCropped);
      final similarity = await _faceMatchEngine.compareVectors(
        refVector,
        targetVector,
      );
      debugPrint(
        "[LiveFaceAuth] Local similarity score: $similarity (threshold: $threshold)",
      );

      if (similarity >= threshold) {
        debugPrint("[LiveFaceAuth] Local match PASSED.");
        return FaceAuthResult(
          success: true,
          strong: true,
          passiveLivenessResult: passiveLivenessResult,
          activeLivenessResult: activeLivenessResult,
        );
      }

      // Step 4: Fallback to FastAPI server for high-accuracy processing
      debugPrint(
        "[LiveFaceAuth] Local match failed ($similarity < $threshold). Falling back to server...",
      );
      final fallbackResult = await _serverFallbackCompare(
        refCropped,
        targetCropped,
      );
      debugPrint(
        "[LiveFaceAuth] Server fallback result: success=${fallbackResult.success}, strong=${fallbackResult.strong}",
      );
      return FaceAuthResult(
        success: fallbackResult.success,
        strong: fallbackResult.strong,
        passiveLivenessResult: passiveLivenessResult,
        activeLivenessResult: activeLivenessResult,
      );
    } finally {
      File(tempFilePath).deleteSync();
    }
  }

  // Network Fallback Integration
  Future<FaceAuthResult> _serverFallbackCompare(
    Uint8List refCropped,
    Uint8List targetCropped,
  ) async {
    try {
      final request = http.MultipartRequest(
        "POST",
        Uri.parse("$_serverBaseUrl/compare_faces"),
      );
      request.fields['api_key'] = _apiKey ?? "";
      request.fields['cropped'] = "true";

      // The FastAPI endpoint is prepared for this format
      request.files.add(
        http.MultipartFile.fromBytes(
          'reference_image',
          refCropped,
          filename: 'ref.jpg',
        ),
      );
      request.files.add(
        http.MultipartFile.fromBytes(
          'target_image',
          targetCropped,
          filename: 'tgt.jpg',
        ),
      );

      final response = await request.send();
      debugPrint(
        "[LiveFaceAuth] Server fallback response status: ${response.statusCode}",
      );
      if (response.statusCode == 200) {
        final respStr = await response.stream.bytesToString();
        final data = jsonDecode(respStr);
        debugPrint("[LiveFaceAuth] Server fallback response: $data");
        // Fallback returned final authorization decision
        return FaceAuthResult(success: data['success'] ?? false, strong: true);
      } else {
        final respStr = await response.stream.bytesToString();
        debugPrint("[LiveFaceAuth] Server fallback error body: $respStr");
      }
    } catch (e) {
      // Device offline or network failure, returning weak failure explicitly per instructions
      debugPrint("[LiveFaceAuth] Server fallback exception: $e");
      return FaceAuthResult(success: false, strong: false);
    }
    return FaceAuthResult(success: false, strong: false);
  }
}
