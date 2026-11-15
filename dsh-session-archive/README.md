# @dsh-web/session-archive

Host-only DSH plugin that restores a cold session log before the stock
`sessionPersistence.open` reads it.

`state.sh` replaces archived session logs with a header-only stub and writes
`$DSH_HOME/.session-archive/index.json`. This plugin reads that index at load,
and for an indexed session calls the local `session-archive-agent` over a Unix
socket. The agent downloads the archive asset from the private state release,
verifies its SHA-256, extracts it, and replaces the stub. The plugin then
delegates to the original `open`, so the Web, SDK, and ACP paths all load the
full history.

The agent socket path comes from `DSH_SESSION_ARCHIVE_SOCKET`. If the session
is not indexed, or the variable is absent, the plugin delegates unchanged.
