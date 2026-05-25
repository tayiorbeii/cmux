# Agent hook integrations

cmux uses agent hooks to show running state, Feed approvals, notifications, and to restore agent sessions after a normal app relaunch.

Claude Code is handled by the cmux Claude wrapper when Claude Code integration is enabled in Settings. Other agents are installed with:

```bash
cmux hooks setup
cmux hooks setup <agent>
cmux hooks setup --agent <agent>
cmux hooks uninstall <agent>
```

Supported agent names are `codex`, `opencode`, `pi`, `amp`, `cursor`, `gemini`, `rovodev` (or `rovo`), `copilot`, `codebuddy`, `factory`, and `qoder`. `cmux hooks setup` skips agents whose binary is not on `PATH` and prints a summary.

## Integrations

| Agent | Binary checked | Installed file | Session restore | Feed bridge |
| --- | --- | --- | --- | --- |
| Claude Code | `claude` through wrapper | wrapper-injected settings | `claude --resume <id>` | PermissionRequest |
| Codex | `codex` | `~/.codex/hooks.json`, `~/.codex/config.toml` | `codex resume <id>` | PreToolUse, PermissionRequest |
| OpenCode | `opencode` | `~/.config/opencode/plugins/cmux-session.js`, `~/.config/opencode/plugins/cmux-feed.js` | `opencode --session <id>` | plugin event bus |
| Pi | `pi` | `~/.pi/agent/extensions/cmux-session.ts` | `pi --session <id>` | none |
| Amp | `amp` | `~/.config/amp/plugins/cmux-session.ts` | `amp threads continue <id>` | none |
| Cursor CLI | `cursor-agent` | `~/.cursor/hooks.json` | `cursor-agent --resume <id>` | beforeShellExecution |
| Gemini | `gemini` | `~/.gemini/settings.json` | `gemini --resume <id>` | PreToolUse |
| Rovo Dev | `acli` | `~/.rovodev/config.yml` | `acli rovodev run --restore <id>` | none |
| Copilot | `copilot` | `~/.copilot/config.json` | `copilot --resume <id>` | PreToolUse |
| CodeBuddy | `codebuddy` | `~/.codebuddy/settings.json` | `codebuddy --resume <id>` | PreToolUse |
| Factory | `droid` | `~/.factory/settings.json` | `droid --resume <id>` | PreToolUse |
| Qoder | `qodercli` | `~/.qoder/settings.json` | `qodercli --resume <id>` | PreToolUse |

OpenCode also supports project-local Feed installation:

```bash
cmux hooks opencode install --project
```

That writes `.opencode/plugins/cmux-feed.js` in the current directory.

## What the hooks record

Session hooks write `~/.cmuxterm/<agent>-hook-sessions.json`. Each entry stores the agent session ID, cmux workspace ID, surface ID, cwd, process ID when available, and a sanitized launch command. On app relaunch, cmux rebuilds each workspace and runs the agent's native resume command with the saved session ID.

The sanitizer preserves model, sandbox, config, and cwd-related flags. It drops prompts, credentials, old session selectors, and noninteractive commands so relaunch resumes the session instead of starting a new task or leaking secrets.

## Disable automatic resume

To restore panes without automatically restarting saved agent sessions, turn off
**Settings > Terminal > Resume Agent Sessions on Reopen**.

You can also set the same preference in `~/.config/cmux/cmux.json`:

```json
{
  "terminal": {
    "autoResumeAgentSessions": false
  }
}
```

When this is off, cmux still restores the saved window, workspace, pane, scrollback,
and browser state. Restored agent terminals stay idle until you resume them manually.

## tmux alerts and pane navigation

cmux understands tmux alert hooks when they call the feed bridge with `--source tmux-bridge`. Install the managed hooks with:

```bash
cmux hooks tmux install
```

The installer only removes/replaces hook entries containing cmux's `cmux-tmux-bridge` marker before appending its own hooks; it does not clear unrelated user tmux hooks. tmux must still have the relevant alert monitors enabled (`monitor-bell`, `monitor-activity`, and/or `monitor-silence`) for activity and silence hooks to fire. To remove the managed entries, run:

```bash
cmux hooks tmux uninstall
```

Equivalent manual tmux hooks (use `-a` so existing hooks are preserved; keep the marker if you want `cmux hooks tmux uninstall` to remove them later):

