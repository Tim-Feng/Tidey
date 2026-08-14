#ifndef REMOTE_BRIDGE_PTY_SHIM_H
#define REMOTE_BRIDGE_PTY_SHIM_H

#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

typedef enum tidey_tmux_socket_kind {
    TIDEY_TMUX_SOCKET_DEFAULT = 0,
    TIDEY_TMUX_SOCKET_PATH = 1,
    TIDEY_TMUX_SOCKET_NAME = 2,
} tidey_tmux_socket_kind;

typedef struct tidey_tmux_pty_spawn_request {
    const char *tmux_executable_path;
    tidey_tmux_socket_kind socket_kind;
    const char *socket_value;
    const char *session_id;
    const char *window_id;
    uint16_t columns;
    uint16_t rows;
} tidey_tmux_pty_spawn_request;

typedef struct tidey_tmux_pty_handle {
    int32_t master_file_descriptor;
    int32_t child_process_id;
} tidey_tmux_pty_handle;

int32_t tidey_tmux_pty_shim_abi_version(void);

// The lifecycle entry points intentionally return ENOTSUP until their
// behavior is introduced behind real-PTY tests. A zero return value will
// mean success; nonzero values are POSIX error numbers.
int32_t tidey_tmux_pty_spawn(
    const tidey_tmux_pty_spawn_request *request,
    tidey_tmux_pty_handle *handle_out
);
int32_t tidey_tmux_pty_resize(
    int32_t master_file_descriptor,
    uint16_t columns,
    uint16_t rows
);
int32_t tidey_tmux_pty_close(int32_t master_file_descriptor);
int32_t tidey_tmux_pty_reap(
    int32_t child_process_id,
    int32_t blocking,
    int32_t *raw_status_out,
    int32_t *did_exit_out
);

#ifdef __cplusplus
}
#endif

#endif
