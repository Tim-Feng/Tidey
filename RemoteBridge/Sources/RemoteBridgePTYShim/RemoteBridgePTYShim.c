#include "RemoteBridgePTYShim.h"

#include <errno.h>
#include <fcntl.h>
#include <signal.h>
#include <stddef.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/ioctl.h>
#include <sys/types.h>
#include <sys/wait.h>
#include <termios.h>
#include <unistd.h>
#include <util.h>

extern char **environ;

static int tidey_set_close_on_exec(int file_descriptor) {
    int flags = fcntl(file_descriptor, F_GETFD);
    if (flags == -1) {
        return errno;
    }
    if (fcntl(file_descriptor, F_SETFD, flags | FD_CLOEXEC) == -1) {
        return errno;
    }
    return 0;
}

static int tidey_set_nonblocking(int file_descriptor) {
    int flags = fcntl(file_descriptor, F_GETFL);
    if (flags == -1) {
        return errno;
    }
    if (fcntl(file_descriptor, F_SETFL, flags | O_NONBLOCK) == -1) {
        return errno;
    }
    return 0;
}

static int tidey_is_exact_tmux_id(const char *value, char prefix) {
    if (value == NULL || value[0] != prefix || value[1] == '\0') {
        return 0;
    }
    for (const char *cursor = value + 1; *cursor != '\0'; cursor++) {
        if (*cursor < '0' || *cursor > '9') {
            return 0;
        }
    }
    return 1;
}

static int tidey_environment_entry_has_name(const char *entry, const char *name) {
    size_t name_length = strlen(name);
    return strncmp(entry, name, name_length) == 0 && entry[name_length] == '=';
}

static char **tidey_sanitized_environment(void) {
    size_t environment_count = 0;
    while (environ[environment_count] != NULL) {
        environment_count++;
    }

    char **sanitized = calloc(environment_count + 2, sizeof(char *));
    if (sanitized == NULL) {
        return NULL;
    }

    size_t output_index = 0;
    for (size_t index = 0; index < environment_count; index++) {
        const char *entry = environ[index];
        if (tidey_environment_entry_has_name(entry, "TMUX") ||
            tidey_environment_entry_has_name(entry, "TMUX_PANE") ||
            tidey_environment_entry_has_name(entry, "TERM")) {
            continue;
        }
        sanitized[output_index++] = environ[index];
    }
    sanitized[output_index++] = "TERM=xterm-256color";
    sanitized[output_index] = NULL;
    return sanitized;
}

static void tidey_child_fail(int error_file_descriptor, int error_number) {
    int32_t value = error_number;
    ssize_t ignored = write(error_file_descriptor, &value, sizeof(value));
    (void)ignored;
    _exit(127);
}

static int tidey_read_child_error(int file_descriptor, int32_t *error_out) {
    size_t offset = 0;
    while (offset < sizeof(*error_out)) {
        ssize_t count = read(
            file_descriptor,
            ((char *)error_out) + offset,
            sizeof(*error_out) - offset
        );
        if (count == 0) {
            return offset == 0 ? 0 : -EIO;
        }
        if (count < 0) {
            if (errno == EINTR) {
                continue;
            }
            return -errno;
        }
        offset += (size_t)count;
    }
    return 1;
}

static void tidey_wait_for_failed_child(pid_t child_process_id) {
    int status = 0;
    while (waitpid(child_process_id, &status, 0) == -1 && errno == EINTR) {
    }
}

int32_t tidey_tmux_pty_shim_abi_version(void) {
    return 1;
}

