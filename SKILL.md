---
name: opencode-worker
description: Delegate a self-contained coding or research task to a persistent OpenCode worker with its own isolated workspace, full file and shell permissions, and a resumable session. Multi-turn work uses a locally budgeted chat with a hard turn limit, user/admin approval, and a per-turn ledger of expected result and deadline. Use when a task would flood this conversation with tool output, can run in parallel, or needs many edit-run-fix iterations. Only the worker's final answer returns to the calling agent; intermediate tool output stays in the worker log. This is the standalone worker: no chatroom server, no supervisor/worker cell, no broadcast or DM channels.
whenToUse: The user asks for a substantial independent task (implement a feature, fix and verify tests, refactor a module, investigate a repository, run a long build-debug loop) that does not need this conversation's hidden context, or asks to delegate work to OpenCode/a worker/sub-agent. Also use for several independent tasks that can run concurrently in separate workspaces. Do not use for a multi-worker cell with a base station, broadcasts, DMs, inbox delivery, or budget alerts: that is the opencode-worker-cell skill.
---

# OpenCode Worker

Delegate a self-contained task to a persistent OpenCode worker with its own isolated workspace, full file/shell permissions, and a resumable session. Only the worker's final answer is printed; intermediate tool output stays in its logs. The manager only needs Python 3.9+, git, and the `opencode` CLI; it works under dsh and OpenCode alike.

This is the **standalone worker** skill: one worker, one assignment, one budgeted chat. There is no chatroom server, no supervisor role, no broadcast/DM channels, and no alerts. If the task needs a team (a base station that schedules several user-equipment workers, coordination messages, or a shared message budget), use the **opencode-worker-cell** skill instead.

The manager is `scripts/opencode-worker` beside this `SKILL.md`. Resolve the absolute path from the skill base directory (dsh exposes it as `<skill_resources>`; OpenCode passes it with the loaded skill) and repeat it in every bash call:

```sh
W=/absolute/path/to/opencode-worker/scripts/opencode-worker
```

## One-off run

`run NAME TASK...` is the unbudgeted shorthand for a single self-contained task. It auto-creates a missing worker and resumes the worker's stored session.

```sh
"$W" run fix-auth "Also update the changelog."
```

Prefer a chat whenever the task may need follow-up messages.

## Chat budget (multi-turn work)

Every delegation that may need more than one message runs inside a **chat** with a hard turn budget, a local ledger, and mandatory approval. The ledger is a plain file under `<worker>/chats/<chat-id>.json`; no server is involved.

```sh
# 1. Create a chat. Approval is mandatory.
"$W" chat start --worker fix-auth --max-turns 6 --priority high \
  --approved-by user --note "fix the auth tests"
# prints: chat: chat-20261108T...

# 2. Send one turn. Always record what you expect and when.
"$W" chat send --chat chat-20261108T... \
  --expect "auth tests pass" --expect-within 600 \
  --prompt-file - <<'EOF'
Objective: fix the failing auth tests.
Context: failures are in tests/auth; token expiry logic is in src/auth/token.ts.
Verification: run `pytest tests/auth -q` and report the result.
Report back: changed files, test summary, remaining risks.
EOF

# 3. Check the local ledger. Overdue work is marked OVERDUE.
"$W" chat status --chat chat-20261108T...
"$W" chat list --open

# 4. Close when done.
"$W" chat close --chat chat-20261108T...
```

Rules:

- **Budget**: default 10 turns, hard cap 50 (`--max-turns`). Each `chat send` consumes one turn before it runs; failed and timed-out turns still count. One chat runs one turn at a time.
- **Exhaustion**: at the limit the chat stops with exit 4. To continue the same OpenCode session, ask the user or admin to approve a **new** chat with `--session <session-id>`. Never start a new chat silently.
- **Approval**: `chat start` requires `--approved-by user|admin` and stores `approved_at` plus an optional `--note`. Do not claim approval you did not receive.
- **Expectations**: always pass `--expect TEXT` and `--expect-within SEC`. `chat status`/`chat list` expose the deadline and `OVERDUE`; when due, check progress and report to the user. Do not busy-poll.
- **Priority**: `--priority high|normal|low` (default `normal`) orders the global execution queue. Set it at `chat start`, or override for one turn with `chat send --priority`.

## Session precedence

