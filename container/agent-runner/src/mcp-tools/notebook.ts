/**
 * Notebook MCP tools — Stevens-style single-table household memory.
 *
 * Persists at /workspace/agent/notebook.db (mounted from groups/<folder>/).
 * One table `entries` with optional `date_for` (NULL = background) plus
 * `source` for provenance ('chat' | 'calendar' | 'weather' | 'fun-fact'
 * | 'briefing' | 'manual'). Schema is created lazily on first call.
 */
import { Database } from 'bun:sqlite';

import { registerTools } from './server.js';
import type { McpToolDefinition } from './types.js';

const NOTEBOOK_PATH = '/workspace/agent/notebook.db';

let _db: Database | null = null;

function getDb(): Database {
  if (_db) return _db;
  const db = new Database(NOTEBOOK_PATH);
  db.exec('PRAGMA journal_mode = DELETE');
  db.exec('PRAGMA busy_timeout = 5000');
  db.exec(`
    CREATE TABLE IF NOT EXISTS entries (
      id           INTEGER PRIMARY KEY AUTOINCREMENT,
      created_at   TEXT NOT NULL DEFAULT (datetime('now')),
      source       TEXT NOT NULL,
      source_user  TEXT,
      date_for     TEXT,
      content      TEXT NOT NULL,
      tags         TEXT
    );
    CREATE INDEX IF NOT EXISTS idx_entries_date_for ON entries(date_for);
    CREATE INDEX IF NOT EXISTS idx_entries_source   ON entries(source);
  `);
  _db = db;
  return db;
}

function ok(text: string) {
  return { content: [{ type: 'text' as const, text }] };
}

function err(text: string) {
  return { content: [{ type: 'text' as const, text: `Error: ${text}` }], isError: true };
}

interface EntryRow {
  id: number;
  created_at: string;
  source: string;
  source_user: string | null;
  date_for: string | null;
  content: string;
  tags: string | null;
}

function formatRows(rows: EntryRow[]): string {
  if (rows.length === 0) return '(no entries)';
  return rows
    .map((r) => {
      const date = r.date_for ?? '(background)';
      const who = r.source_user ? ` <${r.source_user}>` : '';
      const tags = r.tags ? ` [${r.tags}]` : '';
      return `#${r.id} ${date} ${r.source}${who}${tags}: ${r.content}`;
    })
    .join('\n');
}

export const notebookAdd: McpToolDefinition = {
  tool: {
    name: 'notebook_add',
    description:
      'Append one row to the household notebook. Use `date_for` (ISO YYYY-MM-DD) when the entry is anchored to a specific day; leave null for background/always-relevant facts. `source` is required for provenance.',
    inputSchema: {
      type: 'object' as const,
      properties: {
        content: { type: 'string', description: 'The note itself — concise, factual, written in the third person.' },
        source: {
          type: 'string',
          description: "Where it came from: 'chat' | 'calendar' | 'weather' | 'fun-fact' | 'briefing' | 'manual'",
        },
        source_user: {
          type: 'string',
          description:
            "User id of the originator when source='chat' (e.g. 'telegram:6542453791'). Omit for system sources.",
        },
        date_for: {
          type: 'string',
          description:
            'ISO date (YYYY-MM-DD) the entry is relevant to. Omit/null for undated background entries.',
        },
        tags: { type: 'string', description: 'Optional comma-separated tags.' },
      },
      required: ['content', 'source'],
    },
  },
  async handler(args) {
    const content = args.content as string;
    const source = args.source as string;
    if (!content || !source) return err('content and source are required');
    const source_user = (args.source_user as string) || null;
    const date_for = (args.date_for as string) || null;
    const tags = (args.tags as string) || null;
    const db = getDb();
    const info = db
      .prepare('INSERT INTO entries (source, source_user, date_for, content, tags) VALUES (?, ?, ?, ?, ?)')
      .run(source, source_user, date_for, content, tags);
    return ok(`Added entry #${info.lastInsertRowid}`);
  },
};

