# Changelog

All notable changes to this project are documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/).

## [1.3.0] - 2026-10-24

### Added

- A photo for each medicine. In the edit form you can take a picture or choose
  one from the gallery to help tell the boxes apart; it appears on the
  medication page and on Dose details, and you can replace or remove it. The
  app turns it into a small JPEG (at most 1600 pixels on a side, about 300 KB)
  with the camera and location data removed, on the device, before it is stored
  or sent. The photo syncs with the account, is included in the data export and
  in backups (a backup refuses with a clear message past about 120 photos), and
  goes with the medicine when it is deleted. It needs no extra Android
  permission. Migration 0034 (expand), capability `medicationPhoto: 1`,
  `GET`, `PUT` and `DELETE /api/v1/pills/{id}/photo`, Drift schema 25. An older
  app ignores the new `photo` key.
- Optional medication details. An as-needed medicine can carry a limit of at
  most N doses in any rolling 24 hours and a minimum number of hours between
  doses; recording a dose past a limit asks first and says when the next dose
  fits, and you can still record it. A medicine can carry an expiry date, which
  appears on Today as a notice from 30 days before and as "Expired" after. A
  medicine can also carry a prescriber and a pharmacy, each a name and a phone
  number, with tap to call on its page. All of it syncs with the account.
  Migration 0033 (expand), capability `medicationDetailsExtra: 1`, Drift schema
  24. An older app ignores the new keys.
- Change your email, export your data and delete your account from Settings >
  Account. Changing the email asks for your password (and 2FA code) and, when
  the server can send mail, confirms the new address by link and tells the old
  one; you stay signed in everywhere. The export is a zip with the full data as
  `simpastil-data.json` and a `dose-history.csv`, and the app says it is not encrypted. Delete
  shows what will go, offers an export first, then asks for the
  password; other devices clear their local copy on the next contact. Migration
  0032 (breaking, compatibility floor 33), capability `accountSelfService`,
  `emailChange`, `GET /api/v1/account/summary` and `/export`,
  `POST /api/v1/account/delete`, `POST /api/v1/auth/change-email` and
  `/confirm`. Deleting an account that was invited by another no longer fails.
- Settings that follow your account. Reminder settings (snooze length, routine
  and person reminders), the Recorded-by name, adherence stats for as-needed
  doses, sibling detection, notices put off with "Later", text size, contrast
  and motion, custom colours and the language are kept with the account and
  appear on every device you sign in on. A new device keeps what the account
  already holds, fills only what it has never held, and says what came along.
  Theme mode, home-screen widget choices, app lock, the device name, the layout,
  the notification sound, automatic missed doses and the new "Remind me on this
  device" switch stay on each device, and Settings says so. Against a server
  without `contracts.accountSettings` nothing changes. Edits are resolved per
  setting with the server winning, and a restored backup is sent as ordinary
  edits that the account can override. Migration 0031, capability
  `accountSettings`, `GET` and `PUT /api/v1/account/settings`.
- Care kept on a phone before it connected can move to the account, from the
  connect screen or Settings. The app saves a backup first, shows what moves and
  asks about every person whose name is already on the account (keep both or
  skip; nothing is merged), copies every recorded dose at its original time,
  checks the account, and only then offers to remove the phone's copy.
- Routines that repeat every N days, and start and end dates for routines, now
  sync to the server (migration 0027, capability `scheduleWindows`).
- `POST /api/v1/medication/moved-history` creates the past doses of moved care
  (capability `movedHistory`).
- Every medication is drawn in its own shape (round, caplet, oval, softgel,
  capsule, triangle, square, diamond or drop) with an imprinted first letter,
  in its colour with a darker outline, so medications are told apart without
  relying on colour. A new medication suggests an unused shape; two letters
  appear when two of a person's medications share a shape and first letter, and
  the picker warns about that. The shape shows on Today, History, Medications,
  the as-needed screen, blister pockets and the home-screen widget. It syncs
  with the medication (migration 0028, capability `medicationShapes`).
