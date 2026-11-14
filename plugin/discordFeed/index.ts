/*
 * DiscordFeed: forwards incoming messages to the discord-feed overlay.
 * SPDX-License-Identifier: GPL-3.0-or-later
 */

import { definePluginSettings } from "@api/Settings";
import { Logger } from "@utils/Logger";
import definePlugin, { OptionType, PluginNative, ReporterTestable } from "@utils/types";
import type { Channel, Message } from "@vencord/discord-types";
import {
    ChannelStore, FluxDispatcher, GuildMemberStore, GuildRoleStore, GuildStore, NavigationRouter,
    ReadStateStore, RelationshipStore, SelectedChannelStore, UserGuildSettingsStore, UserStore, WindowStore
} from "@webpack/common";

const Native = VencordNative.pluginHelpers.DiscordFeed as PluginNative<typeof import("./native")>;
const logger = new Logger("DiscordFeed");

const settings = definePluginSettings({
    skipFocusedChannel: {
        type: OptionType.BOOLEAN,
        description: "Don't forward messages in the channel you're looking at while Discord is focused",
        default: true,
    },
    mentionsFromMuted: {
        type: OptionType.BOOLEAN,
        description: "Forward messages that mention you even when the channel or server is muted",
        default: false,
    },
    includeBots: {
        type: OptionType.BOOLEAN,
        description: "Forward messages from bots and webhooks",
        default: true,
    },
});

// MESSAGE_CREATE carries the raw API object (snake_case), not a MessageRecord.
type RawMessage = Message & { mention_everyone: boolean; webhook_id?: string; };

let running = false;

function isMuted(channel: Channel): boolean {
    const guildId = channel.guild_id;
    if (!guildId) return UserGuildSettingsStore.isChannelMuted(null, channel.id);
    if (UserGuildSettingsStore.isGuildOrCategoryOrChannelMuted(guildId, channel.id)) return true;
    // Threads inherit the mute state of their parent channel.
    if (channel.isThread() && channel.parent_id
        && UserGuildSettingsStore.isGuildOrCategoryOrChannelMuted(guildId, channel.parent_id)) return true;
    // Servers using "Channels & Roles" only show the channels you opted into.
    if (UserGuildSettingsStore.isOptInEnabled(guildId)
        && !UserGuildSettingsStore.isChannelOrParentOptedIn(guildId, channel.id)) return true;
    return false;
}

function mentionsMe(message: RawMessage, myId: string): boolean {
    return message.mention_everyone || message.mentions.some((u: any) => (u?.id ?? u) === myId);
}

function displayName(message: Message, guildId: string | undefined): string {
    const a = message.author as any;
    if (guildId) {
        const nick = GuildMemberStore.getNick(guildId, a.id);
        if (nick) return nick;
    } else {
        const friendNick = RelationshipStore.getNickname(a.id);
        if (friendNick) return friendNick;
    }
    return a.globalName || a.global_name || a.username;
}

function avatarUrl(message: Message): string {
    const a = message.author as any;
    if (a.avatar) return `https://cdn.discordapp.com/avatars/${a.id}/${a.avatar}.png?size=64`;
    const idx = Number((BigInt(a.id) >> 22n) % 6n);
    return `https://cdn.discordapp.com/embed/avatars/${idx}.png`;
}

function location(channel: Channel): string {
    if (channel.isDM()) return "Direct message";
    if (channel.isGroupDM()) {
        if (channel.name) return channel.name;
        const names = (channel as any).rawRecipients?.map((u: any) => u.global_name || u.username) ?? [];
        return names.join(", ") || "Group DM";
    }
    const guild = GuildStore.getGuild(channel.guild_id);
    let where = `#${channel.name}`;
    if (channel.isThread() && channel.parent_id) {
        const parent = ChannelStore.getChannel(channel.parent_id);
        if (parent) where = `#${parent.name} › ${channel.name}`;
    }
    return guild ? `${guild.name} › ${where}` : where;
}

