import 'package:flutter/foundation.dart';
import 'package:sqflite/sqflite.dart';
import 'package:path/path.dart' as p;

import 'sdk_log_entry.dart';

/// SQLite-backed store for SDK log entries.
///
/// - Entries are appended as events happen (offline-safe).
/// - [getPendingEntries] returns all entries not yet acknowledged by the server.
/// - [markSynced] is called after the server confirms receipt.
class LocalLogStore {
  static const _dbName = 'liveness_sdk_logs.db';
  static const _tableName = 'sdk_logs';
  static const _version = 1;

  Database? _db;

  Future<void> init() async {
    if (_db != null) return;
    final dbPath = p.join(await getDatabasesPath(), _dbName);
    _db = await openDatabase(
      dbPath,
      version: _version,
      onCreate: (db, version) async {
        await db.execute('''
          CREATE TABLE $_tableName (
            request_id   TEXT PRIMARY KEY,
            device_id    TEXT NOT NULL,
            timestamp    TEXT NOT NULL,
            method       TEXT NOT NULL,
            execution_mode TEXT NOT NULL DEFAULT 'edge',
            parameters   TEXT,
            result       TEXT,
            errors       TEXT,
            sync_status  TEXT NOT NULL DEFAULT 'pending',
            synced_at    TEXT
          )
        ''');
        await db.execute(
          'CREATE INDEX idx_sync_status ON $_tableName(sync_status)',
        );
      },
    );
    debugPrint('[LocalLogStore] Opened DB at $dbPath');
  }

  /// Insert a new log entry. Idempotent on [requestId] (ON CONFLICT IGNORE).
  Future<void> insert(SdkLogEntry entry) async {
    await _ensureInit();
    await _db!.insert(
      _tableName,
      entry.toMap(),
      conflictAlgorithm: ConflictAlgorithm.ignore,
    );
  }

  /// Returns all entries whose [SyncStatus] is [pending] or [failed].
  Future<List<SdkLogEntry>> getPendingEntries({int limit = 100}) async {
    await _ensureInit();
    final rows = await _db!.query(
      _tableName,
      where: "sync_status IN ('pending', 'failed')",
      orderBy: 'timestamp ASC',
      limit: limit,
    );
    return rows.map(SdkLogEntry.fromMap).toList();
  }

  /// Mark [requestIds] as synced (called after server acknowledges).
  Future<void> markSynced(List<String> requestIds) async {
    if (requestIds.isEmpty) return;
    await _ensureInit();
    final placeholders = List.filled(requestIds.length, '?').join(',');
    final now = DateTime.now().toIso8601String();
    await _db!.rawUpdate(
      "UPDATE $_tableName SET sync_status='synced', synced_at=? "
      "WHERE request_id IN ($placeholders)",
      [now, ...requestIds],
    );
    debugPrint(
      '[LocalLogStore] Marked ${requestIds.length} entries as synced.',
    );
  }

  /// Mark [requestIds] as failed (server rejected them or network error).
  Future<void> markFailed(List<String> requestIds) async {
    if (requestIds.isEmpty) return;
    await _ensureInit();
    final placeholders = List.filled(requestIds.length, '?').join(',');
    await _db!.rawUpdate(
      "UPDATE $_tableName SET sync_status='failed' "
      "WHERE request_id IN ($placeholders)",
      requestIds,
    );
  }

  /// Returns count of pending entries for diagnostics.
  Future<int> pendingCount() async {
    await _ensureInit();
    final result = await _db!.rawQuery(
      "SELECT COUNT(*) as cnt FROM $_tableName WHERE sync_status IN ('pending','failed')",
    );
    return (result.first['cnt'] as int?) ?? 0;
  }

  Future<void> _ensureInit() async {
    if (_db == null) await init();
  }

  Future<void> close() async {
    await _db?.close();
    _db = null;
  }
}
