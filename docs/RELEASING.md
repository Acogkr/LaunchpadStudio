# Making a release

Release artifacts live in GitHub Releases, not in Git history. The app and installer are built from the tagged source.

1. Update `VERSION`, increment `BUILD_NUMBER`, and add `docs/releases/<version>.md`.
2. Run `./test.sh`, `./build.sh`, `./package.sh`, and `python3 Scripts/verify-package.py`.
3. Commit the changes and push `main`.
4. Create and push the matching tag:

```sh
studio_version="$(cat VERSION)"
git tag -a "v$studio_version" -m "Launchpad Studio $studio_version"
git push origin "v$studio_version"
```

The Release workflow waits for the macOS test matrix, builds a Universal app, creates and verifies the DMG, then uploads the DMG and checksum to a **draft release**. Open the draft in GitHub, check the notes, and choose **Publish release** when it is ready.

Existing published releases are never overwritten by the workflow. To replace an unpublished build, rerun the same tag workflow while its release is still a draft. For a published change, use a new version and tag.

`GITHUB_TOKEN` is enough for the workflow; there is no signing certificate, Apple developer account, or third-party release service to configure. Actions must be enabled for the repository. The release job has `contents: write`; test jobs only need read access.

## First source commit

After reviewing the files, for an empty local history with `origin` already pointing to the GitHub repository:

```sh
git add .
git commit -m "init"
git push -u origin main
```

The repository and `main` branch must be ready before pushing a release tag. The first source push does not publish a release by itself.

## Local fallback

If hosted runners are unavailable, create the draft from a verified local build:

```sh
studio_version="$(cat VERSION)"
gh release create "v$studio_version" "dist/Launchpad-Studio-$studio_version-universal.dmg" \
  "dist/Launchpad-Studio-$studio_version-universal.dmg.sha256" \
  --verify-tag --draft --title "$studio_version" \
  --notes-file "docs/releases/$studio_version.md"
```

Keep the tested environments and outstanding runtime checks accurate in [COMPATIBILITY.md](COMPATIBILITY.md). The project uses the [MIT License](../LICENSE), which is also included inside the app bundle.

## In-app update checks

The app checks the public [latest release endpoint](https://docs.github.com/en/rest/releases/releases#get-the-latest-release) for `Acogkr/LaunchpadStudio`. It offers only a higher numeric version, using tags such as `v1.0.2` or `v1.1`. The tag must match the bundled `VERSION`. Changing only `BUILD_NUMBER` does not notify existing users.

Drafts and prereleases are excluded. When a release is ready for general use, attach the verified DMG, remove the prerelease flag, and mark it as the latest release. Preview releases can still be downloaded manually.

Automatic checks run at most once a day after a successful response and retry failed requests after an hour. Users can turn them off or check from the app menu. A newer version shows a blue update button in the window header and an update entry in the app menu. These open the release page for a manual download. No notification, token, app inventory, or layout data is sent.
