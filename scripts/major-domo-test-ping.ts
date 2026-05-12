/**
 * One-shot: ask Quill to post a brief test greeting to the Rosedale group.
 * Not idempotent — each run inserts a fresh task.
 */
import path from 'path';

import { DATA_DIR } from '../src/config.js';
import { getAgentGroupByFolder } from '../src/db/agent-groups.js';
import { getDb, initDb } from '../src/db/connection.js';
import { runMigrations } from '../src/db/migrations/index.js';
import { getSessionsByAgentGroup } from '../src/db/sessions.js';
import { log } from '../src/log.js';
import { insertTask } from '../src/modules/scheduling/db.js';
import { openInboundDb } from '../src/session-manager.js';

initDb(path.join(DATA_DIR, 'v2.db'));
runMigrations(getDb());

const ag = getAgentGroupByFolder('major-domo');
if (!ag) {
  log.error('no major-domo agent group');
  process.exit(1);
}
const sessions = getSessionsByAgentGroup(ag.id);
const session = sessions.find((s) => s.status === 'active') ?? sessions[sessions.length - 1];
if (!session) {
  log.error('no session');
  process.exit(1);
}

const inDb = openInboundDb(ag.id, session.id);
try {
  const id = `test-ping-${Date.now()}`;
  insertTask(inDb, {
    id,
    processAfter: new Date().toISOString(),
    recurrence: null,
    platformId: 'telegram:-5058623387',
    channelType: 'telegram',
    threadId: null,
    content: JSON.stringify({
      prompt:
        'SYSTEM: This is a one-time channel-verification ping from the operator. Post a single sentence in your butler voice to the family group greeting the household and confirming that you are at your post. Do not ask any questions; do not list capabilities; do not save anything to the notebook.',
      script: null,
    }),
  });
  log.info('Test ping scheduled', { id, sessionId: session.id });
} finally {
  inDb.close();
}
