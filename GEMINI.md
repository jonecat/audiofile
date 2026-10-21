# Project Rules & Instructions

## Workflow: Commits to GitHub & Point Releases
Whenever the user asks to "commit changes to GitHub" (or requests committing and pushing changes):
1. **Always run `./scripts/release.sh`** instead of just a raw git commit/push:
   - This increments the patch version in `VERSION` and `Resources/Info.plist`.
   - Builds and packages `AudioFile.app`, `AudioFile.app.zip`, and `AudioFile.dmg`.
   - Commits and tags the release (e.g. `vX.Y.Z`).
   - Pushes `main` and the release tag to GitHub.
   - Creates/publishes the GitHub Release with the `.dmg` and `.zip` binaries.
2. **Sync Local Installation**:
   - Update `/Applications/AudioFile.app` with the newly signed release bundle so local testing and installed shortcuts immediately reflect the new release.
