#!/usr/bin/env bash

# Source from ~/.bashrc:
#   source "/home/nybo/reverse-history-bash/rhb-bash-setup.sh"

__rhb_script="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/reverse-history-bash.sh"

__rhb_bind() {
  local __rhb_line=$READLINE_LINE
  local __rhb_point=$READLINE_POINT
  local __rhb_selected
  local __rhb_rc=0
  local __rhb_ok=0
  local __rhb_prompt
  local __rhb_prompt_rendered
  local __rhb_prompt_expanded=0
  local __rhb_reuse_initial_line=0
  local __rhb_result_file

  if [[ -n "$PS1" ]]; then
    __rhb_prompt="$PS1"
  fi

  if [[ -z "${__rhb_prompt//[[:space:]]/}" ]]; then
    __rhb_prompt="${USER}@${HOSTNAME%%.*}:${PWD/#$HOME/~}\$ "
  fi

  if [[ "$__rhb_point" -eq ${#__rhb_line} && -e /dev/tty ]]; then
    __rhb_prompt_rendered="${__rhb_prompt@P}"
    if [[ -z "${__rhb_prompt_rendered//[[:space:]]/}" ]]; then
      __rhb_prompt_rendered="${USER}@${HOSTNAME%%.*}:${PWD/#$HOME/~}\$ "
    fi
    printf '\r\033[2K%s%s' "$__rhb_prompt_rendered" "$__rhb_line" > /dev/tty
    __rhb_prompt_expanded=1
    __rhb_reuse_initial_line=1
  fi

  __rhb_result_file=$(mktemp "${TMPDIR:-/tmp}/rhb.XXXXXX") || return
  : > "$__rhb_result_file"

  (
    RHB_QUERY="$__rhb_line" \
    RHB_POINT="$__rhb_point" \
    RHB_PS1="$__rhb_prompt" \
    RHB_PROMPT="$__rhb_prompt_rendered" \
    RHB_PROMPT_EXPANDED="$__rhb_prompt_expanded" \
    RHB_REUSE_INITIAL_LINE="$__rhb_reuse_initial_line" \
    RHB_RESULT_FILE="$__rhb_result_file" \
    "$__rhb_script" --print
  )
  __rhb_rc=$?
  if (( __rhb_rc == 0 )); then
    __rhb_selected=$(<"$__rhb_result_file")
  else
    __rhb_selected=""
  fi
  rm -f "$__rhb_result_file"

  if (( __rhb_rc == 0 && ${#__rhb_selected} > 0 )); then
    __rhb_ok=1
  fi

  if (( __rhb_ok == 1 )); then
    READLINE_LINE=$__rhb_selected
    READLINE_POINT=${#__rhb_selected}
  elif (( __rhb_rc == 130 )); then
    READLINE_LINE=$__rhb_selected
    READLINE_POINT=${#__rhb_selected}
  else
    READLINE_LINE=$__rhb_line
    READLINE_POINT=$__rhb_point
  fi

  unset __rhb_line __rhb_point __rhb_selected __rhb_rc __rhb_ok __rhb_prompt __rhb_prompt_rendered __rhb_prompt_expanded __rhb_reuse_initial_line __rhb_result_file
}

bind -r '\C-r'
bind -x '"\C-r":"__rhb_bind"'
