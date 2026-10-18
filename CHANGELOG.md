# Changelog

All notable changes to this project are documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/).

## Unreleased

### Added

- Update notices. The API checks GitHub once a day for a newer release
  (`SIMPASTIL_UPDATE_CHECK`, on by default), reports it in
  `GET /api/v1/capabilities`, logs `update.available`, and shows a banner on the
  admin dashboard. The app shows an "Update available" card on Today and in
  Settings; a phone without a server checks GitHub itself once a day, which
  Settings > About can switch off. Nothing is installed automatically.
- Updating through Obtainium is described in `docs/INSTALL-ANDROID.md`.
- Setup asks for the essentials on one reminders screen: whether this person
  gets reminders on this device, whether medication names show on the lock
  screen, and, when Android limits Simpastil in the background, a skippable
  request to let it run, with a tip for Samsung phones. Settings > Reminders
  offers the same battery request.
- Setup ends with a short note that Simpastil is a small project, with links
  to GitHub issues, the source code and Ko-fi, then a summary of what is on or
  off. Devices without a server are reminded that backups are not automatic.
- Today shows a "Reminders are off on this device" card when nobody gets
  reminders here, with *Turn on* and a close button.

### Fixed

- A new install now sends dose reminders. People added on a device start with
  reminders on for that device; before, the first person started with them
  off, so nothing was scheduled. People from your account still start off on
  a new device.
- The setup start page opens Backups for *Restore a backup* instead of saying
  it is not available yet.
- Tapping Taken, Snooze or Skip on a reminder no longer opens the app. The
  button records the action in the background; only tapping the notification
  itself opens the app. With app lock on, the buttons still open the app to
  review the dose, because the app cannot be unlocked from a notification.
- Tapping a reminder whose dose no longer exists, or that belongs to an
  earlier sign-in, opens Today instead of a "Care is temporarily unavailable"
  screen.

## [1.0.0] - 2026-10-17

First public release.

### Added

- Offline-first Android app for tracking medication and adherence for one or
  more people, usable without an account or a server.
- Phone and tablet support. Wide windows get a navigation rail, a two-pane Today
  with a side column (this week, stock, coming up) and a dose-details panel, a
  medication list beside its detail, master-detail Settings, and History with
  calendar and trends. The phone has the same features in narrow-screen
  layouts.
- Today with six layouts (Focus deck, Timeline, Day planner, People lanes,
  Action inbox, Daily journal), *Taken now* and *Undo*, and a low-stock notice.
- Recorded missed doses. With Settings > Reminders > *Record missed doses* on
  (the default), a scheduled dose nobody recorded is written to history as
  missed once the delay has passed (an hour unless you choose another). It syncs to every device, can still be taken late or
  skipped, and can be undone. Recorded misses count in adherence, appear in the
  calendar and are included in exports. Doses with nothing recorded show as
  *Not recorded*. Misses are recorded offline. A server that does not support
  them leaves them unrecorded.
- Medications list with color coding, compact rows with a stock strip, a detail
  page with stock, the last 14 days and recent activity, a live preview in the
  editor, stock counts and a supply calendar.
- Routine editor for every-day, chosen-weekday and every-N-days routines, with a
  day dial.
- As-needed medications without routines, shown as ring cards on Today: hold to
  record a dose, with undo and details, and a Focus shortcut that can be turned
  off in Appearance.
- History with a week strip, calendar and per-day records, a day streak,
  adherence, time-of-day and as-needed charts, and stock changes. Days before a
  person was on this phone are marked separately from days with no doses.
- Reminders with a settings page that reports access, scheduling and delivery
  status, a list of the next planned reminders derived on the device, and a
  retry pass that repairs missing notifications.
- *Recorded by* setting that attributes new doses to the primary profile, a typed
  name or the person taking the dose.
- Android home-screen widget for today's doses.
- Times shown on the phone's own 12-hour or 24-hour clock.
- Encrypted on-device storage, password-protected portable backups, and
  PDF and CSV reports.
- Light and dark themes, editable colors, a *Reduce motion* setting, and English
  and Romanian translations.
- Optional sync with a self-hosted server: PostgreSQL with row-level tenant
  isolation, an admin console, API keys and email invitations, and TOTP
  two-factor authentication for users and administrators.
- Sync recovery: separate counts of queued, retrying, blocked, conflicting and
  stranded changes, and a *Fix sync problems* screen with retry, use the server
  version, keep my change, dismiss and re-download.
- Server medication ledger: dose and stock changes are stored as append-only,
  idempotent commands, including recorded misses. A new server starts in
  compatibility mode; activating the ledger is a separate operator step (see
  [DEPLOYMENT.md](DEPLOYMENT.md)).
- The reviewed details of a medicine belong to the account instead of one
  device. The amount taken per dose, the package strength, the form, and whether
  somebody has reviewed the original dosage wording travel with the medicine and
  reach every device, behind the `medicationDetails` capability. A server
  without it keeps working, and the reviews made while it could not store them
  are handed over on the first sync after the upgrade.
- Docker Compose deployment with nginx, provisioning and migration services,
  and backup and restore scripts.
- Signed release builds with a provenance manifest and checksums.
