/**
 * Slack channel adapter (v2) — uses Chat SDK bridge.
 * Self-registers on import.
 */
import { createSlackAdapter } from '@chat-adapter/slack';

import { readEnvFile } from '../env.js';
import { createChatSdkBridge } from './chat-sdk-bridge.js';
import { registerChannelAdapter } from './channel-registry.js';

registerChannelAdapter('slack', {
  factory: () => {
    const env = readEnvFile(['SLACK_BOT_TOKEN', 'SLACK_APP_TOKEN']);
    if (!env.SLACK_BOT_TOKEN) return null;
    const slackAdapter = createSlackAdapter({
      botToken: env.SLACK_BOT_TOKEN,
      appToken: env.SLACK_APP_TOKEN,
      mode: 'socket',
    });

    // Per-thread "processing" indicator: ⏳ reaction on the inbound message,
    // cleared as soon as anything outbound is delivered to that thread.
    //
    // The bridge's onProcessingStart fires for every inbound — including
    // non-engaging messages in mention-mode channels. We only want the
    // reaction when the host's router has actually decided to wake the
    // agent. The host calls `setTyping` only on wake=true, so we use that
    // as the "actually engaged" signal: onProcessingStart just stores the
    // candidate msg id; setTyping promotes it to an actual reaction on first
    // call; onProcessingEnd removes it (and clears unpromoted state).
    interface PendingReaction {
      msgId: string;
      reacted: boolean;
    }
    const pendingReactions = new Map<string, PendingReaction>();
    const REACTION_EMOJI = 'hourglass_flowing_sand';

    const bridge = createChatSdkBridge({
      adapter: slackAdapter,
      concurrency: 'concurrent',
      supportsThreads: true,
      onProcessingStart: async (_channelId, threadId, platformMsgId) => {
        if (!platformMsgId) return;
        pendingReactions.set(threadId, { msgId: platformMsgId, reacted: false });
      },
      onProcessingEnd: async (_channelId, threadId) => {
        const entry = pendingReactions.get(threadId);
        if (!entry) return;
        pendingReactions.delete(threadId);
        if (!entry.reacted) return;
        await slackAdapter.removeReaction(threadId, entry.msgId, REACTION_EMOJI);
      },
    });

    // Wrap setTyping so it doubles as the "agent actually engaged" signal.
    // The host calls setTyping only when wake=true (see src/router.ts —
    // startTypingRefresh in the engaged branch). First call per thread
    // promotes the pending reaction to a real addReaction.
    const origSetTyping = bridge.setTyping?.bind(bridge);
    if (origSetTyping) {
      bridge.setTyping = async (platformId: string, threadId: string | null) => {
        const tid = threadId ?? platformId;
        const entry = pendingReactions.get(tid);
        if (entry && !entry.reacted) {
          entry.reacted = true;
          try {
            await slackAdapter.addReaction(tid, entry.msgId, REACTION_EMOJI);
          } catch {
            // best effort — reaction already there, bot not in channel, etc.
          }
        }
        await origSetTyping(platformId, threadId);
      };
    }
    bridge.resolveChannelName = async (platformId: string) => {
      try {
        const info = await slackAdapter.fetchThread(platformId);
        return (info as { channelName?: string }).channelName ?? null;
      } catch {
        return null;
      }
    };
    return bridge;
  },
});
