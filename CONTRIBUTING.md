# Contributing

This is a personal Windows toolkit, but the conventions below keep it navigable — please follow
them if you send a change or add a tool of your own.

## Layout rules

```
<category>/<tool-name>/        category: powershell | python | sync | node
```

- **Top-level folders are lowercase and hyphenated**: `powershell/`, `python/`, `sync/`, `node/`.
- **One folder per tool.** Never drop a loose script at a category root — loose files turn into
  an unsearchable pile within a month.
- **Tool folders are lowercase-kebab** and match the tool's display name: `Take Ownership` →
  `take-ownership/`.
- Assets shared by the docs live in `assets/`. Nothing else sits at the repository root except
  `README.md`, `CONTRIBUTING.md`, `CHANGELOG.md`, `LICENSE`, `.gitignore`, `.gitattributes`.
- Script *file* names stay as they are (`Run-RcloneJobs.ps1`, `restore_and_copy.ps1`); renaming
  them breaks the scheduled tasks and docs that call them.

## Every tool needs a README.md

A tool is not done until its folder has a `README.md` covering:

1. **One-line purpose** and a `Part of the [Nexus](../../README.md) toolkit — <path>` line.
2. **What it does** — the operations, in order, with the real commands where useful.
3. **Usage** — copy-pasteable invocation, including required arguments and elevation needs.
4. **Configuration** — file/table of the knobs and their defaults.
5. **Notes / caveats** — destructive behaviour, requirements, known breakage.

Match the tone of the existing ones and keep them short enough to be read before running
something that deletes files.

## Main README

When adding or renaming a tool, update:

- the layout tree in [`README.md`](README.md#-repository-layout),
- the tool table for its category,
- the usage block if it warrants a quick-start example.

## Commits

- Conventional-ish prefixes: `feat:`, `fix:`, `docs:`, `chore:`, `refactor:`.
- One logical change per commit; put the *why* in the body when it is not obvious.
- Never commit generated output (`*.log`, `*_log_*.csv`, `__pycache__/`) or machine-specific
  config — extend `.gitignore` instead, and ship a `*.example.json` next to it.

## Secrets

Do **not** commit credentials, tokens or machine-local absolute paths. If a secret ever lands in
a commit, treat it as leaked: rotate the credential, then clean the file (rewriting history is a
second, separate step).

## Script standards

**PowerShell**

- Resolve paths from `$PSScriptRoot` instead of hardcoding the repository location, so moving or
  cloning the repo does not break the tool.
- Annotate intended encoding; keep files CRLF (see `.gitattributes`).
- Destructive operations should print what they will do and require confirmation, and support a
  dry-run switch (`-DryRun`) where practical.

**Python**

- Target 3.7+ unless a tool states otherwise; prefer the standard library.
- Third-party requirements go in the tool's README (`pip install …`), not a shared file.

## Testing before a pull request

- `git status` shows only intended changes.
- Every touched `.ps1` parses:
  `powershell -NoProfile -Command "[scriptblock]::Create((Get-Content -Raw .\file.ps1)) | Out-Null"`
- Relative links in any edited markdown resolve to real files.
