# AI activity in the island

NotchShot ships a small local command named `notchshot-ai`. Claude Code,
Codex, Cursor, shell scripts, and build tools can use it to publish a task's
state into the island. The command writes owner-only JSON files under
`~/Library/Application Support/NotchShot/AI Activity`; it does not use the
network, inspect another app's UI, or parse a transcript during normal hook
activity. The Claude conversation control is a separate, on-demand local read.

The installed reporter is normally here:

```text
/Applications/NotchShot.app/Contents/MacOS/notchshot-ai
```

Settings → Context Modules → AI activity can reveal the status folder or copy
the reporter path. The Claude, Codex, and Cursor buttons on that screen perform
an explicit preserving merge, back up an existing configuration, and never
replace unrelated hooks. Codex's button also enables `[features].codex_hooks`
without changing existing `notify` or other TOML settings. A locally built app uses
`dist/NotchShot.app/Contents/MacOS/notchshot-ai` instead.

## Try it directly

```bash
REPORTER="/Applications/NotchShot.app/Contents/MacOS/notchshot-ai"

"$REPORTER" update \
  --source codex \
  --state working \
  --id export-fix \
  --title "Fixing image export" \
  --detail "Running regression tests" \
  --progress 60 \
  --step completed:Inspect \
  --step working:Test

"$REPORTER" update --source codex --state finished \
  --id export-fix --title "Image export fixed" --progress 100

"$REPORTER" clear --source codex --id export-fix

# Wrap a real build or script. The child exit status is preserved.
"$REPORTER" run --title "Swift build" -- swift build
"$REPORTER" run --title "Xcode tests" -- xcodebuild test -scheme NotchShot
"$REPORTER" run --title "Web checks" -- npm test
```

Progress is optional. When a source does not report a real percentage, the
island shows an indeterminate state instead of estimating one. Active records
become stale after 30 minutes without an update; finished and failed records
remain visible for 45 seconds.

## Connect an AI coding tool

All three supported tools run command hooks with event JSON on standard input.
Use the same command for each lifecycle event you want to surface:

```text
/Applications/NotchShot.app/Contents/MacOS/notchshot-ai hook --source SOURCE
```

The reporter uses only the event name, session id, current working-directory
name, prompt title, and tool name. It deliberately ignores transcript paths,
tool input, tool output, and assistant messages on the hook path. Claude's
permission event uses the same local socket to wait for an Allow or Deny action;
the response contains only the decision and an optional bounded reason.

Do not replace an existing hooks file. Add the handler to its existing event
arrays so current formatters, notifications, and policy hooks keep working.

### Codex

Codex reads `~/.codex/hooks.json` and project-local `.codex/hooks.json`. A
minimal user hook can add the reporter to `UserPromptSubmit`, `SessionStart`,
`PreToolUse`, `PostToolUse`, and `Stop`:

```json
{
  "description": "Show Codex lifecycle state in NotchShot.",
  "hooks": {
    "UserPromptSubmit": [{ "hooks": [{ "type": "command", "command": "/Applications/NotchShot.app/Contents/MacOS/notchshot-ai hook --source codex", "timeout": 3 }] }],
    "PreToolUse": [{ "hooks": [{ "type": "command", "command": "/Applications/NotchShot.app/Contents/MacOS/notchshot-ai hook --source codex", "timeout": 3 }] }],
    "SessionStart": [{ "hooks": [{ "type": "command", "command": "/Applications/NotchShot.app/Contents/MacOS/notchshot-ai hook --source codex", "timeout": 3 }] }],
    "PostToolUse": [{ "hooks": [{ "type": "command", "command": "/Applications/NotchShot.app/Contents/MacOS/notchshot-ai hook --source codex", "timeout": 3 }] }],
    "Stop": [{ "hooks": [{ "type": "command", "command": "/Applications/NotchShot.app/Contents/MacOS/notchshot-ai hook --source codex", "timeout": 3 }] }]
  }
}
```

Review and trust the new command with `/hooks`. This is separate from Codex's
legacy `notify` setting, so an existing notification command does not need to be
removed or replaced. See the official [Codex hooks reference](https://learn.chatgpt.com/docs/hooks).

### Claude Code

Claude Code uses the same event → matcher group → command handler shape in
`~/.claude/settings.json`. Add the reporter command above with source `claude`
to `SessionStart`, `UserPromptSubmit`, `PreToolUse`, `PermissionRequest`,
`PostToolUse`, `PostToolUseFailure`, `PermissionDenied`, `Notification`, `Stop`,
`StopFailure`, `PreCompact`, `PostCompact`, and `SessionEnd`. See the official
[Claude Code hooks reference](https://code.claude.com/docs/en/hooks) for the
settings scopes and merge rules.

When Claude hooks are connected and the Claude source is enabled, NotchShot
listens on `/tmp/notchshot-claude.sock` with owner-only permissions. The expanded
Claude activity card lists live sessions, keeps a PermissionRequest visible, and
returns Claude's documented `hookSpecificOutput` decision after Allow or Deny.
The conversation button reads at most 4 MB of the matching local JSONL file on
demand, shows at most 80 visible messages, and does not persist the transcript.

### Cursor

Cursor uses a flatter command list in `~/.cursor/hooks.json` or a project's
`.cursor/hooks.json`:

```json
{
  "version": 1,
  "hooks": {
    "beforeSubmitPrompt": [{ "command": "/Applications/NotchShot.app/Contents/MacOS/notchshot-ai hook --source cursor" }],
    "preToolUse": [{ "command": "/Applications/NotchShot.app/Contents/MacOS/notchshot-ai hook --source cursor" }],
    "postToolUseFailure": [{ "command": "/Applications/NotchShot.app/Contents/MacOS/notchshot-ai hook --source cursor" }],
    "stop": [{ "command": "/Applications/NotchShot.app/Contents/MacOS/notchshot-ai hook --source cursor" }],
    "sessionEnd": [{ "command": "/Applications/NotchShot.app/Contents/MacOS/notchshot-ai hook --source cursor" }]
  }
}
```

Cursor reloads the file after it changes and exposes hook diagnostics in its
Hooks output channel. See the official [Cursor hooks reference](https://cursor.com/docs/hooks).

## Honest limitations

- Lifecycle hooks report state transitions, not a model's hidden reasoning.
- Tool hooks do not provide a trustworthy percentage or time remaining. Use
  `update --progress` only when your own workflow has a measured total.
- NotchShot changes global AI-tool settings only after the user presses a named
  Connect button and confirms the merge. Existing files are backed up first.
- A hook records the prompt title so the island can identify the task. Disable
  AI activity or omit prompt hooks if even a short local title is too sensitive.
