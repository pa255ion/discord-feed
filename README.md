# discord-feed

A small always-on-top window that shows a live feed of incoming Discord
messages from every DM, group DM and server channel you haven't muted. Entries
fade out after a while and can optionally mark the message as read.

It has two parts:

- **`plugin/discordFeed`**: a Vencord user plugin running inside Vesktop. It
  watches incoming messages, filters them with Discord's own mute settings, and
  serves them on a Unix socket (`$XDG_RUNTIME_DIR/discord-feed-<uid>.sock`).
  It also carries out "mark as read" and "open" requests from the window,
  using the client's own read-state handling.
- **The overlay** (`src/`): a Zig program with a thin Qt 6 Widgets view. Zig
  owns the socket, protocol, timing and settings. `src/shim.cpp` only draws,
  behind the C ABI in `src/shim.h`.

There is no second login and no token handling. Everything goes through your
running Vesktop. Client mods are still technically against Discord's Terms of
Service.

## Setup

1. Build Vencord with the plugin and keep a stable link to it:
   ```
   nix build .#vencord -o ~/.local/share/discord-feed/vencord
   ```
   Re-run this after changing the plugin.
2. In Vesktop: **Settings → Vesktop Settings → Vencord Location → Change**,
   pick `~/.local/share/discord-feed/vencord`, then restart Vesktop. Your
   Vencord settings and plugins are kept, because they live in
   `~/.config/vesktop/settings/`.
   (Alternative: `nix run .#vesktop` runs a Vesktop build that uses this
   Vencord directly.)
3. **Settings → Vencord → Plugins**: enable **DiscordFeed**.
4. Start the overlay: `nix run .` (or `nix develop -c zig build run`).

The status dot turns green once the overlay is connected to Vesktop. Start the
two in either order. The overlay reconnects every 2 s, and Vesktop can sit
minimised in the tray.

## Using it

- **Left-click** a message: opens it in Discord.
- **Middle-click** a message: dismisses it (and marks it read unless marking is
  off).
- **Right-click**, or use the tray icon: settings menu.
  - **Mark as read**: *Never*, *When shown* (as soon as it appears), or *When
    it fades* (when it times out or is pushed out by newer messages).
  - **Fade after**: 15 s to 10 min, or never.
  - **Background opacity**, **Always on top**, **Pause fading**.
  - **Click-through**: the window ignores the mouse, so control it from the
    tray.
  - **Clear**, **Quit**.
- Fading pauses while the pointer is over the window.
- Drag the window by its header or any empty space. Resize it with the
  bottom-right corner.
- Messages you read in Discord itself are dimmed in the feed.
- Mentions of you are highlighted.

Settings are saved to `~/.config/discord-feed/config.json`. That file also has
`max_entries` (default 60) and `max_chars` (default 400; longer messages are
cut off).

The plugin has its own options in Vencord's plugin settings:

- skip the channel you're looking at while Discord is focused (on by default)
- forward mentions from muted channels (off by default)
- include bots and webhooks (on by default)

## What counts as muted

A message is skipped when any of these is true:

- its server, category or channel is muted
- it's in a thread whose parent channel is muted
- it's a DM you've muted
- it's in a server using *Channels & Roles* and you haven't opted into that
  channel

Your own messages and messages from blocked users are also skipped.

## Limitations

- **Large servers:** for big servers you aren't currently viewing, Discord's
  gateway may send only "channel has new messages" updates instead of the
  messages themselves. Those messages can't be shown.
- **Platform:** Linux only, built for X11. On Wayland, "always on top" depends
  on the compositor, as with SyncWatch.

## Protocol

Newline-delimited JSON over the Unix socket. Override the socket path on both
sides with `DISCORD_FEED_SOCKET`.

Plugin → overlay:

```
{"type":"message","id","channel_id","guild_id","author","avatar","where","content","mention","dm","timestamp"}
{"type":"read","channel_id","message_id"}   // read in Discord up to this message
{"type":"delete","id","channel_id"}
```

Overlay → plugin:

```
{"type":"ack","channel_id","message_id"}
{"type":"open","channel_id","guild_id","message_id"}
```

## Development

```
nix develop -c zig build          # zig-out/bin/discord-feed + zig-out/lib/libdfshim.so
nix develop -c zig build run
```

The shim is compiled with the system `c++` rather than zig's own C++ compiler:
nixpkgs' Qt is built against libstdc++, and zig bundles libc++.