- Exact stock for part tablets. A medication whose amount per use is in tablets
  or capsules now subtracts exactly that amount (half a tablet takes half a
  tablet from the count) and shows the count as 12, 12½ or 7.5. The first dose
  recorded from an existing whole count adopts the unit by itself; other units
  (ml, drops, mg) keep a plain count until you confirm. Stock can be typed as
  7.5, 7,5 or 7 1/2. Counts are exact to six decimals; a third of a tablet is
  recorded but its stock needs a recount, and Move asks for that recount first.
  Migration 0029, capability `fractionalStock`, an inventory `quantityDelta` and
  a pill `stockQuantity` / `stockUnit`, all additive on the wire.
- Who gave each dose is now shared with the account. The name chosen under
  Settings > Recorded by is saved with each dose as it is recorded and shown in
  history and dose details on every signed-in device, so a dose recorded on one
  phone no longer reads "Author unknown" on another. Doses recorded before this
  release, and doses from an older app, stay unknown; nothing is guessed. The
  name identifies no account or device. Migration 0030, capability
  `medicationRecordedBy`, an optional `recordedBy {version, name}` on dose
  commands and events. A moved dose keeps its original author, not the name of
  whoever moves it.
- Add stock from a medication's page in a small dialog: type how many you added
  and the count goes up by that amount, recorded as a refill rather than a
  correction. A connected count that could not move for a dose it cannot
  subtract exactly, such as a third of a tablet, says "Needs a recount" with
  a warning icon on Today, the list and the medication page, on every device,
  and a Recount button opens a short dialog with quarter, half and
  three-quarter buttons. Adding stock does not settle a recount; a recount
  does. Against a server without a medication ledger, a refill is refused with
  a notice and waits in Fix sync problems.

### Changed

- Medications are drawn in a higher-contrast palette of twelve colours (the old
  Mint is now Magenta). A colour you already chose keeps its look and is not
  rewritten, and every medication mark has a darker outline of its own colour.
  Colour is never the only signal: shape and imprint tell medications apart,
  and the home-screen widget uses the same display colours.
- In the History calendar every outcome has its own form besides its colour:
  taken is a filled dot, missed a bold cross, skipped a short slash, planned a
  thick ring, not recorded a broken ring and as needed a capsule. A calendar
  day is read aloud as its date and what happened, such as "3 taken, 1 missed".
- Low stock says so in words: a warning icon and "Low · N left", and a
  barred icon and "Out" when nothing is left, on Today, Medications and the
  medication page. Stock bars carry a tick at the refill level. Stock lines
  read as a bare count ("15 left") because the unit is free text.
- Today follows one rule on every layout. The next dose due carries the filled
  *Taken now* button, later doses a small outlined one, and a taken or skipped
  dose shrinks to one quiet line with Undo. After you record a dose the button
  itself plays the check and turns into Undo; Reduce motion shows Undo at once.
  *Other time* opens a short sheet (day, time, and Dose details for an amount
  or a note), *Skip* records at once and offers Undo, and low stock is one
  quiet row ("Refill soon · 5 left") with Add stock and Later.
- History rows lead with the medication's own mark and name, then the person and
  amount, with the time and outcome at the end, grouped by day under a heading
  that counts the outcomes ("Today · 5 taken, 1 missed"). When and by whom a
  dose was recorded moved to Dose details.
- Connecting: a server that was set up but never signed in to shows "Not signed
  in yet" with *Finish signing in* and *Stop using this server*, Log out opens
  at once, and Restore a backup opens at choosing the file.
- Moving care to the account says what moved when it is done and shows which
  duplicate choice is selected.
- An account that stores an every-N-days or dated routine needs app build 7 or
  later; older apps on that account are asked to update. Other accounts are not
  affected.
- Migration 0027 is **breaking**: going back to an earlier server needs a
  restore of the backup taken before the upgrade.
- Migration 0028 is **expand**: the previous image keeps serving the database,
  and going back is `rollback.sh`. Roll back before any medication shape is
  picked, or restore the pre-migration backup, because a medication with a
  picked shape has change rows the previous release cannot read.
