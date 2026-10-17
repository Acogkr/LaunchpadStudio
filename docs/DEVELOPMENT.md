# Development

Use macOS with Xcode Command Line Tools or Xcode. A recent Swift compiler and the macOS SDK are required; Swift sources compile in Swift 5 language mode. Python 3 is used for translation validation and test fixtures. DMG packaging requires Python 3.10 or later.

```sh
./build.sh
./test.sh
./test.sh --live-data   # Optional: test copies of this Mac's Launchpad
./package.sh
python3 Scripts/verify-package.py
```

`build.sh` discovers Swift files recursively, compiles both architectures, combines them with `lipo`, creates the icon and language bundles, and applies an ad-hoc signature. Tests are built into a separate app under `.build/test-app`; test code and preview fixtures are not included in the release app. Build products go into `dist/`.

For a faster local build:

```sh
STUDIO_ARCHS="$(uname -m)" ./build.sh
```

A release DMG requires both architectures, so run a default build before packaging. `STUDIO_BUILD_DIR` and `STUDIO_DIST_DIR` can move temporary files and deliverables. `STUDIO_DMG_PYTHON` can point at an existing virtual environment with the pinned packaging dependencies.

## Layout

| Directory | Contents |
| --- | --- |
| `Sources/App/` | Entry point, native menus, window lifecycle, and app icon |
| `Sources/Launchpad/` | Layout model, classification, SQLite access, synchronization, backup and apply |
| `Sources/AppManagement/` | App detection, removal, permissions, deletion history, restoration, and cleanup screens |
| `Sources/Updates/` | GitHub release checks, version comparison, and update feedback |
| `Sources/UI/` | Main layout, app inspector, sorting rules, backups, settings, and shared view components |
| `Sources/Shared/` | Localization, OS compatibility, session lock, and common errors |
| `Tests/` | Regression suites; reusable fixtures and previews are in `Support/` |
| `Tests/Fixtures/` | Fictional Launchpad database generator and schema |
| `Resources/Translations.json` | English, Korean, Japanese, Simplified Chinese |
| `Scripts/` | Translation, installer artwork, and package verification tools |
| `.github/workflows/` | CI and tag-based release builds |
| `docs/` | Four language READMEs, compatibility, development, and release notes |

`AppDelegate` owns the window, menus, `StudioModel`, and `UpdateChecker`. Views call the model to edit the draft; they do not write the Launchpad database. `LaunchpadStore` validates and reads or writes its format. `LiveApply` coordinates backup, the transaction, and Dock restart.

App removal scans related files before moving the selected files to Trash. Each completed move is recorded for restoration; failed history writes stop the remaining moves and stay pending for retry. Update checks run separately and do not send the app list or layout to GitHub.

The app uses the macOS frameworks directly. Python packaging dependencies in `Scripts/dmg-requirements.txt` are build tools and are not bundled as runtime dependencies.

## Formatting and translations

Swift formatting uses four spaces and a 120-column target, defined in [`.swift-format`](../.swift-format). With an Xcode toolchain that includes `swift-format`:

```sh
xcrun swift-format format --in-place --recursive Sources Tests
```

Edit `Translations.json`, then run `python3 Scripts/localizations.py --check`. `build.sh` validates matching keys and placeholders and generates `.lproj` files inside its staging directory. Folder names and sorting-rule destinations are user data and are never translated.

Keep local backups, database files, app bundles, and test logs out of commits. These are excluded by [`.gitignore`](../.gitignore). The fixture schema contains table definitions only; its app records are generated from fictional names and identifiers.

## Changing the database code

Keep the read, validation, and write paths together. Add a regression test for changes to pagination, app identity, rollback, or failure recovery. Never substitute a live database path for a test fixture's write path. See [compatibility](COMPATIBILITY.md) for the remaining integration work.
