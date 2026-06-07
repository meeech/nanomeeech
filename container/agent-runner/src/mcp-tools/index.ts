/**
 * MCP tools barrel — imports each tool module for its side-effect
 * `registerTools([...])` call, then starts the MCP server.
 *
 * Adding a new tool module: create the file, call `registerTools([...])`
 * at module scope, and append the import here. No central list.
 */
import { loadConfig } from '../config.js';
import './core.js';
import './scheduling.js';
import './interactive.js';
import './agents.js';
import './self-mod.js';
import './notebook.js';
import './weather.js';
import './calendar.js';
import { startMcpServer } from './server.js';

function log(msg: string): void {
  console.error(`[mcp-tools] ${msg}`);
}

// The MCP server runs in its own Bun subprocess (spawned from index.ts), so
// it has a separate module graph from the main agent-runner. Load config here
// so tool handlers can call getConfig() — e.g. messages-out.ts uses it to
// strip the agent-group suffix from inbound message ids.
loadConfig();

startMcpServer().catch((err) => {
  log(`MCP server error: ${err instanceof Error ? err.message : String(err)}`);
  process.exit(1);
});