- Migration 0029 is **breaking**: stock and inventory changes become
  `numeric(20,6)` and pills gain a stock unit, so going back to an earlier
  server needs a restore of the backup taken before the upgrade. The first unit
  or fractional stock write raises that account's minimum app build to 8; other
  accounts are not affected. A server that does not advertise
  `fractionalStock: 1` (1.2.0) stays fully usable: the app keeps whole counts,
  never adopts a unit and never sends the new fields to it.
- The app stores inventory changes as exact decimal text (database schema 21).
  Backups taken by an earlier schema still import.
- Migration 0030 is **breaking**: a dose event may now carry the shared name of
  who recorded it, which the previous server cannot read back, so going back to
  an earlier server needs a restore of the backup taken before the upgrade. An
  older app keeps working and its doses simply have no shared name; a server
  that does not advertise `medicationRecordedBy: 1` is sent no name.
- The app stores the shared name with each event (database schema 22). Backups
  taken by an earlier schema still import.
- Migration 0031 is **expand**: it adds the `account_settings` and
  `account_settings_heads` tables under row-level security and changes nothing
  that exists, so the previous server can serve the database and going back is
  `rollback.sh`. The settings stay stored for when you upgrade again. A server
  that does not advertise `accountSettings: 1` (1.2.0) stays fully usable: every
  setting stays on its device and nothing is queued.
- The app keeps a mirror of the account's settings and a queue of unsent edits
  (database schema 23). Backups taken by an earlier schema still import.
- Migration 0035 is **expand**: it adds one nullable `pills.stock_counted_at`
  column (when the stock was last started or counted, so a count that confirmed
  the same number still settles earlier doses for a later undo). The previous
  server never reads it and going back is `rollback.sh`. Migrations 0033 and
  0034 are **expand** too, but roll back before any detail or photo is set, or
  restore the pre-migration backup, because a medication with one has change
  rows the previous release cannot read.

### Fixed

- A dose or change left "Sending" after the app was killed (an update, battery
  optimisation) is now sent again automatically, or put in Fix sync problems
  when it cannot be resent safely.

## [1.2.0] - 2026-10-20

### Added

- Self-hosting without a public certificate. When the phone cannot verify your
  server's certificate, the app shows the server's key fingerprint and connects
  only after you trust it. It then pins that key: the server must keep
  presenting the same key, even if it later gets a certificate from a public
  authority. If a pinned server presents another key, the app stops all traffic
  to it, shows both fingerprints and lets you keep it blocked, trust the new
  key, or (only if the certificate now passes normal checks) go back to normal
  checking. Background sync never connects to a server whose key changed.
  Servers you never pinned are checked as before; when one presents a
  certificate the phone cannot verify, the sign-in, access-key and Sync screens
  say so and offer to review its key, and the app syncs as soon as you trust
  it. Trusting the key on one screen clears the warning on the others.
- `scripts/init-deploy.sh` prints the certificate public-key fingerprint to
  compare with the one the app shows, and DEPLOYMENT.md gives the command for
  existing servers.
- Password resets without email. The administrator chooses in the console
  whether resets are automatic, sent by email, or made only as links they
  create (manual), and how long a reset link stays valid (5 minutes to 24 hours, one hour by default). A
  *Create reset link* button on a person's page shows a one-time link once. A
  new link, however it was made, cancels that person's older unused links. In
  manual mode, forgot-password sends nothing, and email invitations are turned
  off. A server that has email set up keeps sending reset emails after the upgrade.
- The forgot-password screen follows what the server can do. When the server
  cannot send reset emails, the app says so and points to the administrator
  instead of offering a form that cannot work, and when the server does not say
  it adds a short hint.
- Email is optional on the server. Without `SMTP_HOST` the outbox worker idles
  instead of crash-looping, and the API runs in manual-reset mode. The admin
  console shows an *Email* status card with recent delivery failures; the
  public capabilities answer only says whether reset email is available.
- The API serves the admin console itself, on the same origin as the API. It
  now appears after a normal upgrade on every setup, including a host reverse
  proxy without the bundled nginx, and reset and invitation links lead to a
  working page. The bundled nginx only forwards to the API.
