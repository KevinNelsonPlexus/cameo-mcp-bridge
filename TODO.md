# Outstanding TODOs

Tracks known follow-up work that hasn't been resolved yet.

## Open

- **Diagnose `mcp` dependency breakage above 2.0.0**
  `mcp-server/pyproject.toml` currently pins `mcp>=1.0.0,<2.0.0` because
  installing a newer `mcp` release broke the `cameo-mcp` server (root cause
  not yet diagnosed). Investigate what changed in `mcp>=2.0.0` that breaks
  `cameo_mcp/server.py` or `cameo_mcp/client.py`, fix compatibility, and
  remove/relax the upper bound.