- `--is-new-session true` starts a fresh session. It is valid only on the first turn of a chat and only if the chat has no linked session.
- `--is-new-session false` (default) resumes the chat's linked session.
- A chat created without `--session` starts fresh on its first turn; the resulting session id is stored in the chat.
- After exhaustion, continue the same session with a new approved chat: `chat start --worker NAME --session SES ...`.

## Global semaphore

Every `run` and `chat send` acquires a slot from the central queue at `<root>/.semaphore`. Every process using the same worker root shares this queue:

- Global concurrency default **3**; change it with `semaphore set --max-concurrent N` (1–16). Lowering it does not preempt active holders.
- At most **one active slot per worker**, so concurrent chats cannot focus-fire the same worker. Extra turns wait in the queue.
- Queue order: priority first, then the worker with fewer queued chats, then arrival order.
- `--queue-timeout SEC` controls how long to wait (default 300; `0` fails fast). A queue timeout consumes the chat turn.
- Inspect active holders and waiters with `semaphore status [--json]`.

## Commands

| Command | Purpose |
|---|---|
| `new NAME [--source DIR] [--mode auto\|worktree\|copy\|empty] [--model M] [--task TEXT] [--loop PROFILE]` | Create a worker and its `AGENTS.md`. |
| `run NAME [TASK...]` | One-off unbudgeted run; auto-creates and resumes. |
| `chat start --worker NAME --approved-by user\|admin [--max-turns N] [--priority P] [--session SES]` | Create a budgeted chat. |
| `chat send --chat ID [--expect TEXT] [--expect-within SEC] [--priority P]` | Send one turn, consume the budget. |
| `chat status --chat ID [--json]` | Show budget, turns, deadlines, and the ledger. |
| `chat list [--worker NAME] [--open] [--overdue] [--json]` | The delegation ledger across workers. |
| `chat close --chat ID` | Close a chat. |
| `agents NAME [--task TEXT] [--agents-file FILE] [--write]` | Preview or regenerate a worker's `AGENTS.md`. |
| `semaphore status [--json]` | Show active slots and the waiting queue. |
| `semaphore set --max-concurrent N` | Set the global concurrency limit (1–16). |
| `status NAME` | Query one worker's state. |
| `list [--all]` | List workers. |
| `session NAME [--json]` | Show a worker's session id. |
| `result NAME` | Print the last full result. |
| `logs NAME` | Show recent raw OpenCode events for debugging. |
| `diff NAME` | `--stat`, `--name-only`, or `--patch`. |
| `commit NAME -m MSG` | Commit workspace changes. |
| `close NAME` | Mark a worker closed (keeps workspace and session). |
| `destroy NAME` | Remove state/worktree; `--force` for dirty worktrees; `--delete-session` also deletes the session. |
| `doctor [--models] [--json]` | Check the environment and list models. |

`create` is the same as `new`. Run any command with `--help` for its full flags.

## Worker layout (created for you)

`new` (and `run`, for a missing worker) builds the whole worker; **do not `mkdir` and do not
write `AGENTS.md` yourself**:

```text
<root>/<name>/AGENTS.md        canonical role brief (auto-generated)
<root>/<name>/meta.json        role, task, model, session, counters
<root>/<name>/logs/            raw OpenCode events of every run
<root>/<name>/workspace/       where the worker works
<root>/<name>/workspace/AGENTS.md   marked copy of the brief (auto-maintained)
```

- The worker reads `<workspace>/AGENTS.md` when it starts, so the role instructions reach it
  automatically. A marked block (`<!-- dsh-opencode-worker:start -->`) keeps it in sync; any
  text you keep outside the block is preserved.
- `--mode auto` (default) picks a git worktree for a git `--source`, a copy otherwise, and an
  empty workspace when no source is given. Pass `--mode empty` for a scratch worker.
- `--task TEXT` is written into the brief as the assignment. To change it later:
  `agents NAME --task "new assignment" --write`.
- `--agents-file FILE` replaces the generated brief body with your own text; keep it
  self-contained.
- The **working method** in the brief is picked from the task text, so the loop matches the
  work: `bugfix` (reproduce first), `feature` (acceptance criteria first), `test` (failing
  test first), `refactor` (behaviour baseline), `perf` (measure before and after), `research`
  (evidence and open questions), `docs` (code wins over docs), `infra` (reversible steps),
  `generic` (default). Check what was chosen with `status NAME`; pin it with
  `--loop PROFILE` when the automatic choice is wrong.

## Writing the brief

The worker starts with a fresh context, so the brief must stand alone:

