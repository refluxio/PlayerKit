# PlayerKit Project Context

> Open-source Swift video player framework (KSPlayer-equivalent). Sibling
> repo to `reflux` (closed-source client, main repo) and `PlayerKitPro`
> (closed-source Pro features that depend on this package). Each of the
> three repos has its own remote and commit history — never create a commit
> here from inside another repo's working tree. See `../reflux/CLAUDE.md`
> for the full multi-repo layout and which repo owns which code.

## Git Commit Rules

（复制自 lattice / reflux 项目，提交规则以这里为准）

- A feature should be a single commit. If the implementation spans multiple
  changes, stage them all together and make one commit at the end — do not
  commit incrementally.
- Always use `git commit -s` (Signed-off-by).
- **Never add `Co-Authored-By` in commit messages.**
- Do not amend or rebase existing commits — including ones that haven't
  been pushed yet. If a previous commit needs a fix, just make a new commit
  on top. Keep it simple and linear — no force-pushing, no history
  rewriting. (This is stricter than `CONTRIBUTING.md`'s "no amend/rebase of
  *merged* commits" — for Claude Code's own work, treat every commit as
  final once made.)
- After completing a design/plan and its implementation, automatically
  commit all changes without waiting for the user to ask.
- Push after commit: once a commit is made, push it to the remote
  (`git push`) right away — don't leave commits sitting locally.
- Commit author: always use the identity from `git config user.name` /
  `git config user.email`.
- Before committing, run `xcrun swift build` and `xcrun swift test` (see
  `CONTRIBUTING.md` — use `xcrun swift`, not bare `swift`) and fix any
  failures; don't commit red.
- Commit message subject ≤ 70 chars, imperative mood. Optional `scope:`
  prefix (e.g. `feat(decode): ...`, `fix(sync): ...`), matching
  `CONTRIBUTING.md`.
