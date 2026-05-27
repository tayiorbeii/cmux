# Autoresearch Ideas — tmux notification passthrough

## Completed in this session
- Ghostty DCS tmux passthrough handler (OSC 777 + OSC 9)
- Bell notification suppression when OSC 777 arrives
- `cmux notify-terminal` command (full feature parity with `cmux notify`)
- `cmux notify` tmux socket-failure fallback with tmux-aware defaults
- terminal-notifier shim for OMO
- Docs updated with CLI recommendations
- Claude hook Notification event fallback (hooks feed → notify-terminal)
- OSC 777 notification deduplication (1s cooldown keyed by tab+title)
- tmux-aware default title/subtitle/body in cmux notify tmux fallback

## Future improvements
- **Ghostty upstream contribution**: The DCS tmux passthrough handler is local to the cmux fork. Consider contributing it upstream to Ghostty so all terminal emulators benefit from tmux notification passthrough.
- **OSC 99 support**: Add OSC 99 (iTerm2 semantic notifications) support to `notify-terminal` and the Ghostty passthrough handler for richer notification metadata (subtitle, actions, etc.).
- **tmux bridge hook terminal escape fallback**: When bridge hooks fail to reach the socket, emit a `notify-terminal` escape. Currently not feasible because tmux would consume the escape sequence from its own `run-shell` context, but could work if Ghostty adds support for unwrapping DCS passthrough from tmux hook output.
- **WebSocket notification channel**: Add a WebSocket-based notification path so processes inside real tmux can send rich notifications without requiring a local socket file (useful for remote tmux sessions).