int32_t tidey_tmux_pty_spawn(
    const tidey_tmux_pty_spawn_request *request,
    tidey_tmux_pty_handle *handle_out
) {
    if (request == NULL || handle_out == NULL) {
        return EINVAL;
    }
    handle_out->master_file_descriptor = -1;
    handle_out->child_process_id = -1;

    if (request->tmux_executable_path == NULL ||
        request->tmux_executable_path[0] != '/' ||
        !tidey_is_exact_tmux_id(request->session_id, '$') ||
        !tidey_is_exact_tmux_id(request->window_id, '@') ||
        request->columns == 0 ||
        request->rows == 0) {
        return EINVAL;
    }
    switch (request->socket_kind) {
        case TIDEY_TMUX_SOCKET_DEFAULT:
            break;
        case TIDEY_TMUX_SOCKET_PATH:
        case TIDEY_TMUX_SOCKET_NAME:
            if (request->socket_value == NULL || request->socket_value[0] == '\0') {
                return EINVAL;
            }
            break;
        default:
            return EINVAL;
    }

    size_t session_length = strlen(request->session_id);
    size_t window_length = strlen(request->window_id);
    if (session_length > SIZE_MAX - window_length - 2) {
        return EOVERFLOW;
    }
    size_t target_length = session_length + window_length + 2;
    char *target = malloc(target_length);
    if (target == NULL) {
        return ENOMEM;
    }
    int target_count = snprintf(
        target,
        target_length,
        "%s:%s",
        request->session_id,
        request->window_id
    );
    if (target_count < 0 || (size_t)target_count >= target_length) {
        free(target);
        return EOVERFLOW;
    }

    char **sanitized_environment = tidey_sanitized_environment();
    if (sanitized_environment == NULL) {
        free(target);
        return ENOMEM;
    }

    char *arguments[8];
    size_t argument_index = 0;
    arguments[argument_index++] = (char *)request->tmux_executable_path;
    if (request->socket_kind == TIDEY_TMUX_SOCKET_PATH) {
        arguments[argument_index++] = "-S";
        arguments[argument_index++] = (char *)request->socket_value;
    } else if (request->socket_kind == TIDEY_TMUX_SOCKET_NAME) {
        arguments[argument_index++] = "-L";
        arguments[argument_index++] = (char *)request->socket_value;
    }
    arguments[argument_index++] = "attach-session";
    arguments[argument_index++] = "-t";
    arguments[argument_index++] = target;
    arguments[argument_index] = NULL;

    struct winsize initial_size = {
        .ws_row = request->rows,
        .ws_col = request->columns,
        .ws_xpixel = 0,
        .ws_ypixel = 0,
    };
    int master_file_descriptor = -1;
    int slave_file_descriptor = -1;
    if (openpty(
            &master_file_descriptor,
            &slave_file_descriptor,
            NULL,
            NULL,
            &initial_size
        ) == -1) {
        int error_number = errno;
        free(sanitized_environment);
        free(target);
        return error_number;
    }

    int error_number = tidey_set_nonblocking(master_file_descriptor);
    if (error_number == 0) {
        error_number = tidey_set_close_on_exec(master_file_descriptor);
    }
    if (error_number == 0) {
        error_number = tidey_set_close_on_exec(slave_file_descriptor);
    }

    int error_pipe[2] = {-1, -1};
    if (error_number == 0 && pipe(error_pipe) == -1) {
        error_number = errno;
    }
    if (error_number == 0) {
        error_number = tidey_set_close_on_exec(error_pipe[0]);
    }
    if (error_number == 0) {
        error_number = tidey_set_close_on_exec(error_pipe[1]);
    }
    sigset_t empty_signal_set;
    struct sigaction default_action;
    memset(&default_action, 0, sizeof(default_action));
    default_action.sa_handler = SIG_DFL;
    if (error_number == 0 && sigemptyset(&empty_signal_set) == -1) {
        error_number = errno;
    }
    if (error_number == 0 && sigemptyset(&default_action.sa_mask) == -1) {
        error_number = errno;
    }
    if (error_number != 0) {
        if (error_pipe[0] >= 0) {
            close(error_pipe[0]);
        }
        if (error_pipe[1] >= 0) {
            close(error_pipe[1]);
        }
        close(slave_file_descriptor);
        close(master_file_descriptor);
        free(sanitized_environment);
        free(target);
        return error_number;
    }

    pid_t child_process_id = fork();
    if (child_process_id == -1) {
        error_number = errno;
        close(error_pipe[0]);
        close(error_pipe[1]);
        close(slave_file_descriptor);
        close(master_file_descriptor);
        free(sanitized_environment);
        free(target);
        return error_number;
    }

    if (child_process_id == 0) {
        close(error_pipe[0]);
        close(master_file_descriptor);
        if (setsid() == -1) {
            tidey_child_fail(error_pipe[1], errno);
        }
        if (ioctl(slave_file_descriptor, TIOCSCTTY, 0) == -1) {
            tidey_child_fail(error_pipe[1], errno);
        }

        if (sigprocmask(SIG_SETMASK, &empty_signal_set, NULL) == -1) {
            tidey_child_fail(error_pipe[1], errno);
        }
        int signals[] = {SIGHUP, SIGINT, SIGQUIT, SIGTERM, SIGPIPE, SIGCHLD};
        for (size_t index = 0; index < sizeof(signals) / sizeof(signals[0]); index++) {
            if (sigaction(signals[index], &default_action, NULL) == -1) {
                tidey_child_fail(error_pipe[1], errno);
            }
        }

        if (dup2(slave_file_descriptor, STDIN_FILENO) == -1 ||
            dup2(slave_file_descriptor, STDOUT_FILENO) == -1 ||
            dup2(slave_file_descriptor, STDERR_FILENO) == -1) {
            tidey_child_fail(error_pipe[1], errno);
        }
        for (int file_descriptor = STDIN_FILENO;
             file_descriptor <= STDERR_FILENO;
             file_descriptor++) {
            if (fcntl(file_descriptor, F_SETFD, 0) == -1) {
                tidey_child_fail(error_pipe[1], errno);
            }
        }
        if (slave_file_descriptor > STDERR_FILENO) {
            close(slave_file_descriptor);
        }
        execve(request->tmux_executable_path, arguments, sanitized_environment);
        tidey_child_fail(error_pipe[1], errno);
    }

    close(error_pipe[1]);
    close(slave_file_descriptor);
    int32_t child_error = 0;
    int child_error_result = tidey_read_child_error(error_pipe[0], &child_error);
    close(error_pipe[0]);
    free(sanitized_environment);
    free(target);

    if (child_error_result != 0) {
        close(master_file_descriptor);
        if (child_error_result < 0) {
            kill(child_process_id, SIGHUP);
            tidey_wait_for_failed_child(child_process_id);
            return -child_error_result;
        }
        tidey_wait_for_failed_child(child_process_id);
        return child_error;
    }

    handle_out->master_file_descriptor = master_file_descriptor;
    handle_out->child_process_id = child_process_id;
    return 0;
}

