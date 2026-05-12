/**
 * Calendar MCP tools — stub.
 *
 * The shape mirrors what a real Google Calendar integration would expose,
 * so swapping in the real implementation is a one-file change with no
 * call-site updates required. Until then, both tools return empty results
 * and log a one-line notice so it's visible in container output.
 *
 * To wire the real integration, run the /add-gcal-tool skill — it installs
 * OneCLI-managed OAuth and replaces this file with the real MCP shim.
 */
import { registerTools } from './server.js';
import type { McpToolDefinition } from './types.js';

function ok(text: string) {
  return { content: [{ type: 'text' as const, text }] };
}

function stubNotice(): void {
  console.error('[mcp-tools] calendar: stub returning empty result — run /add-gcal-tool to wire the real API');
}

export const calendarGetEvents: McpToolDefinition = {
  tool: {
    name: 'calendar_get_events',
    description:
      'List calendar events between start_date and end_date (ISO dates). Currently a stub — returns {events: []}. Once /add-gcal-tool is run, this returns real Google Calendar events with the same shape.',
    inputSchema: {
      type: 'object' as const,
      properties: {
        start_date: { type: 'string', description: 'Inclusive ISO date (YYYY-MM-DD).' },
        end_date: { type: 'string', description: 'Inclusive ISO date (YYYY-MM-DD).' },
        calendar_id: { type: 'string', description: 'Optional calendar id — defaults to primary when wired.' },
      },
      required: ['start_date', 'end_date'],
    },
  },
  async handler() {
    stubNotice();
    return ok(JSON.stringify({ events: [], stub: true }, null, 2));
  },
};

export const calendarListCalendars: McpToolDefinition = {
  tool: {
    name: 'calendar_list_calendars',
    description: 'List available calendars. Stubbed — returns {calendars: []} until /add-gcal-tool is run.',
    inputSchema: { type: 'object' as const, properties: {} },
  },
  async handler() {
    stubNotice();
    return ok(JSON.stringify({ calendars: [], stub: true }, null, 2));
  },
};

registerTools([calendarGetEvents, calendarListCalendars]);
