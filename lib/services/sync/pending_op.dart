import 'package:uuid/uuid.dart';

/// Kind of mutation queued in the outbox. Mapped 1:1 to backend endpoint
/// shape so the drainer doesn't need to inspect the payload to dispatch.
enum PendingOpKind {
  upsertWriting, // POST /api/writings/  (isNew=true) or PUT /api/writings/{id}
  deleteWriting, // DELETE /api/writings/{id}
  upsertSection, // POST /api/writings/{wid}/sections (isNew=true) or PUT /api/writings/{wid}/sections/{sid}
  deleteSection, // DELETE /api/writings/{wid}/sections/{sid}
}

PendingOpKind _kindFromString(String s) =>
    PendingOpKind.values.firstWhere((e) => e.name == s);

const _uuid = Uuid();

/// A queued mutation that the [Outbox] persists across app launches and the
/// [OutboxDrainer] eventually pushes to the backend.
///
/// `id` is the client-generated op id (sent to the server as `clientOpId`
/// for idempotency once that's wired up; today the server ignores it but
/// the value is durable so resumed drains can reference past attempts).
///
/// `attemptCount` and `lastError` are mutated in place by the drainer so
/// the persisted state reflects retry history.
class PendingOp {
  PendingOp({
    String? id,
    required this.kind,
    required this.payload,
    DateTime? createdAt,
    this.attemptCount = 0,
    this.lastError,
  })  : id = id ?? _uuid.v4(),
        createdAt = createdAt ?? DateTime.now();

  final String id;
  final PendingOpKind kind;
  final Map<String, dynamic> payload;
  final DateTime createdAt;
  int attemptCount;
  String? lastError;

  PendingOp copyWith({
    Map<String, dynamic>? payload,
    int? attemptCount,
    String? lastError,
  }) =>
      PendingOp(
        id: id,
        kind: kind,
        payload: payload ?? this.payload,
        createdAt: createdAt,
        attemptCount: attemptCount ?? this.attemptCount,
        lastError: lastError ?? this.lastError,
      );

  Map<String, dynamic> toJson() => {
        'id': id,
        'kind': kind.name,
        'payload': payload,
        'createdAt': createdAt.toIso8601String(),
        'attemptCount': attemptCount,
        if (lastError != null) 'lastError': lastError,
      };

  factory PendingOp.fromJson(Map<String, dynamic> json) => PendingOp(
        id: json['id'] as String,
        kind: _kindFromString(json['kind'] as String),
        payload: Map<String, dynamic>.from(json['payload'] as Map),
        createdAt: DateTime.parse(json['createdAt'] as String),
        attemptCount: (json['attemptCount'] as num?)?.toInt() ?? 0,
        lastError: json['lastError'] as String?,
      );

  @override
  String toString() =>
      'PendingOp(${kind.name}, id=$id, attempts=$attemptCount)';
}
