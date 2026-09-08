## Agent skills

### Issue tracker

Issues and specs are tracked as local Markdown files under `.scratch/`. See `docs/agents/issue-tracker.md`.

### Triage labels

This repo uses the default mattpocock/skills triage vocabulary. See `docs/agents/triage-labels.md`.

### Domain docs

This is a single-context repository. Read the root `CONTEXT.md` and relevant ADRs under `docs/adr/` when they exist. See `docs/agents/domain.md`.

### Git discipline

`main` is the only maintained line; feature work lives on short-lived branches, is merged into `main`, then removed with `git branch -d` (which refuses unmerged work). History is traced through the commit graph and tags — `git log`, `git show`, `git log -S`, `git reflog` — never through branch names. The shipped product line is the unsandboxed local workspace editor; Harness remains historical source only and is not an active worktree or release form. See `docs/adr/0014` for the single-main-line decision and `docs/adr/0015` for the FloralMD public identity.