- Admin console: two-factor authentication can be set up and turned off in
  Settings (the QR code is drawn in the browser, nothing is sent to a QR
  service), backup codes are shown once and can be regenerated, and sign-in
  accepts a backup code.
- A way back into a locked-out console. If the console password, or the
  authenticator and every backup code, are lost, `docker compose run --rm
  provision reset-admin` removes the administrator, signs every admin session
  out and prints a new setup proof for the console's setup page. People, devices
  and medication data are untouched, and the reset is written to the audit log.
  See DEPLOYMENT.md, "Locked out of the console".
- Admin console: *Sign out* now ends that session on the server, and
  *Sign out everywhere* ends every admin session. New `POST
  /api/v1/admin/auth/logout`; admin tokens carry a `sid` claim.
- Admin console: an Audit log page with an action filter, a date range and
  paging. Failed admin sign-ins are recorded as `admin.login_failed` (time and
  address only, at most one per address per minute, per API process).
- Admin console: the overview shows the server version, the deployment release
  ID and whether an update is available.
- Scheduled backups. A `scheduled-backup` Compose service writes a restorable
  bundle into `scheduled/` inside `SIMPASTIL_BACKUP_DIR` every 24 hours by
  default and keeps the newest seven, with no host timer. Tune or switch it off
  with `SIMPASTIL_BACKUP_INTERVAL`, `SIMPASTIL_SCHEDULED_BACKUP_KEEP` and
  `SIMPASTIL_SCHEDULED_BACKUP`. It is the one long-running service that holds
  the database superuser credential; see DEPLOYMENT.md, "Scheduled backups".
- Security headers are sent automatically. The API sets a strict
  `Content-Security-Policy`, `X-Content-Type-Options`, `X-Frame-Options`,
  `Referrer-Policy`, `Permissions-Policy` and `Cross-Origin-Opener-Policy` on its
  responses, so a setup behind your own proxy no longer has to add them. The
  bundled nginx also hides its version and does not repeat the headers the API
  sends.
- Store listing metadata under `fastlane/metadata/android`, with English and
  Romanian text and a short changelog for each build.

### Changed

- The direct update check on a phone without a server is now off by default
  for new installs. A phone that already had Simpastil keeps it on, unless you
  had switched it off. Change it in Settings > About > *Check for updates*. The
  server's own daily check is unchanged.
- Sync problems are stored as stable codes and shown in the app language, and
  the sync details sheet no longer depends on guessing the language.
- Romanian gaps are filled. Error messages from sign-in, two-step verification
  and similar flows follow the app language instead of always showing English,
  and the log-out warning about unsynced changes and the home-screen widget's
  "Log" label are translated.
- F-Droid readiness. SQLite3 Multiple Ciphers is compiled from the vendored
  sources in `third_party/sqlite3mc` instead of a downloaded prebuilt library.
  It is SQLite3MC 2.6.1 / SQLite 3.54.0 with unchanged cipher defaults, so
  existing databases open unchanged. Release builds accept
  `SIMPASTIL_ALLOW_UNSIGNED_RELEASE=1` for reproducible-build verification;
  unsigned release builds still fail without it.
- The app is built with Flutter 3.47.7 (Dart 3.13.5), Android Gradle Plugin
  9.1.0, Kotlin 2.4.0, Gradle 9.3.1 and compile SDK 37. Riverpod 3,
  flutter_secure_storage 10, Drift and drift_dev 2.35.1, sqlite3 3.7.1,
  go_router 18, pdf 3.13, permission_handler 13, build_runner 2.16, notifications,
  workmanager, home_widget, connectivity and timezone, and the other app packages
  are upgraded. Behavior does not change.
- The server and the admin console run on Node 24 and current dependencies,
  including Fastify, Zod 4 and Vite 8, and sign-in tokens are accepted only with
  the RS256 algorithm. The nginx and PostgreSQL images move to current patch
  releases; PostgreSQL stays on 16.
- The Flutter CI and release jobs run in a runner image built from
  `.gitea/flutter-image/Dockerfile`, whose pushed digest is recorded in the
  repository and in the release manifest. Operators build and register it once
  per Flutter version, see docs/RELEASE.md, "Flutter runner image".

