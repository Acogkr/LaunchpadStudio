# Compatibility and testing

The Universal app contains `arm64` and `x86_64` executables with a macOS 13.0 deployment target. The OS check accepts 13, 14, and 15 explicitly. A future OS is not assumed compatible just because the app can launch there.

| Environment | Status |
| --- | --- |
| macOS 15.7.4, Apple Silicon | Local UI checks, synthetic tests, and tests against copies of the local database |
| macOS 14 and 15, Apple Silicon | Configured in GitHub Actions; a passing run is required before claiming verification |
| macOS 15, Intel | Configured in GitHub Actions; a passing run is required before claiming verification |
| macOS 13; macOS 14 on Intel | Build target; runtime verification remains outstanding |
| macOS 12 and earlier | Not supported |
| macOS 26 and later | Not supported; the original Launchpad has been replaced |

The current hosted-runner matrix is defined in [ci.yml](../.github/workflows/ci.yml). Passing synthetic tests is not proof that a particular OS uses the same private database format.

## Before a database write

The app requires the original Launchpad, the current user's database path, the standard 7 × 5 grid, and a recognized database shape (`version = 13`, `compatibleVersion = 6`). It refuses active downloads, unknown items, stale previews, missing or duplicate apps, empty folders, and invalid pagination.

Each apply first makes a SQLite backup with a checksum. The write uses a transaction; app metadata, bookmarks, icon caches, and hidden records are retained. A post-commit verification failure keeps the backup and reports the problem instead of silently replacing the database with an old copy.

Backups belong to the same Mac/user database. Stable app UUIDs and bundle identifiers reconcile app installation and removal. They are not a way to transplant someone else's Launchpad onto your Mac.

## What the tests cover

`./test.sh` generates fictional app records from `Tests/Fixtures/schema.sql`. It does not read an installed app list or modify Launchpad. It runs database, model, localization, failure-recovery, synchronization, cleanup, update checks, and 1,500-operation editing tests. Watchdog checks pause and resume disposable sleep processes only. Update tests use injected responses and isolated preferences; they do not contact GitHub.

`./test.sh --live-data` runs those tests against copies of this Mac's compatible Launchpad database. The source database is read-only, and its fingerprint is checked again at the end. User drafts and preferences are also checked for changes.

Neither command performs the real apply → Dock restart → restore sequence. That remains a manual integration check on a separate test account, along with GitHub-download first launch and macOS 13 runtime verification. Those runtime checks remain outstanding for version 1.0.

## App cleanup and synchronization

The app checks Launchpad database and WAL metadata every two seconds while running, and refreshes on foreground activation and wake. Unedited layouts follow Launchpad; competing edits require a choice before applying. App-folder monitoring still confirms installations with two stable scans.

Recent deletions can be restored while the recorded files remain in Trash. Restore verifies file identity and never overwrites an existing destination. Older path-only deletion records remain visible but require manual restoration in Finder. Leftover cleanup checks previously observed app identifiers, excludes installed and protected apps, and requires explicit file selection. Shared group containers are excluded.

An unreadable deletion record is kept and reported without hiding healthy records. App removal and leftover cleanup check other copies registered with macOS, including copies outside Applications, before moving shared settings or data.

Synthetic tests cover conflicts across relaunch, database replacement, deletion protection, file replacement, destination collisions, cancellation, and reinstallation during cleanup. Local UI checks on macOS 15.7.4 also exercise deletion and restoration of disposable test files through the real Trash. They do not empty the user’s Trash.

## Update checks

Only higher stable releases from `Acogkr/LaunchpadStudio` are offered. Drafts, prereleases, equal versions, and older versions do not show an update button. Version comparison, request throttling, cached state, offline responses, and disabling automatic checks are covered by synthetic tests. The release page opens for a manual download; the app does not install updates itself.

## References

The database implementation was developed against a locally inspected schema, with [lporg](https://github.com/blacktop/lporg/blob/master/internal/database/database.go) as a reference. It is not a runtime dependency. Apple's [macOS Tahoe app guide](https://support.apple.com/en-in/guide/mac-help/mh35840/26/mac/26) describes the newer Spotlight app browser.
