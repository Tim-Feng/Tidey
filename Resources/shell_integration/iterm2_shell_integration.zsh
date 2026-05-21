# This program is free software; you can redistribute it and/or
# modify it under the terms of the GNU General Public License
# as published by the Free Software Foundation; either version 2
# of the License, or (at your option) any later version.
# 
# This program is distributed in the hope that it will be useful,
# but WITHOUT ANY WARRANTY; without even the implied warranty of
# MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
# GNU General Public License for more details.
# 
# You should have received a copy of the GNU General Public License
# along with this program; if not, write to the Free Software
# Foundation, Inc., 51 Franklin Street, Fifth Floor, Boston, MA  02110-1301, USA.

if [[ -o interactive ]]; then
  # Don't run in IDE terminals. TERM_PROGRAM is set by the local terminal but not
  # forwarded over SSH. LC_TERMINAL is set by Tidey and may be forwarded over SSH.
  if [ \( -z "${TERM_PROGRAM-}" -o "${TERM_PROGRAM-}" = "iTerm.app" -o "${LC_TERMINAL-}" = "Tidey" \) -a "${ITERM_ENABLE_SHELL_INTEGRATION_WITH_TMUX-}""$TERM" != "tmux-256color" -a "${ITERM_ENABLE_SHELL_INTEGRATION_WITH_TMUX-}""$TERM" != "screen" -a "${ITERM_SHELL_INTEGRATION_INSTALLED-}" = "" -a "$TERM" != linux -a "$TERM" != dumb ]; then
    ITERM_SHELL_INTEGRATION_INSTALLED=Yes
    ITERM2_SHOULD_DECORATE_PROMPT="1"
    # Indicates start of command output. Runs just before command executes.
    iterm2_before_cmd_executes() {
      if [ "$TERM_PROGRAM" = "iTerm.app" ]; then
        printf "\033]133;C;\r\007"
      else
        printf "\033]133;C;\007"
      fi
    }

    iterm2_set_user_var() {
      printf "\033]1337;SetUserVar=%s=%s\007" "$1" $(printf "%s" "$2" | base64 | tr -d '\n')
    }

    # Users can write their own version of this method. It should call
    # iterm2_set_user_var but not produce any other output.
    # e.g., iterm2_set_user_var currentDirectory $PWD
    # Accessible in iTerm2 (in a badge now, elsewhere in the future) as
    # \(user.currentDirectory).
    whence -v iterm2_print_user_vars > /dev/null 2>&1
    if [ $? -ne 0 ]; then
      iterm2_print_user_vars() {
          true
      }
    fi

    iterm2_print_state_data() {
      local _iterm2_hostname="${iterm2_hostname-}"
      if [ -z "${iterm2_hostname:-}" ]; then
        _iterm2_hostname=$(hostname -f 2>/dev/null)
      fi
      printf "\033]1337;RemoteHost=%s@%s\007" "$USER" "${_iterm2_hostname-}"
      printf "\033]1337;CurrentDir=%s\007" "$PWD"
      iterm2_print_user_vars
    }

    # Report return code of command; runs after command finishes but before prompt
    iterm2_after_cmd_executes() {
      printf "\033]133;D;%s\007" "$STATUS"
      iterm2_print_state_data
    }

    # Mark start of prompt
    iterm2_prompt_mark() {
      printf "\033]133;A\007"
    }

    # Mark end of prompt
    iterm2_prompt_end() {
      printf "\033]133;B\007"
    }

    # There are three possible paths in life.
    #
    # 1) A command is entered at the prompt and you press return.
    #    The following steps happen:
    #    * iterm2_preexec is invoked
    #      * PS1 is set to ITERM2_PRECMD_PS1
    #      * ITERM2_SHOULD_DECORATE_PROMPT is set to 1
    #    * The command executes (possibly reading or modifying PS1)
    #    * iterm2_precmd is invoked
    #      * ITERM2_PRECMD_PS1 is set to PS1 (as modified by command execution)
    #      * PS1 gets our escape sequences added to it
    #    * zsh displays your prompt
    #    * You start entering a command
    #
    # 2) You press ^C while entering a command at the prompt.
    #    The following steps happen:
    #    * (iterm2_preexec is NOT invoked)
    #    * iterm2_precmd is invoked
    #      * iterm2_before_cmd_executes is called since we detected that iterm2_preexec was not run
    #      * (ITERM2_PRECMD_PS1 and PS1 are not messed with, since PS1 already has our escape
    #        sequences and ITERM2_PRECMD_PS1 already has PS1's original value)
    #    * zsh displays your prompt
    #    * You start entering a command
    #
    # 3) A new shell is born.
    #    * PS1 has some initial value, either zsh's default or a value set before this script is sourced.
    #    * iterm2_precmd is invoked
    #      * ITERM2_SHOULD_DECORATE_PROMPT is initialized to 1
    #      * ITERM2_PRECMD_PS1 is set to the initial value of PS1
    #      * PS1 gets our escape sequences added to it
    #    * Your prompt is shown and you may begin entering a command.
    #
    # Invariants:
    # * ITERM2_SHOULD_DECORATE_PROMPT is 1 during and just after command execution, and "" while the prompt is
    #   shown and until you enter a command and press return.
    # * PS1 does not have our escape sequences during command execution
    # * After the command executes but before a new one begins, PS1 has escape sequences and
    #   ITERM2_PRECMD_PS1 has PS1's original value.
    iterm2_decorate_prompt() {
      # This should be a raw PS1 without iTerm2's stuff. It could be changed during command
      # execution.
      ITERM2_PRECMD_PS1="$PS1"
      ITERM2_SHOULD_DECORATE_PROMPT=""

      # Add our escape sequences just before the prompt is shown.
      # Use ITERM2_SQUELCH_MARK for people who can't modify PS1 directly, like powerlevel9k users.
      # This is gross but I had a heck of a time writing a correct if statetment for zsh 5.0.2.
      local PREFIX=""
      if [[ $PS1 == *"$(iterm2_prompt_mark)"* ]]; then
        PREFIX=""
      elif [[ "${ITERM2_SQUELCH_MARK-}" != "" ]]; then
        PREFIX=""
      else
        PREFIX="%{$(iterm2_prompt_mark)%}"
      fi
      PS1="$PREFIX$PS1%{$(iterm2_prompt_end)%}"
      ITERM2_DECORATED_PS1="$PS1"
    }

    iterm2_precmd() {
      local STATUS="$?"
      if [ -z "${ITERM2_SHOULD_DECORATE_PROMPT-}" ]; then
        # You pressed ^C while entering a command (iterm2_preexec did not run)
        iterm2_before_cmd_executes
        if [ "$PS1" != "${ITERM2_DECORATED_PS1-}" ]; then
          # PS1 changed, perhaps in another precmd. See issue 9938.
          ITERM2_SHOULD_DECORATE_PROMPT="1"
        fi
      fi

      iterm2_after_cmd_executes "$STATUS"

      if [ -n "$ITERM2_SHOULD_DECORATE_PROMPT" ]; then
        iterm2_decorate_prompt
      fi
    }

    # This is not run if you press ^C while entering a command.
    iterm2_preexec() {
      # Set PS1 back to its raw value prior to executing the command.
      PS1="$ITERM2_PRECMD_PS1"
      ITERM2_SHOULD_DECORATE_PROMPT="1"
      iterm2_before_cmd_executes
    }

    # If hostname -f is slow on your system set iterm2_hostname prior to
    # sourcing this script. We know it is fast on macOS so we don't cache
    # it. That lets us handle the hostname changing like when you attach
    # to a VPN.
    if [ -z "${iterm2_hostname-}" ]; then
      if [ "$(uname)" != "Darwin" ]; then
        iterm2_hostname=`hostname -f 2>/dev/null`
        # Some flavors of BSD (i.e. NetBSD and OpenBSD) don't have the -f option.
        if [ $? -ne 0 ]; then
          iterm2_hostname=`hostname`
        fi
      fi
    fi

    [[ -z ${precmd_functions-} ]] && precmd_functions=()
    precmd_functions=($precmd_functions iterm2_precmd)

    [[ -z ${preexec_functions-} ]] && preexec_functions=()
    preexec_functions=($preexec_functions iterm2_preexec)

    # When running inside Tidey, tell tmux to inherit Tidey environment variables
    # into new sessions so notifications keep working.
    if [ -n "${TIDEY_SOCKET_PATH-}" ]; then
      tmux set-option -ga update-environment " TIDEY_SOCKET_PATH TIDEY_WORKSPACE_ID TIDEY_BIN_DIR LC_TERMINAL" 2>/dev/null
    fi

    # Prepend Tidey's bin/ to PATH after all startup files have loaded.
    # Uses a one-shot precmd hook because .zshrc rebuilds PATH after shell integration.
    if [ -n "${TIDEY_BIN_DIR-}" ] && [ -d "${TIDEY_BIN_DIR-}" ]; then
      _tidey_inject_path() {
        # Remove existing entry (if inherited from outer shell) and prepend
        local cleaned="${PATH//$TIDEY_BIN_DIR:/}"
        cleaned="${cleaned//:$TIDEY_BIN_DIR/}"
        export PATH="${TIDEY_BIN_DIR}:${cleaned}"
        rehash 2>/dev/null || true
        add-zsh-hook -d precmd _tidey_inject_path
      }
      autoload -Uz add-zsh-hook
      add-zsh-hook precmd _tidey_inject_path
    fi

    # When running inside Tidey, report shell state via precmd/preexec hooks.
    if [ -n "${TIDEY_SOCKET_PATH-}" ] && [ -S "${TIDEY_SOCKET_PATH-}" ]; then
      _tidey_report_shell_state() {
        local msg="$1"
        if [ -n "${TIDEY_WORKSPACE_ID-}" ]; then
          msg="$msg --workspace_id=$TIDEY_WORKSPACE_ID"
        fi
        "${TIDEY_BIN_DIR}/tidey" send "$msg" &!
      }

      _tidey_command_takes_over_terminal() {
        # Don't report "running" for terminal multiplexers. They take over the
        # terminal and never return to a prompt, so the outer shell would be
        # stuck in "Running" state forever.
        #
        # Tidey's restore flow wraps attach in an `if tmux has-session ...`
        # command, so first-token checks are not enough.
        local command_line="${1//$'\n'/ }"
        case "$command_line" in
          *"tmux attach"*|*"tmux a -t"*|*"screen -r"*|*"screen -x"*) return 0 ;;
        esac

        local cmd="${command_line%% *}"
        cmd="${cmd##*/}"
        case "$cmd" in
          tmux|screen) return 0 ;;
        esac
        return 1
      }

      _tidey_preexec() {
        if _tidey_command_takes_over_terminal "$1"; then
          return
        fi
        _tidey_report_shell_state "report_shell_state running"
      }

      _tidey_precmd() {
        _tidey_report_shell_state "report_shell_state prompt"
      }

      autoload -Uz add-zsh-hook
      add-zsh-hook preexec _tidey_preexec
      add-zsh-hook precmd _tidey_precmd
    fi

    _tidey_is_tidey_terminal() {
      if [ "${LC_TERMINAL-}" = "Tidey" ]; then
        return 0
      fi
      if [ -n "${TMUX-}" ] && command -v tmux >/dev/null 2>&1; then
        local tmux_lc_terminal
        tmux_lc_terminal="$(tmux show-environment LC_TERMINAL 2>/dev/null || tmux show-environment -g LC_TERMINAL 2>/dev/null)"
        if [ "${tmux_lc_terminal#LC_TERMINAL=}" = "Tidey" ]; then
          return 0
        fi
      fi
      return 1
    }

    if _tidey_is_tidey_terminal; then
      _tidey_override_prompt() {
        if [ "${ZSH_THEME-}" = "robbyrussell" ]; then
          PROMPT="%(?:%{$fg[green]%}%1{➜%} :%{$fg[red]%}%1{➜%} ) %{$fg[blue]%}%c%{$reset_color%}"
          PROMPT+=' $(git_prompt_info)'
        fi
      }
      autoload -Uz add-zsh-hook
      add-zsh-hook precmd _tidey_override_prompt
    fi

    iterm2_print_state_data
    printf "\033]1337;ShellIntegrationVersion=15;shell=zsh\007"
  fi
fi
