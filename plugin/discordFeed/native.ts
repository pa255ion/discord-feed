/*
 * DiscordFeed: forwards incoming messages to the discord-feed overlay.
 * SPDX-License-Identifier: GPL-3.0-or-later
 *
 * Runs in Vesktop's main process. Listens on a Unix socket that the overlay
 * connects to and speaks newline-delimited JSON in both directions. Commands
 * coming back from the overlay are handed to the renderer through a long poll
 * (nextCommands), so no main -> renderer IPC is needed.
 */

import { BrowserWindow, IpcMainInvokeEvent } from "electron";
import { chmodSync, unlinkSync } from "fs";
import { createServer, Server, Socket } from "net";

let server: Server | null = null;
const clients = new Set<Socket>();
let queue: any[] = [];
let waiter: ((cmds: any[]) => void) | null = null;

export function socketPath() {
    if (process.env.DISCORD_FEED_SOCKET) return process.env.DISCORD_FEED_SOCKET;
    const dir = process.env.XDG_RUNTIME_DIR || "/tmp";
    return `${dir}/discord-feed-${process.getuid?.() ?? 0}.sock`;
}

function push(cmd: any) {
    queue.push(cmd);
    if (waiter) {
        const w = waiter;
        waiter = null;
        w(queue.splice(0));
    }
}

function onClient(sock: Socket) {
    clients.add(sock);
    sock.setEncoding("utf8");
    let buf = "";
    sock.on("data", (chunk: string) => {
        buf += chunk;
        let nl: number;
        while ((nl = buf.indexOf("\n")) >= 0) {
            const line = buf.slice(0, nl).trim();
            buf = buf.slice(nl + 1);
            if (!line) continue;
            try {
                push(JSON.parse(line));
            } catch {
                // ignore malformed lines
            }
        }
        if (buf.length > 1 << 20) buf = "";
    });
    sock.on("close", () => clients.delete(sock));
    sock.on("error", () => clients.delete(sock));
    push({ type: "overlay-connected" });
}

export function start(_: IpcMainInvokeEvent) {
    if (server) return socketPath();
    const path = socketPath();
    try { unlinkSync(path); } catch { }
    server = createServer(onClient);
    server.on("error", err => console.error("[DiscordFeed]", err));
    server.listen(path, () => {
        try { chmodSync(path, 0o600); } catch { }
    });
    return path;
}

export function stop(_: IpcMainInvokeEvent) {
    for (const c of clients) c.destroy();
    clients.clear();
    server?.close();
    server = null;
    try { unlinkSync(socketPath()); } catch { }
    queue = [];
    if (waiter) {
        const w = waiter;
        waiter = null;
        w([]);
    }
}

export function send(_: IpcMainInvokeEvent, json: string) {
    for (const c of clients) {
        if (!c.destroyed) c.write(json + "\n");
    }
}

/** Resolves with the commands received from the overlay since the last call. */
export function nextCommands(_: IpcMainInvokeEvent): Promise<any[]> {
    // A new poll replaces any older one (e.g. after the renderer reloaded).
    if (waiter) {
        const w = waiter;
        waiter = null;
        w([]);
    }
    if (queue.length) return Promise.resolve(queue.splice(0));
    return new Promise(res => (waiter = res));
}

export function focusWindow(_: IpcMainInvokeEvent) {
    const win = BrowserWindow.getAllWindows().find(w => !w.isDestroyed());
    if (!win) return;
    if (win.isMinimized()) win.restore();
    win.show();
    win.focus();
}
