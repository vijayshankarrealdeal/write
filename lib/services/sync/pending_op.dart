import 'package:uuid/uuid.dart';

/// Kind of mutation queued in the outbox. Mapped 1:1 to backend endpoint
/// shape so the drainer doesn't need to inspect the payload to dispatch.
enum PendingOpKind {
  upsertWriting, // POST /api/writings/  (isNew=true) or PUT /api/writings/{id}
  deleteWriting, // DELETE /api/writings/{id}
  upsertSection, // POST /api/writings/{wid}/sections (isNew=true) or PUT /api/writings/{wid}/sections/{sid}
  deleteSection, // DELETE /api/writings/{wid}/sections/{sid}
  upsertBookmark, // POST /api/bookmarks/  (idempotent — server dedupes)
  deleteBookmark, // DELETE /api/bookmarks/{id}
  upsertAuthorBookmark, // POST /api/author-bookmarks/  (P1 #6, idempotent)
  patchAuthorBookmark, // PATCH /api/author-bookmarks/{id} — label/color/offset
  deleteAuthorBookmark, // DELETE /api/author-bookmarks/{id}
  updateWritingProject, // PUT /api/writings/{id} — Scrivener-class project fields
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
/// `attemptCount`, `lastError`, `nextAttemptAt`, and `failed` are mutated
/// in place by the drainer so the persisted state reflects retry history
/// across app restarts.
class PendingOp {
  PendingOp({
    String? id,
    required this.kind,
    required this.payload,
    DateTime? createdAt,
    this.attemptCount = 0,
    this.lastError,
    this.nextAttemptAt,
    this.failed = false,
  })  : id = id ?? _uuid.v4(),
        createdAt = createdAt ?? DateTime.now();

  final String id;
  final PendingOpKind kind;
  final Map<String, dynamic> payload;
  final DateTime createdAt;
  int attemptCount;
  String? lastError;

  /// Earliest wall-clock time the drainer should try this op. Null means
  /// "ready now". The drainer leaves later ops in place behind this one
  /// (head-of-line blocking) until the timer fires.
  DateTime? nextAttemptAt;

  /// True once `attemptCount` exceeds the drainer's cap. The drainer
  /// stops retrying; the UI is expected to surface failed ops and let
  /// the user retry (resets the flag + count) or discard.
  bool failed;

  PendingOp copyWith({
    Map<String, dynamic>? payload,
    int? attemptCount,
    String? lastError,
    DateTime? nextAttemptAt,
    bool? failed,
    bool clearNextAttempt = false,
    bool clearLastError = false,
  }) =>
      PendingOp(
        id: id,
        kind: kind,
        payload: payload ?? this.payload,
        createdAt: createdAt,
        attemptCount: attemptCount ?? this.attemptCount,
        lastError: clearLastError ? null : (lastError ?? this.lastError),
        nextAttemptAt:
            clearNextAttempt ? null : (nextAttemptAt ?? this.nextAttemptAt),
        failed: failed ?? this.failed,
      );

  Map<String, dynamic> toJson() => {
        'id': id,
        'kind': kind.name,
        'payload': payload,
        'createdAt': createdAt.toIso8601String(),
        'attemptCount': attemptCount,
        if (lastError != null) 'lastError': lastError,
        if (nextAttemptAt != null)
          'nextAttemptAt': nextAttemptAt!.toIso8601String(),
        if (failed) 'failed': true,
      };

  factory PendingOp.fromJson(Map<String, dynamic> json) => PendingOp(
        id: json['id'] as String,
        kind: _kindFromString(json['kind'] as String),
        payload: Map<String, dynamic>.from(json['payload'] as Map),
        createdAt: DateTime.parse(json['createdAt'] as String),
        attemptCount: (json['attemptCount'] as num?)?.toInt() ?? 0,
        lastError: json['lastError'] as String?,
        nextAttemptAt: json['nextAttemptAt'] is String
            ? DateTime.parse(json['nextAttemptAt'] as String)
            : null,
        failed: json['failed'] == true,
      );

  @override
  String toString() =>
      'PendingOp(${kind.name}, id=$id, attempts=$attemptCount, failed=$failed)';
}