int32_t tidey_tmux_pty_resize(
    int32_t master_file_descriptor,
    uint16_t columns,
    uint16_t rows
) {
    if (master_file_descriptor < 0 || columns == 0 || rows == 0) {
        return EINVAL;
    }
    struct winsize size = {
        .ws_row = rows,
        .ws_col = columns,
        .ws_xpixel = 0,
        .ws_ypixel = 0,
    };
    if (ioctl(master_file_descriptor, TIOCSWINSZ, &size) == -1) {
        return errno;
    }
    return 0;
}

int32_t tidey_tmux_pty_close(int32_t master_file_descriptor) {
    if (master_file_descriptor < 0) {
        return EINVAL;
    }
    if (close(master_file_descriptor) == -1) {
        return errno;
    }
    return 0;
}

int32_t tidey_tmux_pty_reap(
    int32_t child_process_id,
    int32_t blocking,
    int32_t *raw_status_out,
    int32_t *did_exit_out
) {
    if (child_process_id <= 0 ||
        (blocking != 0 && blocking != 1) ||
        raw_status_out == NULL ||
        did_exit_out == NULL) {
        return EINVAL;
    }
    *raw_status_out = 0;
    *did_exit_out = 0;
    int status = 0;
    pid_t result = waitpid(child_process_id, &status, blocking ? 0 : WNOHANG);
    if (result == -1) {
        return errno;
    }
    if (result == 0) {
        return 0;
    }
    *raw_status_out = status;
    *did_exit_out = 1;
    return 0;
}
