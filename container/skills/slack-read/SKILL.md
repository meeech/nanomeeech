---
name: slack-read
description: Read Slack messages you were NOT @-mentioned on. Use when a Slack user points at a message you don't have in context — "look at the message above", "review the link my colleague posted", "summarize this thread/channel" — or when you need the message a thread was started on. Slack channels only.
---

# Reading Slack messages you weren't tagged on

You only receive Slack messages that @-mention you. When a user refers to
another message you can't see (a colleague's message, a link posted above, the
message they started a thread on), fetch it directly from Slack instead of
guessing or saying you can't see it.

Auth is automatic — the OneCLI gateway injects the Slack credential. You never
handle a token.

## Read the current thread (most common)

When a user replies in a thread and asks you to look at "the message above" or
"my colleague's message", that message is almost always the **thread root**.
A bare call reads the whole thread (root + replies), auto-detecting the channel
and thread from the message that just triggered you:

```bash
bun /app/skills/slack-read/read.ts
```

## Read recent channel messages

When the referenced message is a separate top-level message in the channel
(not the one the thread hangs off), read recent channel history and find it:

```bash
bun /app/skills/slack-read/read.ts --channel --limit 30
```

## Options

- `--channel` — read channel history instead of the current thread
- `--limit N` — how many messages (default 20)
- `--id <C…>` — explicit channel id (otherwise auto-detected)
- `--ts <thread_ts>` — explicit thread root timestamp

## Notes

- Senders are shown as Slack user ids (e.g. `U014DKRG2BX`); match them to people
  you know from context.
- If you get `Slack API error: not_authed`, the agent has no `slack.com`
  credential assigned — tell the operator; don't retry in a loop.
