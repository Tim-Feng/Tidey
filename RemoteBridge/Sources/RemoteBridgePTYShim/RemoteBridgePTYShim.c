#include "RemoteBridgePTYShim.h"

#include <errno.h>

int32_t tidey_tmux_pty_shim_abi_version(void) {
    return 1;
}

int32_t tidey_tmux_pty_spawn(
    const tidey_tmux_pty_spawn_request *request,
    tidey_tmux_pty_handle *handle_out
) {
    (void)request;
    (void)handle_out;
    return ENOTSUP;
}

int32_t tidey_tmux_pty_resize(
    int32_t master_file_descriptor,
    uint16_t columns,
    uint16_t rows
) {
    (void)master_file_descriptor;
    (void)columns;
    (void)rows;
    return ENOTSUP;
}

int32_t tidey_tmux_pty_close(int32_t master_file_descriptor) {
    (void)master_file_descriptor;
    return ENOTSUP;
}

int32_t tidey_tmux_pty_reap(
    int32_t child_process_id,
    int32_t blocking,
    int32_t *raw_status_out,
    int32_t *did_exit_out
) {
    (void)child_process_id;
    (void)blocking;
    (void)raw_status_out;
    (void)did_exit_out;
    return ENOTSUP;
}
