// C interface between the Zig core (src/main.zig) and the Qt view (src/shim.cpp).
// The Zig side owns all state and policy; the shim only draws and reports input.
// Everything runs on the Qt main thread.
#pragma once
#include <stddef.h>
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

typedef struct {
    const char *ptr;
    size_t len;
} DfStr;

enum DfAction {
    DF_ACT_ACK_MODE = 1,      // value: 0 off, 1 when shown, 2 when it fades
    DF_ACT_DECAY = 2,         // value: seconds, 0 = never
    DF_ACT_OPACITY = 3,       // value: percent
    DF_ACT_ON_TOP = 4,        // value: 0/1
    DF_ACT_CLICK_THROUGH = 5, // value: 0/1
    DF_ACT_PAUSE = 6,         // value: 0/1
    DF_ACT_CLEAR = 7,
    DF_ACT_QUIT = 8,
};

typedef struct {
    void *ctx;
    void (*tick)(void *ctx);                         // every 200 ms
    void (*readable)(void *ctx);                     // the watched fd is readable
    void (*entry_clicked)(void *ctx, uint64_t id);   // left click
    void (*entry_dismissed)(void *ctx, uint64_t id); // middle click
    void (*hover)(void *ctx, int inside);            // pointer entered/left the window
    void (*action)(void *ctx, int action, int value);
    void (*geometry)(void *ctx, int x, int y, int w, int h); // user moved/resized the window
} DfCallbacks;

typedef struct {
    int opacity; // 10..100
    int on_top;
    int click_through;
    int ack_mode;
    int decay_s;
    int paused;
} DfState;

int df_init(int argc, char **argv, const DfCallbacks *cb);
// x < 0 places the window in the top-right corner of the primary screen.
void df_set_geometry(int x, int y, int w, int h);
void df_apply(const DfState *st);
void df_watch_fd(int fd); // -1 stops watching
void df_add(uint64_t id, DfStr author, DfStr where, DfStr content, DfStr avatar_url,
            int64_t timestamp_ms, int mention);
void df_fade(uint64_t id);     // fades out, then removes
void df_set_read(uint64_t id); // dims the entry
void df_set_status(int connected, DfStr text);
int df_exec(void);
void df_quit(void);

#ifdef __cplusplus
}
#endif
