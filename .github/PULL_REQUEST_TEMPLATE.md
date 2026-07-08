# Pull Request

## Summary

<!-- One or two sentences: what does this PR change and why? -->

## Type

- [ ] feat (new feature)
- [ ] fix (bug fix)
- [ ] refactor (no behavior change)
- [ ] perf (performance improvement)
- [ ] docs (documentation only)
- [ ] test (test only)
- [ ] chore (build/CI/tooling)

## Open core boundary

- [ ] This PR **does not** add HDR passthrough, Atmos/DTS-HD passthrough, DLNA cast, or AI frame sampling. Those belong in `PlayerKitPro`, not this repo.

## Tests

- [ ] `xcrun swift test` passes locally.
- [ ] New public API has tests.
- [ ] No force-unwraps (`!`) added in library code.

## Commits

- [ ] One commit per feature (no incremental commits).
- [ ] All commits are signed (`git commit -s`, no `Co-Authored-By`).
- [ ] No amend/rebase of already-pushed commits.

## Protocol changes

If this PR changes a protocol (`Playable` / `MediaProbable` / `VideoRenderer` / `AudioOutputBackend` / `FrameSink` / `PlayerBackend`):

- [ ] Default implementations are updated.
- [ ] Breaking change called out in the commit message.
- [ ] `PlayerKitPro` compatibility considered (since Pro injects via the same protocols).

## Verification

<!-- How did you verify this works? E.g. "Played BigBuckBunny.mp4 with MinimalPlayer, observed smooth playback at 60fps." -->
