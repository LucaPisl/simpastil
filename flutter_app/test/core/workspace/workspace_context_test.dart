// ignore_for_file: prefer_const_constructors
// Distinct values are required to verify value equality, not const identity.

import 'package:flutter_test/flutter_test.dart';
import 'package:simpastil/core/workspace/workspace_context.dart';

void main() {
  test('WorkspaceContext equality and hash cover every authority field', () {
    final context = WorkspaceContext(
      workspaceId: 'workspace-a',
      ownerUserId: 'owner-a',
      authorId: 'author-a',
      kind: WorkspaceKind.connected,
      accessEpoch: 7,
      endpoint: 'https://example.test/care',
      sessionGeneration: 11,
      networkEpoch: 13,
    );
    final equivalent = WorkspaceContext(
      workspaceId: 'workspace-a',
      ownerUserId: 'owner-a',
      authorId: 'author-a',
      kind: WorkspaceKind.connected,
      accessEpoch: 7,
      endpoint: 'https://example.test/care',
      sessionGeneration: 11,
      networkEpoch: 13,
    );

    expect(equivalent, context);
    expect(equivalent.hashCode, context.hashCode);

    final changes = <WorkspaceContext>[
      WorkspaceContext(
        workspaceId: 'workspace-b',
        ownerUserId: 'owner-a',
        authorId: 'author-a',
        kind: WorkspaceKind.connected,
        accessEpoch: 7,
        endpoint: 'https://example.test/care',
        sessionGeneration: 11,
        networkEpoch: 13,
      ),
      WorkspaceContext(
        workspaceId: 'workspace-a',
        ownerUserId: 'owner-b',
        authorId: 'author-a',
        kind: WorkspaceKind.connected,
        accessEpoch: 7,
        endpoint: 'https://example.test/care',
        sessionGeneration: 11,
        networkEpoch: 13,
      ),
      WorkspaceContext(
        workspaceId: 'workspace-a',
        ownerUserId: 'owner-a',
        authorId: 'author-b',
        kind: WorkspaceKind.connected,
        accessEpoch: 7,
        endpoint: 'https://example.test/care',
        sessionGeneration: 11,
        networkEpoch: 13,
      ),
      WorkspaceContext(
        workspaceId: 'workspace-a',
        ownerUserId: 'owner-a',
        authorId: 'author-a',
        kind: WorkspaceKind.local,
        accessEpoch: 7,
        endpoint: 'https://example.test/care',
        sessionGeneration: 11,
        networkEpoch: 13,
      ),
      WorkspaceContext(
        workspaceId: 'workspace-a',
        ownerUserId: 'owner-a',
        authorId: 'author-a',
        kind: WorkspaceKind.connected,
        accessEpoch: 8,
        endpoint: 'https://example.test/care',
        sessionGeneration: 11,
        networkEpoch: 13,
      ),
      WorkspaceContext(
        workspaceId: 'workspace-a',
        ownerUserId: 'owner-a',
        authorId: 'author-a',
        kind: WorkspaceKind.connected,
        accessEpoch: 7,
        endpoint: 'https://other.test/care',
        sessionGeneration: 11,
        networkEpoch: 13,
      ),
      WorkspaceContext(
        workspaceId: 'workspace-a',
        ownerUserId: 'owner-a',
        authorId: 'author-a',
        kind: WorkspaceKind.connected,
        accessEpoch: 7,
        endpoint: 'https://example.test/care',
        sessionGeneration: 12,
        networkEpoch: 13,
      ),
      WorkspaceContext(
        workspaceId: 'workspace-a',
        ownerUserId: 'owner-a',
        authorId: 'author-a',
        kind: WorkspaceKind.connected,
        accessEpoch: 7,
        endpoint: 'https://example.test/care',
        sessionGeneration: 11,
        networkEpoch: 14,
      ),
    ];

    for (final changed in changes) {
      expect(changed, isNot(context));
    }
  });
}
