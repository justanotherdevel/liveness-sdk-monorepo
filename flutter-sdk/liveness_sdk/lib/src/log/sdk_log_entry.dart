/// Represents a single SDK event that will be persisted locally
/// and eventually synced to the server.
library;

/// Whether the authentication decision was made on-device (edge)
/// or required the server fallback.
enum ExecutionMode { edge, server }

/// Sync status of a log entry.
enum SyncStatus { pending, synced, failed }

class SdkLogEntry {
  final String requestId; // UUID — unique per event
  final String deviceId; // Persistent per-device UUID
  final DateTime timestamp;
  final String method; // 'init' | 'enroll' | 'authenticate'
  final ExecutionMode executionMode;
  final Map<String, dynamic>? parameters;
  final Map<String, dynamic>? result;
  final String? errors;
  SyncStatus syncStatus;
  DateTime? syncedAt;

  SdkLogEntry({
    required this.requestId,
    required this.deviceId,
    required this.timestamp,
    required this.method,
    required this.executionMode,
    this.parameters,
    this.result,
    this.errors,
    this.syncStatus = SyncStatus.pending,
    this.syncedAt,
  });

  Map<String, dynamic> toMap() => {
    'request_id': requestId,
    'device_id': deviceId,
    'timestamp': timestamp.toIso8601String(),
    'method': method,
    'execution_mode': executionMode.name,
    'parameters': parameters?.toString(),
    'result': result?.toString(),
    'errors': errors,
    'sync_status': syncStatus.name,
    'synced_at': syncedAt?.toIso8601String(),
  };

  /// Shape expected by the backend /sync_logs endpoint.
  Map<String, dynamic> toSyncPayload() => {
    'request_id': requestId,
    'device_id': deviceId,
    'timestamp': timestamp.toIso8601String(),
    'method': method,
    'execution_mode': executionMode.name,
    'parameters': parameters,
    'result': result,
    'errors': errors,
  };

  factory SdkLogEntry.fromMap(Map<String, dynamic> map) => SdkLogEntry(
    requestId: map['request_id'] as String,
    deviceId: map['device_id'] as String,
    timestamp: DateTime.parse(map['timestamp'] as String),
    method: map['method'] as String,
    executionMode: ExecutionMode.values.firstWhere(
      (e) => e.name == map['execution_mode'],
      orElse: () => ExecutionMode.edge,
    ),
    parameters: map['parameters'] != null ? {'raw': map['parameters']} : null,
    result: map['result'] != null ? {'raw': map['result']} : null,
    errors: map['errors'] as String?,
    syncStatus: SyncStatus.values.firstWhere(
      (s) => s.name == map['sync_status'],
      orElse: () => SyncStatus.pending,
    ),
    syncedAt: map['synced_at'] != null
        ? DateTime.tryParse(map['synced_at'] as String)
        : null,
  );
}