```tmux
set -g monitor-bell on
set -g monitor-activity on
set -g monitor-silence 15
set-hook -g -a alert-bell 'run-shell -b "cmux hooks feed --source tmux-bridge --event bell --pane-id #{q:pane_id} --pane-tty #{q:pane_tty} --session #{q:session_name} --window #{q:window_index} --pane #{q:pane_index} --command #{q:pane_current_command} # cmux-tmux-bridge"'
set-hook -g -a alert-activity 'run-shell -b "cmux hooks feed --source tmux-bridge --event activity --pane-id #{q:pane_id} --pane-tty #{q:pane_tty} --session #{q:session_name} --window #{q:window_index} --pane #{q:pane_index} --command #{q:pane_current_command} # cmux-tmux-bridge"'
set-hook -g -a alert-silence 'run-shell -b "cmux hooks feed --source tmux-bridge --event silence --pane-id #{q:pane_id} --pane-tty #{q:pane_tty} --session #{q:session_name} --window #{q:window_index} --pane #{q:pane_index} --command #{q:pane_current_command} # cmux-tmux-bridge"'
```

The bridge preserves the inner tmux pane metadata (`pane_id`, `pane_tty`, session/window/pane, and current command) but routes the notification by the outer tmux client TTY when available. If the cmux workspace/surface environment is present it is still passed as an explicit preference; otherwise cmux falls back through caller TTY, the remembered tmux-pane route table, and finally the selected workspace.

Agent lifecycle/status hooks use the same caller-aware path (`status.set_for_caller`, also available as `set_status_for_caller`) and no longer require `CMUX_SURFACE_ID` when running inside tmux. Notifications use `notification.create_for_caller`. These APIs accept `preferred_workspace_id`, `preferred_surface_id`, `caller_tty`, `prefer_tty`, `allow_selected_fallback`, and tmux pane metadata (`tmux_pane_id`, `tmux_pane_tty`, `tmux_session`, `tmux_window`, `tmux_pane`, `tmux_command`). The generated hooks pass caller TTY plus tmux pane metadata so Claude/Codex/Gemini/Cursor/Copilot/CodeBuddy/Factory/Qoder status changes can land on the embedded cmux surface even when tmux strips or stales the original cmux environment.

**Settings > Terminal > tmux-Aware Pane Navigation** enables the native Focus Pane shortcuts (Cmd+Option+Arrow by default), Option+h/j/k/l, and Ghostty split navigation to move inside tmux first. When tmux reports `pane_at_left`, `pane_at_right`, `pane_at_top`, or `pane_at_bottom`, cmux falls through to native split focus. Focus Pane shortcuts remain configurable in **Keyboard Shortcuts** or `cmux.json`.

## Environment overrides

| Agent | Config directory override | Disable cmux hooks for one process |
| --- | --- | --- |
| Codex | `CODEX_HOME` | `CMUX_CODEX_HOOKS_DISABLED=1` |
| OpenCode | `OPENCODE_CONFIG_DIR` | `CMUX_OPENCODE_HOOKS_DISABLED=1` |
| Pi | `PI_CODING_AGENT_DIR` | `CMUX_PI_HOOKS_DISABLED=1` |
| Amp | none | `CMUX_AMP_HOOKS_DISABLED=1` |
| Cursor CLI | none | `CMUX_CURSOR_HOOKS_DISABLED=1` |
| Gemini | none | `CMUX_GEMINI_HOOKS_DISABLED=1` |
| Rovo Dev | none | `CMUX_ROVODEV_HOOKS_DISABLED=1` |
| Copilot | `COPILOT_HOME` | `CMUX_COPILOT_HOOKS_DISABLED=1` |
| CodeBuddy | `CODEBUDDY_CONFIG_DIR` | `CMUX_CODEBUDDY_HOOKS_DISABLED=1` |
| Factory | none | `CMUX_FACTORY_HOOKS_DISABLED=1` |
| Qoder | `QODER_CONFIG_DIR` | `CMUX_QODER_HOOKS_DISABLED=1` |

Pi uses Pi's extension system, not the legacy Pi hooks API. The installed extension is auto-discovered from `~/.pi/agent/extensions/` or `$PI_CODING_AGENT_DIR/extensions/`.

## Troubleshooting

Run `cmux hooks <agent> install --yes` to reinstall one integration. Run `cmux hooks <agent> uninstall --yes` before editing generated files by hand.

If Feed shows nothing, confirm the terminal has `CMUX_SURFACE_ID` and the hook file contains a `cmux hooks feed --source <agent>` command or OpenCode feed plugin. Pi, Rovo Dev, and Amp currently provide lifecycle and restore hooks only, so they do not create Feed approval cards.

If relaunch does not resume an agent, check `~/.cmuxterm/<agent>-hook-sessions.json` for the saved session and verify the agent's resume command still works outside cmux.