export const notebookSearch: McpToolDefinition = {
  tool: {
    name: 'notebook_search',
    description:
      'Search the notebook. Combines filters: case-insensitive LIKE on content, optional date range, source, tag. Returns up to `limit` rows ordered by date_for then created_at.',
    inputSchema: {
      type: 'object' as const,
      properties: {
        query: { type: 'string', description: 'Substring to LIKE-match in content. Omit to match all.' },
        date_from: { type: 'string', description: 'Inclusive ISO date lower bound for date_for.' },
        date_to: { type: 'string', description: 'Inclusive ISO date upper bound for date_for.' },
        source: { type: 'string', description: 'Exact source filter.' },
        tag: { type: 'string', description: 'Substring match in tags column.' },
        limit: { type: 'number', description: 'Default 50, max 500.' },
      },
    },
  },
  async handler(args) {
    const query = args.query as string | undefined;
    const date_from = args.date_from as string | undefined;
    const date_to = args.date_to as string | undefined;
    const source = args.source as string | undefined;
    const tag = args.tag as string | undefined;
    const limit = Math.min(Math.max(Number(args.limit ?? 50) || 50, 1), 500);

    const where: string[] = [];
    const params: (string | number | null)[] = [];
    if (query) {
      where.push('content LIKE ?');
      params.push(`%${query}%`);
    }
    if (date_from) {
      where.push('date_for >= ?');
      params.push(date_from);
    }
    if (date_to) {
      where.push('date_for <= ?');
      params.push(date_to);
    }
    if (source) {
      where.push('source = ?');
      params.push(source);
    }
    if (tag) {
      where.push('tags LIKE ?');
      params.push(`%${tag}%`);
    }
    const sql = `SELECT * FROM entries${where.length ? ' WHERE ' + where.join(' AND ') : ''} ORDER BY date_for IS NULL, date_for, created_at LIMIT ?`;
    params.push(limit);
    const rows = getDb().prepare(sql).all(...params) as EntryRow[];
    return ok(formatRows(rows));
  },
};

export const notebookWindow: McpToolDefinition = {
  tool: {
    name: 'notebook_window',
    description:
      "The briefing retrieval pattern: returns dated entries with date_for in [today, today+days_ahead] union all undated 'background' entries. Use this when composing the morning briefing.",
    inputSchema: {
      type: 'object' as const,
      properties: {
        days_ahead: { type: 'number', description: 'How many days forward to include (default 7).' },
        include_background: {
          type: 'boolean',
          description: 'Include undated background entries (default true).',
        },
      },
    },
  },
  async handler(args) {
    const days = Math.max(Number(args.days_ahead ?? 7) || 7, 0);
    const includeBg = args.include_background !== false;
    const today = new Date().toISOString().slice(0, 10);
    const end = new Date(Date.now() + days * 86400_000).toISOString().slice(0, 10);
    const db = getDb();
    const dated = db
      .prepare('SELECT * FROM entries WHERE date_for BETWEEN ? AND ? ORDER BY date_for, created_at')
      .all(today, end) as EntryRow[];
    const bg = includeBg
      ? (db.prepare('SELECT * FROM entries WHERE date_for IS NULL ORDER BY created_at').all() as EntryRow[])
      : [];
    const parts: string[] = [];
    parts.push(`=== Dated entries (${today} → ${end}) ===`);
    parts.push(formatRows(dated));
    if (includeBg) {
      parts.push('', '=== Background entries (undated) ===');
      parts.push(formatRows(bg));
    }
    return ok(parts.join('\n'));
  },
};

export const notebookRecent: McpToolDefinition = {
  tool: {
    name: 'notebook_recent',
    description:
      'List recently-created entries regardless of date_for. Useful to review what the family has said in the last day.',
    inputSchema: {
      type: 'object' as const,
      properties: {
        hours: { type: 'number', description: 'Window in hours (default 24).' },
        limit: { type: 'number', description: 'Default 50, max 500.' },
      },
    },
  },
  async handler(args) {
    const hours = Math.max(Number(args.hours ?? 24) || 24, 0);
    const limit = Math.min(Math.max(Number(args.limit ?? 50) || 50, 1), 500);
    const cutoff = new Date(Date.now() - hours * 3600_000).toISOString().replace('T', ' ').slice(0, 19);
    const rows = getDb()
      .prepare('SELECT * FROM entries WHERE created_at >= ? ORDER BY created_at DESC LIMIT ?')
      .all(cutoff, limit) as EntryRow[];
    return ok(formatRows(rows));
  },
};

export const notebookDelete: McpToolDefinition = {
  tool: {
    name: 'notebook_delete',
    description: 'Remove an entry by id. Use sparingly — prefer adding a correction over deleting history.',
    inputSchema: {
      type: 'object' as const,
      properties: {
        id: { type: 'number', description: 'Row id from notebook_search / notebook_window output.' },
      },
      required: ['id'],
    },
  },
  async handler(args) {
    const id = Number(args.id);
    if (!Number.isFinite(id)) return err('id is required and must be a number');
    const info = getDb().prepare('DELETE FROM entries WHERE id = ?').run(id);
    if (info.changes === 0) return err(`no entry with id ${id}`);
    return ok(`Deleted entry #${id}`);
  },
};

registerTools([notebookAdd, notebookSearch, notebookWindow, notebookRecent, notebookDelete]);
