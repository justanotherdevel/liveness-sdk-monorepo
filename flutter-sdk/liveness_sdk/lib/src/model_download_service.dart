import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

/// Names of the ONNX models the SDK requires.
const _kModels = ['minifasnet.onnx', 'mobilefacenet.onnx'];

/// Manages downloading and caching of ONNX models from the backend server.
///
/// Models are stored in [getApplicationSupportDirectory]/liveness_models/.
/// On every [ensureModelsReady] call the service:
///   1. Fetches the server manifest (sha256 + size per model) — lightweight.
///   2. For each model, compares the local sha256 with the server's.
///   3. Downloads only models that are missing or stale.
///
/// The manifest check is skipped if the server is unreachable AND local
/// copies already exist (offline-safe).
class ModelDownloadService {
  final String serverBaseUrl;
  final String apiKey;

  ModelDownloadService({required this.serverBaseUrl, required this.apiKey});

  // ── Public API ─────────────────────────────────────────────────────────────

  /// Returns the local [File] for [modelName] after ensuring it is current.
  /// Call [ensureModelsReady] once during SDK init rather than per-model.
  Future<File> getModelFile(String modelName) async {
    final dir = await _cacheDir();
    return File(p.join(dir.path, modelName));
  }

  /// Downloads any missing or stale models.
  /// Throws if a model cannot be obtained (no local copy + server unreachable).
  Future<void> ensureModelsReady() async {
    final dir = await _cacheDir();

    Map<String, dynamic>? manifest;
    try {
      manifest = await _fetchManifest();
    } catch (e) {
      debugPrint('[ModelDownloadService] Manifest fetch failed: $e');
    }

    for (final name in _kModels) {
      final file = File(p.join(dir.path, name));
      final serverHash = (manifest?[name]?['sha256'] as String?);

      if (await _isUpToDate(file, serverHash)) {
        debugPrint('[ModelDownloadService] ✓ $name is current.');
        continue;
      }

      if (manifest == null) {
        // Server unreachable and local copy stale/missing — hard fail.
        throw Exception(
          '[ModelDownloadService] Cannot reach server to download $name '
          'and no valid local copy exists.',
        );
      }

      debugPrint('[ModelDownloadService] Downloading $name …');
      await _downloadModel(name, file);
      debugPrint('[ModelDownloadService] ✓ $name downloaded.');
    }
  }

  // ── Internals ──────────────────────────────────────────────────────────────

  Future<Directory> _cacheDir() async {
    final base = await getApplicationSupportDirectory();
    final dir = Directory(p.join(base.path, 'liveness_models'));
    if (!dir.existsSync()) dir.createSync(recursive: true);
    return dir;
  }

  Future<Map<String, dynamic>> _fetchManifest() async {
    final uri = Uri.parse(
      '$serverBaseUrl/models/manifest?api_key=$apiKey',
    );
    final response = await http.get(uri).timeout(const Duration(seconds: 10));
    if (response.statusCode != 200) {
      throw Exception('Manifest request failed: ${response.statusCode}');
    }
    return jsonDecode(response.body) as Map<String, dynamic>;
  }

  Future<void> _downloadModel(String name, File dest) async {
    final uri = Uri.parse(
      '$serverBaseUrl/models/download/$name?api_key=$apiKey',
    );
    final request = http.Request('GET', uri);
    final streamed = await request.send().timeout(
      const Duration(minutes: 5), // models can be large
    );

    if (streamed.statusCode != 200) {
      throw Exception('Download of $name failed: ${streamed.statusCode}');
    }

    final sink = dest.openWrite();
    try {
      await streamed.stream.pipe(sink);
    } finally {
      await sink.close();
    }
  }

  /// Returns true if [file] exists and its SHA256 matches [expectedSha256].
  /// If [expectedSha256] is null (manifest unavailable), existence is enough.
  Future<bool> _isUpToDate(File file, String? expectedSha256) async {
    if (!file.existsSync()) return false;
    if (expectedSha256 == null) return true; // can't verify, trust local copy
    final actual = await _sha256File(file);
    return actual == expectedSha256;
  }

  Future<String> _sha256File(File file) async {
    final bytes = await file.readAsBytes();
    return sha256.convert(bytes).toString();
  }
}
