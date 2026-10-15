---
description: Log this session's work in the Obsidian vault
argument-hint: "[what to log]"
disable-model-invocation: true
allowed-tools: Bash(node:*)
---

Log the work of this session in the Obsidian vault, through the `obsidian` MCP tools only.

What to log: $ARGUMENTS
If nothing is named above, log the work since the last log, as this conversation shows it. Always log.

!`node "${CLAUDE_PLUGIN_ROOT}/hooks/worklog.mjs" procedure`
