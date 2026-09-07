# CLAUDE.md

@AGENTS.md

Claude-only wiring: `.claude/settings.json` runs `.agents/setup.sh` on `SessionStart`; the worktree hooks (`scruff hook create` / `scruff hook remove`) sit in `~/.claude/settings.json`, declared by haus, never hand-edited. The cross-harness map is [`.agents/README.md`](./.agents/README.md).
