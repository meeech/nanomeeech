# Reading Slack messages you weren't tagged on

On Slack you only receive messages that @-mention you. When a user refers to a message you don't have in context — "look at the message above", "the link my colleague posted", "what did Claire say", "summarize this thread" — do NOT say your history is empty or that you can't see it. Fetch it from Slack:

```bash
bun /app/skills/slack-read/read.ts            # current thread: root message + all replies
bun /app/skills/slack-read/read.ts --channel  # recent messages in this channel
```

It auto-detects the channel and thread you're in (no token needed — the gateway injects auth). The message a user started a thread on is the thread root, so a bare call returns it. See `/slack-read` for options (`--limit`, `--id`, `--ts`, channel-history mode).
