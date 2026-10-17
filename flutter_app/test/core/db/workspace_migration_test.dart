import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:simpastil/core/db/database.dart';

import '../../fixtures/legacy_v3_database.dart';

void main() {
  test(
    'upgrade keeps owner and queue, leaves historical author and origin unknown',
    () async {
      final db = AppDatabase(NativeDatabase.memory(setup: seedLegacyV3));
      addTearDown(db.close);
      final version = await db.customSelect('PRAGMA user_version').getSingle();
      expect(
        version.read<int>('user_version'),
        AppDatabase.supportedSchemaVersion,
      );
      final workspace = await db
          .customSelect('SELECT * FROM care_workspaces')
          .getSingle();
      expect(workspace.read<String>('owner_user_id'), 'user-1');
      expect(workspace.read<String>('kind'), 'connected');
      expect(workspace.read<String>('binding_state'), 'unresolved');
      expect(workspace.readNullable<String>('endpoint'), isNull);
      expect(workspace.readNullable<String>('current_author_id'), isNull);
      expect((await db.profilesDao.getById('profile-1'))?.userId, 'user-1');
      expect(await db.pendingOperationsDao.getForUser('user-1'), hasLength(3));
      final reminder = await db
          .customSelect(
            'SELECT enabled FROM device_person_reminders WHERE profile_id=\'profile-1\'',
          )
          .getSingle();
      expect(reminder.read<int>('enabled'), 1);
    },
  );
}
