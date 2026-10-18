# Installing the Android app

This guide is for people who want to install a released Simpastil APK. To build
the app from source instead, see the [README](../README.md#1-the-app-without-a-server).

## Get the release

Releases are on the project's
[GitHub releases page](https://github.com/LucaPisl/simpastil/releases). Each
release has these files:

- `app-release.apk`, the signed app, and `app-release.apk.sha256`;
- `release-manifest.json`, which records the app version and the signer
  certificate fingerprint, and `release-manifest.json.sha256`;
- `dependency-inventory.json` and `dependency-inventory.json.sha256`;
- `simpastil-v<version>-<run>-<id>.tar.gz`, all of the above in one archive,
  and its `.sha256`.

To install, you only need `app-release.apk`. Download `app-release.apk.sha256`
to the same folder if you want to check it.

## Verify the download

Check the APK:

```sh
sha256sum --check app-release.apk.sha256
```

The command must print `OK`. On macOS use `shasum -a 256 -c`. Do not install a file that fails a check.

Then check who signed the APK. This needs `apksigner` from the Android SDK
build-tools:

```sh
apksigner verify --print-certs app-release.apk
```

Compare the printed `certificate SHA-256 digest` with the Simpastil release
certificate, ignoring case and colons. It is also recorded in
`release-manifest.json`:

```text
BF:49:F2:AE:A7:AE:27:15:FD:ED:C6:BC:0A:A4:52:BF:E1:1C:BA:F1:20:DD:AB:87:AE:0B:89:9E:42:FA:69:70
```

`apksigner` prints it without colons, as
`bf49f2aea7ae2715fdedc6bc0aa452bfe11cbaf120ddab87ae0b899e42fa6970`, with the
signer `CN=Simpastil`. If it differs, or the output mentions a debug
certificate, do not install the APK. The checksums only show the download
is intact; the fingerprint shows who signed it.

## Allow installation

Android blocks apps from outside the Play Store until you allow the app you use
to open the file (your browser or file manager) to install apps. Open
**Settings > Apps > Special app access > Install unknown apps** (the wording
varies by manufacturer), pick that app and allow it. Turn the permission off
again after installing. Then open `app-release.apk` and confirm the install.

## Upgrade

Install a newer release over the old one; Android keeps your data and the app
updates in place. Take a portable backup first (Settings > Backups) if you want an
independent copy. Do not clear the app's data or uninstall to "fix" an
upgrade: that deletes the on-device data.

An upgrade is only possible between APKs signed with the same certificate. A
debug build (built from source with `flutter build apk --debug`) is signed with
a local debug key, so a release APK cannot replace it, and a debug build cannot
replace a release APK. Android refuses the update, and the only way through is
to uninstall the first app, which erases its data. If you move from a debug
build to a release build, make a portable backup first, uninstall, install the
release APK and restore the backup.

## Update notices

Simpastil never downloads or installs updates by itself. When the latest
release on GitHub has a newer app build than the one installed, a card above
the day on Today and at the top of Settings says so, with a button that opens
the release page. Close the card to hide that release; the next one shows it
again. Install the new APK over the old one as described under
[Upgrade](#upgrade), so your data stays.

- With a server, the server asks GitHub once a day and the app reads the answer
  from the server. The phone does not contact GitHub. If the server requires
  a newer app before it syncs, the sync status says so and the card stays
  hidden.
- Without a server, the app does not contact GitHub unless you switch on
  Settings > About > *Check for updates*. Then it asks at most once a day, when
  you open it. The request carries your IP address and nothing about your data.
  The switch is off by default, so a fresh install, an install from F-Droid and
  an update from an earlier version all stay quiet until you turn it on.

[Obtainium](https://github.com/ImranR98/Obtainium) can download each release
for you instead: add `https://github.com/LucaPisl/simpastil` as an app source.
It installs `app-release.apk` from the latest release. Android only accepts an
update signed with the same certificate as the installed app, so check the
first APK as described under [Verify the download](#verify-the-download).

## First launch

The welcome screen offers:

- **Start on this device**: no account and no server. Add a person and a
  medication and the app works fully offline. You can connect a server later.
- **Connect to a server**: enter the
  server's address and an API key from its administrator, then create or sign in
  to an account. See
  [DEPLOYMENT.md](../DEPLOYMENT.md) for running a server.
- **Restore a backup**: restore from a portable backup file and its password.

The app requests no permissions at launch. Reminder access is requested
when you set up reminders, and Settings shows whether reminders are working.
