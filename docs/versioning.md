# TokenRemain version management

TokenRemain uses Semantic Versioning for public releases and monotonically
increasing Apple build numbers.

## Sources of truth

- `VERSION` contains the next public marketing version as `MAJOR.MINOR.PATCH`.
- `BUILD_NUMBER` contains the positive integer used by Apple bundles.
- `script/verify_version_consistency.sh` requires the macOS Info.plist and the
  two version files to match.
- `CHANGELOG.md` records the current unreleased cycle and every tagged release.

## Branches and tags

- `main` is the stable integration branch.
- Active release development uses `codex/vMAJOR.MINOR`; the current line is
  `codex/v1.1`.
- Public releases use immutable annotated tags such as `v1.0.0` and `v1.1.0`.
  Existing release tags are never moved or reused.
- Development commits do not receive a release tag. A `v1.1.0` tag may be
  created only after the release commit is on `main` and all release gates pass.

## Version increments

- Patch: compatible fixes that do not add a product capability.
- Minor: compatible new capabilities or material workflow improvements.
- Major: incompatible product, storage, or public-contract changes.
- `BUILD_NUMBER` increases for every macOS bundle release.

## Release gate

Before creating a release tag:

1. Move the matching Changelog section from `Unreleased` to its release date.
2. Run `script/verify_release_configuration.sh` and the full test suite.
3. Build and inspect the distribution-signed macOS artifact.
4. Complete external production prerequisites, including the reviewed CloudKit
   schema deployment when the release depends on cross-device sync.
5. Merge the reviewed release commit to `main`.
6. Create and push an annotated `vMAJOR.MINOR.PATCH` tag at that exact commit.

The current `v1.0.0` tag remains the immutable v1 baseline. Work after that
baseline belongs to the v1.1 development cycle until the `v1.1.0` gate closes.
