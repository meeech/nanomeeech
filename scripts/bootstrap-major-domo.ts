/**
 * Bootstrap the Major Domo agent's scheduled importers + daily briefing.
 *
 * Idempotent: cancels any existing series with the well-known ids before
 * re-inserting fresh rows. Touches the notebook.db file so the MCP tool's
 * lazy CREATE TABLE has a writable file on the host side.
 *
 * Usage:
 *   pnpm exec tsx scripts/bootstrap-major-domo.ts
 *
 * Sets up four recurring tasks on the major-domo agent group's session:
 *   - md-weather-refresh   (every 6h)     refresh weather forecast
 *   - md-calendar-refresh  (every 6h)     refresh calendar events (stub)
 *   - md-fun-fact          (Mon 8am)      pick a weekly fun fact
 *   - md-daily-briefing    (every 7am)    compose + send the morning briefing
 *
 * First runs:
 *   - importers fire 30–90s from now to seed the notebook immediately.
 *   - briefing fires at the next 7am America/Toronto.
 */
import fs from 'fs';
import path from 'path';

import { CronExpressionParser } from 'cron-parser';

import { DATA_DIR, GROUPS_DIR, TIMEZONE } from '../src/config.js';
import { getAgentGroupByFolder } from '../src/db/agent-groups.js';
import { getDb, initDb } from '../src/db/connection.js';
import { runMigrations } from '../src/db/migrations/index.js';
import { getSessionsByAgentGroup } from '../src/db/sessions.js';
import { log } from '../src/log.js';
import { cancelTask, insertTask } from '../src/modules/scheduling/db.js';
import { openInboundDb } from '../src/session-manager.js';

const MAJOR_DOMO_FOLDER = 'major-domo';
const ROSEDALE_GROUP_PLATFORM_ID = 'telegram:-5058623387';
const CHANNEL_TYPE = 'telegram';

interface TaskSpec {
  id: string;
  prompt: string;
  recurrence: string;
  firstRunDelaySec?: number; // if set, processAfter = now + delaySec
  // otherwise the next firing of `recurrence` (interpreted in TIMEZONE) is used
}

const TASKS: TaskSpec[] = [
  {
    id: 'md-weather-refresh',
    prompt: 'IMPORTER: refresh weather forecast',
    recurrence: '0 */6 * * *',
    firstRunDelaySec: 30,
  },
  {
    id: 'md-calendar-refresh',
    prompt: 'IMPORTER: refresh calendar events',
    recurrence: '0 */6 * * *',
    firstRunDelaySec: 90,
  },
  {
    id: 'md-fun-fact',
    prompt: 'IMPORTER: pick a fun fact for the week',
    recurrence: '0 8 * * 1',
    // first run = next Monday 8am Toronto, per cron
  },
  {
    id: 'md-daily-briefing',
    prompt: 'BRIEFING: compose and send the morning briefing',
    recurrence: '0 7 * * *',
    // first run = next 7am Toronto, per cron
  },
];

function nextCronFiring(expr: string): string {
  const interval = CronExpressionParser.parse(expr, { tz: TIMEZONE });
  return interval.next().toDate().toISOString();
}

function delayFromNow(seconds: number): string {
  return new Date(Date.now() + seconds * 1000).toISOString();
}

function main(): void {
  initDb(path.join(DATA_DIR, 'v2.db'));
  runMigrations(getDb());

  const agentGroup = getAgentGroupByFolder(MAJOR_DOMO_FOLDER);
  if (!agentGroup) {
    log.error(`No agent group with folder "${MAJOR_DOMO_FOLDER}". Run /manage-channels first.`);
    process.exit(1);
  }

  // 1. Ensure notebook.db exists (empty file; schema is lazy via the MCP tool).
  const notebookPath = path.join(GROUPS_DIR, MAJOR_DOMO_FOLDER, 'notebook.db');
  if (!fs.existsSync(notebookPath)) {
    fs.closeSync(fs.openSync(notebookPath, 'w'));
    log.info(`Created empty notebook.db at ${notebookPath}`);
  } else {
    log.info(`notebook.db already exists at ${notebookPath}`);
  }

  // 2. Locate the agent group's session bound to the Rosedale group.
  const sessions = getSessionsByAgentGroup(agentGroup.id);
  if (sessions.length === 0) {
    log.error(`No sessions for agent group ${agentGroup.id}. The session is created when the agent is first wired.`);
    process.exit(1);
  }
  // Prefer the active session bound to the Rosedale group.
  const session =
    sessions.find((s) => s.status === 'active') ?? sessions[sessions.length - 1];
  log.info('Using session', { sessionId: session.id, messagingGroupId: session.messaging_group_id });

  // 3. Open the session's inbound.db (host writer).
  const inDb = openInboundDb(agentGroup.id, session.id);

  try {
    for (const task of TASKS) {
      // Idempotent: cancel any existing row in the series.
      cancelTask(inDb, task.id);

      const processAfter =
        task.firstRunDelaySec !== undefined
          ? delayFromNow(task.firstRunDelaySec)
          : nextCronFiring(task.recurrence);

      insertTask(inDb, {
        id: task.id,
        processAfter,
        recurrence: task.recurrence,
        platformId: ROSEDALE_GROUP_PLATFORM_ID,
        channelType: CHANNEL_TYPE,
        threadId: null,
        content: JSON.stringify({ prompt: task.prompt, script: null }),
      });
      log.info('Scheduled task', { id: task.id, processAfter, recurrence: task.recurrence });
    }
  } finally {
    inDb.close();
  }

  log.info('Bootstrap complete. The host sweep (60s) will wake the agent at each task firing.');
}

main();
