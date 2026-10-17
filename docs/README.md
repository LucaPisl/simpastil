# Documentation

| Document | Contents |
| --- | --- |
| [README](../README.md) | Overview, getting started and quick verification |
| [CONTRIBUTING](../CONTRIBUTING.md) | Development workflow, tests and contribution terms |
| [Install on Android](INSTALL-ANDROID.md) | Installing and verifying a released APK, upgrading, first launch |
| [DEPLOYMENT](../DEPLOYMENT.md) | Installation, upgrade, backup, restore, readiness and rollback |
| [SECURITY](../SECURITY.md) | Supported versions and how to report a vulnerability |
| [CHANGELOG](../CHANGELOG.md) | Release history |
| [ARCHITECTURE](ARCHITECTURE.md) | API, sync, medication, projection, privacy and logging contracts |
| [RELEASE](RELEASE.md) | Signing, provenance and artifact verification |
| [Migration compatibility](decisions/migration-compatibility.md) | Expand/contract migrations, the compatibility floor and image-only rollback |
| [Refresh recovery](decisions/refresh-recovery.md) | Recoverable refresh-rotation protocol and its rollout |
| [Technology stack](decisions/2026-03-technology-stack.md) | Original technology decisions and their reasoning |
| [Server README](../server/README.md) | Component map of `server/` and local-development commands |
| [Flutter README](../flutter_app/README.md) | Android release-signing setup |
| [OpenAPI](../server/openapi/openapi.json) | Routes and schemas (generated; do not edit by hand) |

Planning notes, design records and review evidence kept in other directories of
the development repository are not part of the public source tree.

When sources disagree, executable tests and the generated OpenAPI document take
precedence over the prose guides.
