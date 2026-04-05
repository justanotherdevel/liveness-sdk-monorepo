import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:http/http.dart' as http;
import 'package:path_provider/path_provider.dart';

import 'engines/face_extraction_engine.dart';
import 'engines/passive_liveness_engine.dart';
import 'engines/face_match_engine.dart';
import 'log/local_log_store.dart';
import 'log/log_sync_service.dart';
import 'log/sdk_log_entry.dart';
import 'model_download_service.dart';

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

  late final LocalLogStore _logStore;
  late final LogSyncService _logSync;

  final String _serverBaseUrl = "http://shashwatdesktop.lan:8000";
  String? _apiKey;

  // Private constructor
  LiveFaceAuth._();

  /// Initializes the SDK, downloads models if needed, validates the API key,
  /// and sets up local logging.
  static Future<LiveFaceAuth> initialize({required String apiKey}) async {
    final sdk = LiveFaceAuth._();
    sdk._apiKey = apiKey;

    sdk._extractionEngine = FaceExtractionEngine();
    sdk._passiveLivenessEngine = PassiveLivenessEngine();
    sdk._faceMatchEngine = FaceMatchEngine();

    // Set up local log store + sync service before anything else
    sdk._logStore = LocalLogStore();
    await sdk._logStore.init();
    sdk._logSync = LogSyncService(
      store: sdk._logStore,
      serverBaseUrl: sdk._serverBaseUrl,
      apiKey: apiKey,
    );

    // Download (or verify) ONNX models from the server
    debugPrint('[LiveFaceAuth] Ensuring models are up-to-date…');
    final downloader = ModelDownloadService(
      serverBaseUrl: sdk._serverBaseUrl,
      apiKey: apiKey,
    );
    await downloader.ensureModelsReady();

    // Initialize ML engines with downloaded model files
    await sdk._passiveLivenessEngine.initialize(
      await downloader.getModelFile('minifasnet.onnx'),
    );
    await sdk._faceMatchEngine.initialize(
      await downloader.getModelFile('mobilefacenet.onnx'),
    );

    // Validate API key (online check with offline cache fallback)
    await sdk._validateKey(apiKey);

    // Log the init event and trigger a sync of any pending entries
    await sdk._logSync.logEvent(
      method: 'init',
      executionMode: ExecutionMode.edge,
      result: {'sdk_version': '0.0.1'},
    );

    return sdk;
  }

  // ── Key validation ────────────────────────────────────────────────────────

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
            final reason = data['message'] ?? 'invalid or inactive';
            throw Exception("API Key rejected by server: $reason");
          }
        } else {
          throw Exception(
            "API Key validation failed with status ${response.statusCode}",
          );
        }
      } on SocketException catch (e) {
        if (lastValidation == null) {
          throw Exception(
            "No network and no previously validated key. Cannot initialize SDK.",
          );
        }
        debugPrint(
          "[LiveFaceAuth] Network unavailable, using cached key validation: $e",
        );
      } on http.ClientException catch (e) {
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

  // ── Temp file helper ──────────────────────────────────────────────────────

  Future<String> _writeBase64ToTempFile(String base64String) async {
    final tempDir = await getTemporaryDirectory();
    final tempFile = File(
      '${tempDir.path}/lfa_tmp_${DateTime.now().millisecondsSinceEpoch}.jpg',
    );
    await tempFile.writeAsBytes(base64Decode(base64String));
    return tempFile.path;
  }

  // ── Public API ────────────────────────────────────────────────────────────

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
      return livenessScore > 0.8;
    } finally {
      File(tempFilePath).deleteSync();
    }
  }

  /// Headless Face Enrollment
  Future<EnrollResult> enrollFaceImage({
    required String imageBase64,
    bool saveReference = false,
  }) async {
    final tempFilePath = await _writeBase64ToTempFile(imageBase64);

    try {
      final croppedFace = await _extractionEngine.extractFaceFromFile(
        filePath: tempFilePath,
      );
      if (croppedFace == null) {
        await _logSync.logEvent(
          method: 'enroll',
          executionMode: ExecutionMode.edge,
          result: {'success': false, 'reason': 'no_face_detected'},
        );
        return EnrollResult();
      }

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

      await _logSync.logEvent(
        method: 'enroll',
        executionMode: ExecutionMode.edge,
        parameters: {'save_reference': saveReference},
        result: {'success': true, 'vector_dim': faceVector.length},
      );

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

    bool? activeLivenessResult;
    bool? passiveLivenessResult;

    // Load reference from storage or extract from provided image
    if (useReference) {
      final savedImage = await _storage.read(key: "saved_reference_image");
      final savedVectorStr = await _storage.read(key: "saved_reference_vector");
      if (savedImage != null && savedVectorStr != null) {
        refCropped = base64Decode(savedImage);
        final List<dynamic> decoded = jsonDecode(savedVectorStr);
        refVector = decoded.map((e) => (e as num).toDouble()).toList();
      } else {
        await _logSync.logEvent(
          method: 'authenticate',
          executionMode: ExecutionMode.edge,
          result: <String, dynamic>{
            'success': false,
            'reason': 'no_enrolled_reference',
          },
        );
        return FaceAuthResult(success: false, strong: false);
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
      await _logSync.logEvent(
        method: 'authenticate',
        executionMode: ExecutionMode.edge,
        result: {'success': false, 'reason': 'reference_extraction_failed'},
      );
      return FaceAuthResult(success: false, strong: false);
    }

    final tempFilePath = await _writeBase64ToTempFile(targetImageBase64);
    try {
      // Single detection pass → tight crop (ArcFace) + wide crop (MiniFASNet)
      final extraction = await _extractionEngine.extractDualCropFromFile(
        filePath: tempFilePath,
      );

      final targetCropped = extraction.tightCrop;
      final livenessCrop = extraction.livenessCrop;

      if (targetCropped == null || livenessCrop == null) {
        debugPrint("[LiveFaceAuth] No face detected in target image.");
        await _logSync.logEvent(
          method: 'authenticate',
          executionMode: ExecutionMode.edge,
          result: {'success': false, 'reason': 'no_face_in_target'},
        );
        return FaceAuthResult(success: false);
      }

      // --- DEBUG: Save crops ---
      if (kDebugMode) {
        final docsDir = await getApplicationDocumentsDirectory();
        final ts = DateTime.now().millisecondsSinceEpoch;
        await File(
          '${docsDir.path}/debug_ref_$ts.jpg',
        ).writeAsBytes(refCropped);
        await File(
          '${docsDir.path}/debug_tgt_tight_$ts.jpg',
        ).writeAsBytes(targetCropped);
        await File(
          '${docsDir.path}/debug_tgt_liveness_$ts.jpg',
        ).writeAsBytes(livenessCrop);
        debugPrint(
          '[LiveFaceAuth][DEBUG] Debug crops saved to docs dir at ts=$ts',
        );
      }

      // Step 2: Passive Liveness — uses the WIDE 2.7× crop
      if (passiveLiveness) {
        final score = await _passiveLivenessEngine.checkLiveness(livenessCrop);
        passiveLivenessResult = score > 0.8;
        debugPrint(
          "[LiveFaceAuth] Passive liveness score: $score => passed: $passiveLivenessResult",
        );

        if (!passiveLivenessResult && !proceedIfLivenessFail) {
          debugPrint("[LiveFaceAuth] Spoof detected. Returning early.");
          await _logSync.logEvent(
            method: 'authenticate',
            executionMode: ExecutionMode.edge,
            parameters: {'liveness_check': true},
            result: {
              'success': false,
              'reason': 'spoof_detected',
              'liveness_score': score,
            },
          );
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
        debugPrint("[LiveFaceAuth] Local match PASSED. (edge decision)");
        await _logSync.logEvent(
          method: 'authenticate',
          executionMode: ExecutionMode.edge,
          parameters: {
            'threshold': threshold,
            'liveness_check': passiveLiveness,
          },
          result: {
            'success': true,
            'similarity': similarity,
            'passive_liveness': passiveLivenessResult,
          },
        );
        return FaceAuthResult(
          success: true,
          strong: true,
          passiveLivenessResult: passiveLivenessResult,
          activeLivenessResult: activeLivenessResult,
        );
      }

      // Step 4: Server fallback (edge failed, escalate to server)
      debugPrint(
        "[LiveFaceAuth] Local match failed ($similarity < $threshold). Falling back to server...",
      );
      final fallbackResult = await _serverFallbackCompare(
        refCropped,
        targetCropped,
      );
      debugPrint(
        "[LiveFaceAuth] Server fallback result: success=${fallbackResult.success}",
      );

      // Log with executionMode=server since the server made the final call
      await _logSync.logEvent(
        method: 'authenticate',
        executionMode: ExecutionMode.server,
        parameters: {
          'threshold': threshold,
          'local_similarity': similarity,
          'liveness_check': passiveLiveness,
        },
        result: {
          'success': fallbackResult.success,
          'strong': fallbackResult.strong,
          'passive_liveness': passiveLivenessResult,
        },
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

  // ── Server fallback ───────────────────────────────────────────────────────

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
        return FaceAuthResult(success: data['success'] ?? false, strong: true);
      } else {
        final respStr = await response.stream.bytesToString();
        debugPrint("[LiveFaceAuth] Server fallback error body: $respStr");
      }
    } catch (e) {
      debugPrint("[LiveFaceAuth] Server fallback exception: $e");
      return FaceAuthResult(success: false, strong: false);
    }
    return FaceAuthResult(success: false, strong: false);
  }
}
