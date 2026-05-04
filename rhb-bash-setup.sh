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

  if [[ -n "$PS1" ]]; then
    __rhb_prompt="$PS1"
  fi

  if [[ -z "${__rhb_prompt//[[:space:]]/}" ]]; then
    __rhb_prompt="${USER}@${HOSTNAME%%.*}:${PWD/#$HOME/~}\$ "
  fi

  __rhb_selected=$(
    RHB_QUERY="$__rhb_line" \
    RHB_PS1="$__rhb_prompt" \
    "$__rhb_script" --print
  )
  __rhb_rc=$?

  if (( __rhb_rc == 0 && ${#__rhb_selected} > 0 )); then
    __rhb_ok=1
  fi

  if (( __rhb_ok == 1 )); then
    READLINE_LINE=$__rhb_selected
    if (( __rhb_point > ${#__rhb_selected} )); then
      READLINE_POINT=${#__rhb_selected}
    else
      READLINE_POINT=$__rhb_point
    fi
  else
    READLINE_LINE=$__rhb_line
    READLINE_POINT=$__rhb_point
  fi

  unset __rhb_line __rhb_point __rhb_selected __rhb_rc __rhb_ok __rhb_prompt
}

bind -r '\C-r'
bind -x '"\C-r":"__rhb_bind"'
