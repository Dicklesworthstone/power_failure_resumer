# Session file formats (agent notes)

Reference notes on the on-disk session formats pfr scans. Distilled from studying
`~/projects/cross_agent_session_resumer` (casr) — **no code or dependency from casr
is used here**; pfr stays a self-contained Codex+Claude tool.

## Codex (`$CODEX_HOME/sessions/`, default `~/.codex/sessions/`)

- Layout: `YYYY/MM/DD/rollout-YYYY-MM-DDThh-mm-ss-<session-id>.jsonl`
- Envelope per line: `{ "type", "timestamp", "payload" }`
- Line types: `session_meta`, `response_item`, `event_msg` (and subtypes)
- Session id: `session_meta.payload.id`; the filename UUID matches it in practice.
  pfr prefers the filename UUID because it survives a torn/corrupt first line
  after a power cut (casr prefers `payload.id` when meta parses; same result).
  `session_meta` can sit past early housekeeping lines — scan ~64 lines for it.
- Workspace: `session_meta.payload.cwd`
- Resume: `codex resume <session-id>` (pfr emits the `cod` alias)
- Subagent threads: `payload.thread_source == "subagent"` (pfr filters these
  by default; casr similarly prefers `thread_source = 'user'` threads)
- Legacy single-JSON-object files exist in the wild (casr supports them; pfr's
  first-object reader tolerates them since the object still carries `payload`).

## Claude Code (`$CLAUDE_HOME/projects/`, default `~/.claude/projects/`)

- Layout: `<project-key>/<session-id>.jsonl` (subagent transcripts live under a
  `subagents/` subdir, which pfr never descends into)
- **Project key encoding: every non-alphanumeric character → `-`** (not just
  `/`). `~/projects/jeffreys-skills.md` → `-Users-x-projects-jeffreys-skills-md`.
  Reverse-decoding by splitting on `-` is therefore lossy; always prefer the
  top-level `cwd` field embedded in the JSONL lines. pfr only falls back to the
  decode when the JSONL yields no cwd, and only trusts it if the decoded
  directory exists.
- Line types: `user` / `assistant` (conversation), plus `custom-title`,
  `ai-title`, `summary`, `file-history-snapshot`, …
- Per-message fields: `message.role`, `message.content` (string or blocks),
  top-level `cwd`, `sessionId`, `gitBranch`, `timestamp`, `version`
- Session id: filename stem (a UUID); `sessionId` appears in the first ~8 lines
- Titles (for the session-identity work): priority is
  `custom-title` (user `/rename`) > `ai-title` > `summary` > first user text
- Resume: `claude --resume <session-id>` (pfr emits the `cc` alias)

## Timestamps: mtime vs activity

Content timestamps ("last active") describe conversation activity and are the
right signal for "what was I working on?" UI. For power-failure clustering,
**file mtime is the right death signal** — it records when the process last
flushed, i.e. when it died. pfr clusters on mtime and should keep doing so.

## Scope

casr also parses Gemini, Cursor, Grok, etc. pfr deliberately stays Codex+Claude:
those are the sessions that live in Ghostty tabs and die in a power cut.
