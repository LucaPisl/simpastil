import 'dart:convert';

import 'package:crypto/crypto.dart';

import '../db/database.dart';

const legacyPrnRecoveryKind = 'legacy-prn-retained-create-v1';

String legacyPrnSnapshotFingerprint(String snapshot) =>
    sha256.convert(utf8.encode(snapshot)).toString();

String legacyPrnPreimageFingerprint(Schedule row) => sha256
    .convert(
      utf8.encode(
        jsonEncode({
          'id': row.id,
          'pillId': row.pillId,
          'hour': row.hour,
          'minute': row.minute,
          'frequency': row.frequency,
          'frequencyDays': row.frequencyDays,
          'isActive': row.isActive,
          'timeZone': row.timeZone,
          'timeZoneStatus': row.timeZoneStatus,
          'createdAt': row.createdAt.toUtc().toIso8601String(),
          'updatedAt': row.updatedAt.toUtc().toIso8601String(),
          'serverId': row.serverId,
          'revision': row.revision,
          'syncStatus': row.syncStatus,
          'isDeleted': row.isDeleted,
        }),
      ),
    )
    .toString();
