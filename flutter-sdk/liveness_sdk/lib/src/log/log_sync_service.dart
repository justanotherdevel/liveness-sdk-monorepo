import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;
import 'package:uuid/uuid.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';

import 'local_log_store.dart';
import 'sdk_log_entry.dart';

/// Handles fire-and-forget background sync of local log entries to the server.
///
/// Usage:
///   - Call [scheduleSync] after any SDK operation.
///   - It runs async (unawaited) and never throws — callers don't care.
///   - Only dispatches if there are pending entries AND network is reachable.
///
/// Device identity:
///   - A persistent UUID is generated on first run and stored in secure storage.
///   - It never changes, giving each device a stable identity across sessions.
class LogSyncService {
  final LocalLogStore _store;
  final String _serverBaseUrl;
  final String _apiKey;
  final FlutterSecureStorage _secureStorage;

  static const _uuid = Uuid();
  static const _deviceIdKey = 'sdk_device_id';

  String? _deviceId;
  bool _syncInProgress = false;

  LogSyncService({
    required LocalLogStore store,
    required String serverBaseUrl,
    required String apiKey,
    FlutterSecureStorage? secureStorage,
  }) : _store = store,
       _serverBaseUrl = serverBaseUrl,
       _apiKey = apiKey,
       _secureStorage = secureStorage ?? const FlutterSecureStorage();

  // ── Device ID ─────────────────────────────────────────────────────────────

  /// Returns (or lazily creates) the persistent device UUID.
  Future<String> getDeviceId() async {
    if (_deviceId != null) return _deviceId!;
    String? stored = await _secureStorage.read(key: _deviceIdKey);
    if (stored == null) {
      stored = _uuid.v4();
      await _secureStorage.write(key: _deviceIdKey, value: stored);
      debugPrint('[LogSyncService] Generated new device ID: $stored');
    }
    _deviceId = stored;
    return _deviceId!;
  }

  // ── Entry creation helper ─────────────────────────────────────────────────

  /// Creates a new [SdkLogEntry], writes it to the local store, then
  /// schedules a sync. Returns the entry so callers can extend it if needed.
  Future<SdkLogEntry> logEvent({
    required String method,
    required ExecutionMode executionMode,
    Map<String, dynamic>? parameters,
    Map<String, dynamic>? result,
    String? errors,
  }) async {
    final entry = SdkLogEntry(
      requestId: _uuid.v4(),
      deviceId: await getDeviceId(),
      timestamp: DateTime.now().toUtc(),
      method: method,
      executionMode: executionMode,
      parameters: parameters,
      result: result,
      errors: errors,
    );
    await _store.insert(entry);
    debugPrint(
      '[LogSyncService] Logged event: method=${entry.method} '
      'mode=${entry.executionMode.name} rid=${entry.requestId}',
    );
    scheduleSync(); // fire-and-forget
    return entry;
  }

  // ── Sync ──────────────────────────────────────────────────────────────────

  /// Schedules a background sync. Safe to call anywhere — never throws.
  /// If a sync is already running, this is a no-op.
  void scheduleSync() {
    if (_syncInProgress) return;
    // ignore: discarded_futures
    _trySyncAsync();
  }

  Future<void> _trySyncAsync() async {
    _syncInProgress = true;
    try {
      if (!await _isOnline()) {
        debugPrint('[LogSyncService] Offline — skipping sync.');
        return;
      }
      final pending = await _store.getPendingEntries();
      if (pending.isEmpty) {
        debugPrint('[LogSyncService] No pending entries to sync.');
        return;
      }
      debugPrint('[LogSyncService] Syncing ${pending.length} entries...');
      await _uploadEntries(pending);
    } catch (e) {
      debugPrint('[LogSyncService] Sync failed: $e');
    } finally {
      _syncInProgress = false;
    }
  }

  Future<void> _uploadEntries(List<SdkLogEntry> entries) async {
    final payload = jsonEncode({
      'api_key': _apiKey,
      'logs': entries.map((e) => e.toSyncPayload()).toList(),
    });

    late http.Response response;
    try {
      response = await http
          .post(
            Uri.parse('$_serverBaseUrl/sync_logs'),
            headers: {'Content-Type': 'application/json'},
            body: payload,
          )
          .timeout(const Duration(seconds: 15));
    } on SocketException {
      debugPrint('[LogSyncService] Network error during upload.');
      return; // will retry next scheduleSync call
    }

    if (response.statusCode == 200) {
      final ids = entries.map((e) => e.requestId).toList();
      await _store.markSynced(ids);
      debugPrint('[LogSyncService] ✓ Synced ${ids.length} entries.');
    } else {
      debugPrint(
        '[LogSyncService] Server returned ${response.statusCode} — '
        'entries remain pending.',
      );
    }
  }

  // ── Connectivity ──────────────────────────────────────────────────────────

  /// Lightweight connectivity check via DNS lookup.
  /// Avoids the connectivity_plus dependency.
  Future<bool> _isOnline() async {
    try {
      final result = await InternetAddress.lookup(
        'google.com',
      ).timeout(const Duration(seconds: 4));
      return result.isNotEmpty && result.first.rawAddress.isNotEmpty;
    } catch (_) {
      return false;
    }
  }
}
