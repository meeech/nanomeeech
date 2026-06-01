#!/usr/bin/env bun
/**
 * slack-read — read Slack messages you weren't @-mentioned on.
 *
 * Auth is handled by the OneCLI gateway: this script holds no token. It just
 * calls the real Slack Web API and the gateway injects the bot credential for
 * `slack.com` (requires a `slack.com` secret assigned to this agent).
 *
 * By default it auto-detects the channel + thread you're currently in from the
 * latest inbound message in inbound.db, so a bare invocation reads the thread
 * the user just pinged you in — including the root message they started the
 * thread on (the colleague's message you weren't tagged on).
 *
 *   bun /app/skills/slack-read/read.ts            # current thread (root + replies)
 *   bun /app/skills/slack-read/read.ts --channel  # recent messages in this channel
 *   bun /app/skills/slack-read/read.ts --limit 50
 *   bun /app/skills/slack-read/read.ts --id C0B327Z494N --ts 1780346961.939119
 */
import { Database } from 'bun:sqlite';

const SLACK_API = 'https://slack.com/api';
const INBOUND = '/workspace/inbound.db';

function flag(name: string): string | undefined {
  const i = process.argv.indexOf(name);
  return i >= 0 ? process.argv[i + 1] : undefined;
}
const wantChannel = process.argv.includes('--channel');
const limit = Number(flag('--limit') ?? '20');

// Explicit overrides win; otherwise auto-detect from the triggering message.
let channel = flag('--id');
let ts = flag('--ts');

if (!channel || !ts) {
  try {
    const db = new Database(INBOUND, { readonly: true });
    const row = db
      .query(
        `SELECT platform_id, thread_id FROM messages_in
         WHERE channel_type = 'slack' AND platform_id LIKE 'slack:%'
         ORDER BY rowid DESC LIMIT 1`,
      )
      .get() as { platform_id: string | null; thread_id: string | null } | undefined;
    db.close();
    if (row) {
      // platform_id: "slack:C0B327Z494N" ; thread_id: "slack:C0B327Z494N:<ts>"
      channel ||= row.platform_id?.split(':')[1] || undefined;
      if (!ts && row.thread_id?.startsWith('slack:')) {
        ts = row.thread_id.split(':').slice(2).join(':') || undefined;
      }
    }
  } catch (e) {
    // fall through — we'll error below if we still lack a channel
  }
}

if (!channel) {
  console.error(
    'Could not determine the Slack channel. Pass --id <channel> (and --ts <thread_ts> for a thread).',
  );
  process.exit(1);
}

// Thread read needs a root ts; without one (or with --channel) read channel history.
const useHistory = wantChannel || !ts;
const url = useHistory
  ? `${SLACK_API}/conversations.history?channel=${channel}&limit=${limit}`
  : `${SLACK_API}/conversations.replies?channel=${channel}&ts=${ts}&limit=${limit}`;

// curl is the gateway-blessed path: it honours HTTPS_PROXY + CURL_CA_BUNDLE,
// both set in the container, so the gateway injects auth transparently.
const proc = Bun.spawnSync(['curl', '-s', url]);
const body = proc.stdout.toString();

let data: any;
try {
  data = JSON.parse(body);
} catch {
  console.error('Unexpected response from Slack (not JSON):');
  console.error(body.slice(0, 500));
  process.exit(1);
}

if (!data.ok) {
  console.error(`Slack API error: ${data.error}`);
  if (data.error === 'not_authed' || data.error === 'invalid_auth') {
    console.error('The gateway did not inject a slack.com credential for this agent.');
  }
  process.exit(1);
}

const msgs: any[] = data.messages ?? [];
// history returns newest-first; replies returns oldest-first. Normalise to oldest-first.
const ordered = useHistory ? msgs.slice().reverse() : msgs;

console.log(
  `# ${useHistory ? 'Channel' : 'Thread'} ${channel}${ts && !useHistory ? ` @ ${ts}` : ''} — ${ordered.length} message(s)\n`,
);
for (const m of ordered) {
  const who = m.user ?? m.username ?? m.bot_id ?? 'unknown';
  const when = m.ts ? new Date(Number(m.ts) * 1000).toISOString().replace('T', ' ').slice(0, 19) : '';
  console.log(`[${when}] ${who}: ${(m.text ?? '').trim()}`);
}