/** Turns Discord's message markup into readable plain text. */
function renderContent(message: Message, guildId: string | undefined): string {
    let text = message.content ?? "";

    text = text.replace(/<@!?(\d{17,20})>/g, (_, id) => {
        const user = UserStore.getUser(id) as any;
        const nick = guildId ? GuildMemberStore.getNick(guildId, id) : null;
        return `@${nick || user?.globalName || user?.username || "unknown"}`;
    });
    text = text.replace(/<@&(\d{17,20})>/g, (_, id) =>
        `@${(guildId && GuildRoleStore.getRole(guildId, id)?.name) || "role"}`);
    text = text.replace(/<#(\d{17,20})>/g, (_, id) => `#${ChannelStore.getChannel(id)?.name ?? "channel"}`);
    text = text.replace(/<a?(:\w+:)\d{17,20}>/g, "$1");
    text = text.replace(/<t:(\d+)(?::\w)?>/g, (_, s) => new Date(Number(s) * 1000).toLocaleString());

    const extras: string[] = [];
    for (const a of message.attachments ?? []) {
        const kind = a.content_type?.startsWith("image") ? "image"
            : a.content_type?.startsWith("video") ? "video" : "file";
        extras.push(`[${kind}: ${a.filename}]`);
    }
    for (const s of (message as any).sticker_items ?? []) extras.push(`[sticker: ${s.name}]`);
    if (!text && message.embeds?.length) {
        const e: any = message.embeds[0];
        const title = e.rawTitle ?? e.title;
        const desc = e.rawDescription ?? e.description;
        extras.push([title, desc].filter(Boolean).join(" — ") || "[embed]");
    }
    if (message.poll) extras.push(`[poll: ${(message.poll as any).question?.text ?? ""}]`);

    return [text, ...extras].filter(Boolean).join(" ").trim();
}

function send(obj: any) {
    Native.send(JSON.stringify(obj));
}

function onMessage(message: RawMessage) {
    const me = UserStore.getCurrentUser();
    if (!me || message.author?.id === me.id) return;
    const channel = ChannelStore.getChannel(message.channel_id);
    if (!channel) return;
    if (RelationshipStore.isBlocked(message.author.id)) return;
    if (!settings.store.includeBots && (message.author.bot || message.webhook_id)) return;

    const mention = mentionsMe(message, me.id);
    if (isMuted(channel) && !(mention && settings.store.mentionsFromMuted)) return;
    if (settings.store.skipFocusedChannel
        && SelectedChannelStore.getChannelId() === channel.id && WindowStore.isFocused()) return;

    const guildId = channel.guild_id || undefined;
    send({
        type: "message",
        id: message.id,
        channel_id: channel.id,
        guild_id: guildId ?? null,
        author: displayName(message, guildId),
        avatar: avatarUrl(message),
        where: location(channel),
        content: renderContent(message, guildId),
        mention,
        dm: channel.isPrivate(),
        timestamp: new Date(message.timestamp as any).getTime() || Date.now(),
    });
}

function ack(channelId: string, messageId: string) {
    if (!ReadStateStore.hasUnread(channelId)) return;
    const acked = ReadStateStore.ackMessageId(channelId);
    if (acked && BigInt(acked) >= BigInt(messageId)) return;
    FluxDispatcher.dispatch({
        type: "BULK_ACK",
        context: "APP",
        channels: [{ channelId, messageId, readStateType: 0 }],
    });
}

function handle(cmd: any) {
    switch (cmd?.type) {
        case "ack":
            if (cmd.channel_id && cmd.message_id) ack(String(cmd.channel_id), String(cmd.message_id));
            break;
        case "open":
            NavigationRouter.transitionTo(`/channels/${cmd.guild_id ?? "@me"}/${cmd.channel_id}/${cmd.message_id}`);
            Native.focusWindow();
            break;
        case "overlay-connected":
            logger.info("overlay connected");
            break;
    }
}

async function pollLoop() {
    while (running) {
        let cmds: any[];
        try {
            cmds = await Native.nextCommands();
        } catch (e) {
            logger.error("poll failed", e);
            await new Promise(r => setTimeout(r, 2000));
            continue;
        }
        if (!running) break;
        for (const cmd of cmds) {
            try {
                handle(cmd);
            } catch (e) {
                logger.error("command failed", cmd, e);
            }
        }
    }
}

export default definePlugin({
    name: "DiscordFeed",
    description: "Streams incoming messages from unmuted channels to the discord-feed overlay window",
    authors: [{ name: "milo", id: 0n }],
    reporterTestable: ReporterTestable.None,
    settings,

    flux: {
        MESSAGE_CREATE({ message, optimistic }: { message: RawMessage; optimistic: boolean; }) {
            if (optimistic || !running) return;
            try {
                onMessage(message);
            } catch (e) {
                logger.error("failed to forward message", e);
            }
        },
        MESSAGE_DELETE({ id, channelId }: { id: string; channelId: string; }) {
            if (running) send({ type: "delete", id, channel_id: channelId });
        },
        MESSAGE_ACK({ channelId, messageId }: { channelId: string; messageId: string; }) {
            if (running && channelId && messageId) send({ type: "read", channel_id: channelId, message_id: messageId });
        },
    },

    async start() {
        running = true;
        const path = await Native.start();
        logger.info("listening on", path);
        pollLoop();
    },

    stop() {
        running = false;
        Native.stop();
    },
});