```text
Objective: one concrete outcome.
Context: repository layout, relevant files, constraints, versions, credentials already in the environment.
Deliverables: files to change or create; behavior required.
Verification: exact commands and expected results.
Report back: a short summary, verification evidence, and remaining risks.
Do not: unrelated refactors, dependency upgrades, branch changes, or changes outside the workspace.
```

Tell it to stay inside the workspace and verify its own work. Ask for a summary and file paths, not full logs or pasted files.

## Parallel and long tasks

Use one worker per independent task; different workers run in parallel subject to the global semaphore. The same worker never runs twice at once; a second turn waits in the semaphore queue. For tasks that may exceed the caller's shell timeout, run the call as a background job and collect it with the caller's job tool (dsh `job_output`; OpenCode background shell).

## Safety

- `opencode run --auto` grants full file and shell permissions. The workspace isolates context, not the machine.
- Review `diff --patch` before merging or applying changes.
- `destroy` refuses a live run and a dirty worktree without `--force`.
- Uncommitted source changes are not copied into a worktree; commit or stash first, or use copy mode.
- Workers cannot create or drive other workers: the manager refuses nested `new`/`run`/`chat` inside a worker.

## Troubleshooting

| Symptom | Action |
|---|---|
| `opencode executable not found` | Run `doctor`; install OpenCode or set `OPENCODE_BIN`. |
| `chat ... quota exhausted` | Ask the user/admin for a new approved chat with `--session <id>`; do not bypass the budget. |
| `timed out ... semaphore slot` | Check `semaphore status`; wait, raise `--queue-timeout`, or use another worker. |
| Worker busy (exit 4) | Wait, pass `--wait`, or use another worker. |
| Status `interrupted` | Run again; the session and workspace are reused. |
| `disabled inside an OpenCode worker` | Worker-to-worker delegation is off; the calling agent stays the orchestrator. |
| Auth/provider error | Retry with a free model via `--model opencode/<name>-free`; otherwise fix OpenCode config. |
| Run timed out | Prefer background jobs; check `status`; use `--new-session` if the session looks confused. |

## Model selection

Prefer the strongest available model for the task, not the default. In this
environment the observed capability order is:

1. `opencode/deepseek-v4.1-flash-free` — strongest of the free tier; use for
   independent implementation, debugging, refactors, multi-file changes, and
   test authoring. It may be rate-limited; switch rather than retrying blindly.
2. `minimax-cn-coding-plan/MiniMax-M3` (or newer MiniMax) — good for bounded
   implementation, test/review work, documentation, and verification runs.
   Keep architecture-critical or high-risk changes under caller review.
3. `ollama/*-cloud` (ultra is the strongest Ollama option) — use for simple,
   read-only, or short tasks: investigation, data collection, running an
   existing test, summarizing, or checking a diff. Do not assign large
   autonomous multi-file development without a stronger model.

Use `doctor --models` to confirm the current IDs and quotas. The ordering is a
task-allocation default, not a benchmark claim: a stronger model that is
quota-limited or misconfigured is not usable. Escalate to the strongest
available model for high-risk work; use cheaper/weaker models only when the
task is isolated and easy to verify.

## Defaults and environment

- **Workspace**: git worktree when the source is a git repo with a commit, otherwise a filtered copy. `--mode empty` for pure research.
- **Model**: `opencode/deepseek-v4.1-flash-free` — free, no API key. Override with `--model provider/model`.
- **Agent**: `build`.
- **Output**: only the final assistant text. Raw JSONL and stderr stay in `<worker>/logs/`.

Workers call the `opencode` CLI directly and never use the calling agent's model or credentials. `doctor --models` lists available models; names ending in `-free` use the free quota.

`DSH_OPENCODE_WORKERS` overrides the worker root, `OPENCODE_BIN` the OpenCode binary, `DSH_HOME` the default root base. Default root: `~/.dsh/opencode-workers`. Use `--root` to isolate a test root.

## Using from OpenCode

OpenCode discovers skills under `~/.config/opencode/skills/<id>/SKILL.md` (or `.opencode/skills` in a project). Install this directory there, for example:

```sh
mkdir -p ~/.config/opencode/skills
ln -s ~/.dsh/skills/opencode-worker ~/.config/opencode/skills/opencode-worker
```

Then mention `@opencode-worker` in a prompt or let the model load it by description. If OpenCode is already running, restart it or run with `--standalone` to pick up a newly installed skill.
