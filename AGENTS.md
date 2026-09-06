# AGENTS.md — Rules for AI agents working in this repository

These rules apply to any AI agent (Pi, Claude Code, Codex, etc.) operating in
this repo. They exist because automated formatting and auto-committing have
repeatedly produced unwanted changes and hidden the agent's real work.

## 1. Do not auto-commit when a task is complete

- Never run `git commit` (or `git add` + `git commit`) as an automatic final
  step of a task.
- Leave changes uncommitted so the human can review the diff first.
- Only commit when the human explicitly asks you to.
- If you think a commit would be helpful, say so and ask — do not just do it.

## 2. Do not auto-format when a task is complete

- Never run formatters or "tidy"/"cleanup" passes over the codebase on your
  own, including on files you edited.
- Do not reformat existing code, unrelated files, or whole files just because
  a formatter would produce different output.
- Match the surrounding style of the code you touch; do not impose a global
  reformat.
- If you notice formatting inconsistencies, mention them — do not fix them
  wholesale without being asked.

## General

- Keep diffs minimal and focused on the requested change.
- When in doubt, ask the human before mutating the working tree beyond the
  requested edit.