### Fixed

- The app no longer shows "Simpastil closed unexpectedly" after an update.
  Android's update, package-change and freezer exits now count as normal.
- The first sync starts right after signing in, even when the screen is idle,
  so reminders for the rest of the day are scheduled straight away. A sync
  failure from another account no longer shows after signing in, and a
  successful sync always clears an old failure. A sync done in the background
  now updates *Last synced*, and Home says *Synced* only after a sync has
  succeeded. *Last synced* keeps counting while the Sync page stays open.
- Saving a new device name in Settings no longer crashes, and signing in again
  offers the saved device name and keeps it if you skip. The Today screen moves
  to the new day when it stays open past midnight. A dose marked as
  missed no longer counts as recorded in the Today summary or the journal, so
  they agree with *This week*. Texts that said "this phone" now say "this
  device", so they read right on a tablet.
- *Verify key* works again after logging out. Logging out always asks first.
  After the server ends a session, the sign-in screen explains that you were
  signed out. The weak-password message says 10 characters, as the server
  requires.
- Doses recorded in the minutes before a server switches to the medication
  ledger now become ledger entries during the switch, so other devices show
  them as taken instead of "Not recorded". Such a dose can be corrected but not
  undone.
- Backups: the database dump is readable only by its owner (mode 0600), and
  `pg_dump` and `psql` are stopped after 30 minutes instead of hanging.

### Upgrading

- Back up first. The server upgrade adds database migration 0026 and the
  automatic pre-migration backup runs, but a manual backup is still the safest
  way back. Rolling back the server image needs no restore, because 0026 only
  adds a table and a function.
- Start the new `scheduled-backup` service with the upgrade. A bare
  `docker compose up --detach` starts it; if you name services, name it too
  (`up --detach --no-build api outbox scheduled-backup`). Before rolling back
  to an older release, stop it first; see DEPLOYMENT.md, "Rollback".
- After updating the app to 1.2.0, do not install an older app version over it.
  The secure storage upgrade moves the stored sign-in and database key, and an
  older build cannot read them, so going back loses both.

## [1.1.1] - 2026-10-18

### Added

- Settings > About has a *Support Simpastil* row that opens the project's Ko-fi
  page outside the app. Donations are optional and nothing in the app depends
  on them. The README gained a badge row and a *Support this project* section.

## [1.1.0] - 2026-10-18

### Added

- Clearer server logs. Every log line now has a fixed English sentence in `msg`
  next to its JSON fields, and a failure says why it failed using only safe,
  closed fields (`causeKind`, `causeCode`, `errorClass`, `where`,
  `configVariable`, `validationPath`), never the exception text. A service that
  stops on a startup error prints one explained line instead of a raw stack
  trace, the readiness probe logs `readiness.not_ready` with its reason when it
  changes, and the outbox worker and token cleanup report why a job failed.
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
- Report a problem. Settings > About > Report a problem builds a short report
  that is safe to post publicly (rough sizes and times, no names, medicines,
  doses, server address or account) and shows exactly what it holds. **Submit
  issue on GitHub** saves it to Downloads and opens a prefilled issue form;
  **Share another way** saves it, emails the maintainer or shares it with
  another app. The app keeps a small on-device log of its own errors so the
  report can say more than "it crashed", notices when it closed unexpectedly
  and offers the report once on Today, and offers it from the sync details when
  a sync has failed and from the screen shown when Simpastil cannot open. Sync
  lines carry the request's correlation ID, which matches the server log.

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
- Update notices. The API checks GitHub once a day for a newer release
  (`SIMPASTIL_UPDATE_CHECK`, on by default), reports it in
  `GET /api/v1/capabilities`, logs `update.available`, and shows a banner on the
  admin dashboard. The app shows an "Update available" card on Today and in
  Settings; a phone without a server checks GitHub itself once a day, which
  Settings > About can switch off. Nothing is installed automatically.
- Updating through Obtainium is described in `docs/INSTALL-ANDROID.md`.
