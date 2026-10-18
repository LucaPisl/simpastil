# Security policy

## Supported versions

Security fixes are made for the latest 1.x release. Older releases are not
patched; upgrade to the latest release before reporting an issue.

## Reporting a vulnerability

Report vulnerabilities privately. Do not open a public issue, pull
request or discussion for a security problem.

Email **simpastil@protonmail.com** with the details below, or use GitHub's
private vulnerability reporting (the **Security** tab, then **Report a
vulnerability**). If you cannot reach either, open a public issue that says
only that you have a security report to share, without any details, and a
maintainer will arrange a private channel.

Useful details to include:

- the affected component (Android app, server API, admin console, deployment
  files) and version or commit;
- the impact, and what an attacker needs in order to exploit it;
- steps or a minimal proof of concept that reproduces the problem;
- any logs or configuration that are relevant, with secrets and personal data
  removed.

This is a volunteer project. Reports are handled on a best-effort basis
with no guaranteed response or fix time. Credit is given in the
changelog if you want it.

## Scope

Of particular interest are authentication and session handling, two-factor
authentication, API keys and invitations, tenant isolation (row-level
security), protected on-device storage and backups, and the handling of
medication data. Findings that need a compromised device or administrator
account, or that only affect an unsupported or modified deployment, are
generally out of scope.
