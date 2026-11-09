# opencode-worker (standalone)

A dsh/OpenCode skill that delegates independent tasks to persistent [OpenCode](https://opencode.ai) workers. Each worker has its own workspace, full file and shell permissions, and a resumable session. Only the worker's final answer is printed, so intermediate tool output does not consume the caller's context.

This is the **standalone** variant: one worker, one assignment, one locally budgeted chat. It deliberately has **no chatroom**: no local server, no supervisor/worker cell, no broadcast or DM channels, no shared message budget, and no alerts. Everything is plain files under the worker root.

The team variant (base station + user equipment, chatroom server, coordination channels, alerts) is the separate **opencode-worker-cell** project. Both are built from the same manager; the difference is the `--profile` flag.

## Requirements

- macOS or Linux
- Python 3.9+
- git
- OpenCode CLI on `PATH` (or set `OPENCODE_BIN`); no paid provider is required — OpenCode's free models work without authentication. Tested with v2.2.6, which provides `run --format json`, `--session`, and `--auto`

## Installation

This repository is self-contained: `scripts/opencode-worker` is the whole manager, vendored with
the **standalone** profile as its default (no chatroom server, no roles, no broadcast/DM).

**OpenCode** - clone it into the global skill directory:

```sh
git clone https://github.com/fundou1081/opencode-worker.git \
    ~/.config/opencode/skills/opencode-worker
```

**dsh** - clone it into the skill directory:

```sh
git clone https://github.com/fundou1081/opencode-worker.git \
    ~/.dsh/skills/opencode-worker
```

Either way the skill is discovered through its `SKILL.md`. The manager only needs
`scripts/opencode-worker` to be executable.

```text
opencode-worker/
├── SKILL.md                 # model-facing instructions
├── README.md                # this file
├── scripts/
│   └── opencode-worker      # the manager (standalone profile by default)
└── tests/                   # regression suite
```

Verify the environment:

```sh
./scripts/opencode-worker doctor
```

### OpenCode discovery

OpenCode discovers `SKILL.md` under `~/.config/opencode/skills/<id>/` and `.opencode/skills/` in
a project. Mention `@opencode-worker` in a prompt, or let OpenCode load it from the description
in `SKILL.md`. The manager is standalone: it only needs Python 3.9+, git, and the `opencode` CLI.
If OpenCode is already running, restart it or use `--standalone` to pick up a new skill.
## How it works

A worker is a name plus:

- **Workspace**: an isolated directory the worker edits and runs commands in.
- **Session**: an OpenCode session id. Every run resumes it, so the worker keeps its conversation.
- **Brief**: a generated `AGENTS.md` with the assignment, the responsibilities, and a working method that follows the task type (see [Task-aware working loop](#task-aware-working-loop)).
- **State**: `<root>/<name>/` containing `meta.json`, `AGENTS.md`, `result.md`, `logs/`, `chats/`, and usually `workspace/`.

Each `run` or `chat send` invokes:

```sh
opencode run --format json --auto [--session <id>] -- <prompt>
```

The manager prints only the final assistant text. Raw JSONL events and stderr stay in `<worker>/logs/`, so the caller's context stays small.

State layout:

```text
<root>/
├── <worker>/
│   ├── meta.json            worker metadata, model, status, task
│   ├── AGENTS.md            generated worker brief
│   ├── AGENTS.custom.md     optional custom instructions
│   ├── workspace/           isolated workspace (worktree/copy/empty)
│   ├── logs/*.jsonl         OpenCode event stream
│   ├── result.md            last result
│   └── chats/<chat-id>.json turn ledger: deadline, result, approval
└── .semaphore/
    ├── state.json           max_concurrent, holders, waiters
    └── state.lock
```

## Chat budget

A chat is the unit of cost control for multi-turn delegation. It belongs to one worker, has a hard turn budget, and keeps a local ledger of every turn, including the expected result and deadline.

```sh
opencode-worker chat start --worker NAME --approved-by user|admin [options]
opencode-worker chat send --chat ID [options]
opencode-worker chat status --chat ID [--json]
opencode-worker chat list [--worker NAME] [--open] [--overdue] [--json]
opencode-worker chat close --chat ID
```

| Option | Description |
|---|---|
| `--worker NAME` | Worker that will receive the chat (required; must already exist). |
| `--approved-by user\|admin` | Who approved this chat (required). Stored with `approved_at`. |
| `--max-turns N` | Turn budget, 1–50 (default 10). |
| `--priority high\|normal\|low` | Queue priority (default `normal`). |
| `--session ID` | Link the chat to an existing OpenCode session. |
| `--note TEXT` | Free-text approval note. |
| `--expect TEXT` | What the turn should produce; shown in the ledger. |
| `--expect-within SEC` | Deadline for the turn; the ledger flags it as `OVERDUE`. |
| `--timeout SEC` | Hard timeout for the OpenCode process. |
| `--queue-timeout SEC` | How long to wait for a semaphore slot (default 300; `0` fails fast). |
| `--priority P` | Override the chat priority for one turn. |
| `--is-new-session true\|false` | Start fresh (first turn only) or resume the linked session. |
| `--wait` | Wait for the worker lock instead of failing when busy. |
| `--max-chars N` | Truncate the printed result; the full text stays in `result.md`. |
| `--json` | Machine-readable output. |

Each `chat send` consumes one turn **before** execution. Failed and timed-out turns still count. When the budget is exhausted the chat is marked `exhausted` and further sends exit 4. To continue the same OpenCode session, ask the user/admin to approve a new chat with `--session <id>`; do not bypass the budget.

## Commands

| Command | Purpose |
|---|---|
| `new NAME` | Create a worker (aliases: `create`). |
| `run NAME [TASK...]` | One-off unbudgeted run; auto-creates and resumes. |
| `chat start\|send\|status\|list\|close` | Budgeted conversations. |
| `agents NAME` | Show or regenerate the worker's `AGENTS.md`. |
| `semaphore status\|set` | Inspect or set the global concurrency limit. |
| `status NAME` | Query one worker's state. |
| `list [--all]` | List workers. |
| `session NAME` | Show a worker's session id. |
| `result NAME` | Print the last full result. |
| `logs NAME` | Show recent raw OpenCode events. |
| `diff NAME` | `--stat`, `--name-only`, or `--patch`. |
| `commit NAME -m MSG` | Commit workspace changes. |
| `close NAME` | Mark a worker closed (keeps workspace and session). |
| `destroy NAME` | Remove state/worktree. |
| `doctor [--models]` | Check the environment. |

### `new`

| Option | Description |
|---|---|
| `--source PATH` | Source directory to copy (default: current directory). |
| `--mode auto\|worktree\|copy\|empty` | Workspace strategy (default `auto`). |
| `--base REF` | Git base ref for worktree mode (default `HEAD`). |
| `--branch NAME` | Explicit branch name for worktree mode. |
| `--workspace PATH` | Explicit workspace path instead of the default. |
| `--model PROVIDER/MODEL` | OpenCode model stored on the worker. Default: `opencode/deepseek-v4.1-flash-free`. |
| `--agent NAME` | OpenCode agent (default `build`). |
| `--task TEXT` | Short assignment recorded in `meta.json` and `AGENTS.md`. |
| `--loop PROFILE` | Working loop written into `AGENTS.md` (default: `auto`, detected from the task text). |
| `--agents-file FILE` | Extra instructions copied to `<worker>/AGENTS.custom.md`. |
| `--copy-all` | Copy mode: do not skip caches such as `node_modules`. |
| `--force` | Allow copying the home directory or reusing a non-empty empty-mode workspace. |

Worker names are lowercase kebab-case.

### `agents`

```sh
opencode-worker agents NAME [--task TEXT] [--agents-file FILE] [--write] [--json]
```

Prints the worker's `AGENTS.md`. With `--write`, regenerates `<worker>/AGENTS.md` and the managed block in `<workspace>/AGENTS.md`; `--task` updates the assignment first, `--loop` pins the working loop, and `--agents-file` replaces `<worker>/AGENTS.custom.md`.

### Task-aware working loop

The template of `AGENTS.md` is fixed; the **working method** is not. It is derived from the
task text, so the loop the worker follows matches the kind of work:

| Profile | Picked for | The loop adds |
|---|---|---|
| `bugfix` | fix, bug, crash, failing, regression | reproduce first, name the root cause, add a test that fails before the fix |
| `feature` | implement, support, endpoint | acceptance criteria first, follow existing patterns, test the new path |
| `test` | test, spec, coverage, assertion | failing test first, cover the boundaries, keep the suite deterministic |
| `refactor` | refactor, extract, simplify, rename | behaviour baseline first, small steps, no drive-by changes |
| `perf` | performance, slow, optimize, latency | measure before and after, one change at a time, behaviour unchanged |
| `research` | investigate, analyze, compare, audit | turn it into questions, evidence first, separate fact from inference |
| `docs` | document, readme, changelog | the code wins over the docs, examples must run |
| `infra` | deploy, CI, pipeline, docker, release | reversible steps, reproduce first, rollback written down |
| `generic` | anything else | restate criteria, smallest change, run the checks |

```sh
opencode-worker new fix-auth --task "fix the failing auth tests"   # -> loop: bugfix
opencode-worker status fix-auth                                      # shows: loop: bugfix
opencode-worker new probe --task "fix the failing auth tests" --loop research
```

Every profile also gets its own **Definition of done** list, so the worker knows when it may
report completion. `agents NAME --task "..." --write` regenerates the brief after a task
change; a pinned `--loop` survives that.

### `run` / `send`

```sh
opencode-worker run NAME [TASK...] [options]
```

| Option | Description |
|---|---|
| `--source PATH` | Source for the auto-created workspace. |
| `--mode auto\|worktree\|copy\|empty` | Workspace strategy for the auto-created worker. |
| `--model PROVIDER/MODEL` | Override the stored model. |
| `--agent NAME` | Override the stored agent. |
| `--session ID` | Resume this exact OpenCode session. |
| `--new-session` | Start a new session instead of resuming. |
| `--no-create` | Fail instead of creating a missing worker. |
| `--timeout SEC` | Hard timeout for the OpenCode process. |
| `--wait` | Wait for the worker lock instead of failing when busy. |
| `--max-chars N` | Truncate the printed result (0 = no limit). |
| `--include-stderr` | Include OpenCode stderr in `--json` output. |
| `--json` | Machine-readable output. |

## Models and cost

Workers invoke `opencode run` directly and never read the caller's model or credentials. The default model is `opencode/deepseek-v4.1-flash-free`, a free OpenCode Zen model with cost 0 and no API key. Any other model works too:

```sh
opencode-worker new w1 --model opencode/deepseek-v4.1-flash-free
opencode-worker run w1 "..."
```

`doctor --models` lists the models the local OpenCode CLI can use.

## Token and context discipline

- The manager prints only the final assistant text. Full event streams stay in `<worker>/logs/`.
- `--max-chars` bounds what enters the caller's context; `result.md` keeps the full text.
- Give the worker a narrow brief and ask for a short summary with file paths, not pasted files or logs.

## Long-running tasks

The caller's shell tool has its own timeout; run long delegations as background jobs and collect them with the caller's job tool (dsh: `run_in_background: true` + `job_output`; OpenCode: background shell). The script's `--timeout` is a separate safety kill for the OpenCode process. A timeout kills the client, not necessarily the OpenCode server's in-flight turn, so treat a timed-out run as uncertain and inspect the workspace before trusting the result.

## Safety

- `opencode run --auto` grants full file and shell permissions. The workspace isolates context, not the machine.
- Review `diff --patch` before merging or applying changes.
- `destroy` refuses a live run and a dirty worktree without `--force`.
- Uncommitted source changes are not copied into a worktree; commit or stash first, or use copy mode.
- Workers cannot create or drive other workers; nested `new`/`run`/`chat` calls are refused inside a worker.

## Environment variables

| Variable | Purpose |
|---|---|
| `DSH_OPENCODE_WORKERS` | Worker root override. |
| `OPENCODE_BIN` | OpenCode binary override. |
| `DSH_HOME` | Base directory for the default root. |
| `DSH_OPENCODE_WORKER_DEPTH` | Nesting depth set by the manager for each worker; normally not set by hand. |
| `DSH_OPENCODE_WORKER_NAME` | Worker name injected into a worker's OpenCode environment. |
| `DSH_OPENCODE_WORKER_CLI` | Path of this manager, injected for the worker. |
| `DSH_OPENCODE_WORKER_ROOT` | Worker root, injected for the worker. |
| `DSH_OPENCODE_ALLOW_NESTED` | `1` disables the worker-to-worker delegation guard; use only for a deliberate lead-worker setup. |

Default root: `~/.dsh/opencode-workers`. Shared state is stored under `<root>/.semaphore/`; it is per root, not per worker.

## Troubleshooting

| Symptom | Action |
|---|---|
| `opencode executable not found` | Run `doctor`; install OpenCode or set `OPENCODE_BIN`. |
| `chat ... quota exhausted` | Ask the user/admin for a new approved chat with `--session <id>`; do not bypass the budget. |
| `timed out ... semaphore slot` | Check `semaphore status`; wait, raise `--queue-timeout`, or use another worker. |
| `worker ... already exists` | Use another name or `destroy` the old worker. |
| `worker ... is busy` | Wait, pass `--wait`, or use another worker. |
| Status `interrupted` | The runner died or was killed. Run again to resume the session and workspace. |
| `disabled inside an OpenCode worker` | Worker-to-worker delegation is off; the calling agent stays the orchestrator. |
| Auth/provider error | Retry with a free model via `--model opencode/<name>-free`; otherwise fix OpenCode config. |

## Testing

```sh
cd tests
./run.sh                              # deterministic suite + real-model suite
./e2e-simple.sh                       # 65 checks, no model cost
MODEL=opencode/deepseek-v4.1-flash-free ./e2e-real-simple.sh   # 20 checks
```

The deterministic suite uses a fake OpenCode CLI (`tests/fake-opencode`) and an isolated root,
so it needs no model and never touches the default worker root. When the model provider
refuses a request (free quota exhausted), the real-model suite reports `SKIPPED` (exit 77)
instead of failing.
## Uninstall

```sh
rm -rf ~/.config/opencode/skills/opencode-worker   # OpenCode
rm -rf ~/.dsh/skills/opencode-worker                # dsh
rm -rf ~/.dsh/opencode-workers                      # all worker state (default worktrees are removed; branches remain)
```
