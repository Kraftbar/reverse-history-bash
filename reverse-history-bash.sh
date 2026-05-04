#!/usr/bin/env bash

# ---------- Configuration ----------
HISTORY_FILE="$HOME/.bash_history"
MAX_DISPLAY="${HSMW_PAGE_SIZE:-10}"
HIGHLIGHT_ON=$'\033[1;33m'
ACTIVE_ON=$'\033[7m'
RESET=$'\033[0m'
if ! [[ "$MAX_DISPLAY" =~ ^[0-9]+$ ]] || (( MAX_DISPLAY < 1 )); then
  MAX_DISPLAY=10
fi

# ---------- State ----------
current_cmd_index=1   # 1-based index for easier selection
display_start=1
search_string="${RHB_QUERY:-}"
cmd_matches=""
matches_count=0
overlay_rows=0
cursor_row=0
cursor_col=0
terminal_rows=24
terminal_cols=80
TTY="/dev/tty"
TTY_FD=0
if [[ -t 0 && -e "$TTY" ]]; then
  { exec {TTY_FD}<> "$TTY"; } 2>/dev/null || TTY_FD=0
fi

# ---------- Helpers ----------
tty_printf() {
  if (( TTY_FD > 0 )); then
    printf "$@" >&"$TTY_FD"
  fi
}

move_cursor() {
  local row="$1" col="$2"
  tty_printf '\033[%d;%dH' "$row" "$col"
}

save_cursor() {
  tty_printf '\0337'
}

restore_cursor() {
  tty_printf '\0338'
}

query_cursor_position() {
  if (( TTY_FD <= 0 )); then
    return 1
  fi

  refresh_terminal_size

  local saved_stty current
  saved_stty=$(stty -g <"$TTY" 2>/dev/null || true)
  if ! stty -echo -icanon min 0 time 5 <"$TTY" 2>/dev/null; then
    stty "$saved_stty" <"$TTY" 2>/dev/null || true
    return 1
  fi

  tty_printf '\e[6n'
  local got
  read -rs -t 0.2 -u "$TTY_FD" -n 1 got
  if [[ "$got" != $'\e' ]]; then
    stty "$saved_stty" <"$TTY" 2>/dev/null || true
    return 1
  fi
  read -rs -t 0.2 -u "$TTY_FD" -n 1 got
  if [[ "$got" != '[' ]]; then
    stty "$saved_stty" <"$TTY" 2>/dev/null || true
    return 1
  fi
  read -rs -t 0.2 -u "$TTY_FD" -d R current
  stty "$saved_stty" <"$TTY" 2>/dev/null || true

  if ! [[ "$current" =~ ^[0-9]+\;[0-9]+$ ]]; then
    return 1
  fi

  cursor_row="${current%\;*}"
  cursor_col="${current#*\;}"
  if (( cursor_row < 1 || cursor_row > terminal_rows || cursor_col < 1 || cursor_col > terminal_cols )); then
    stty "$saved_stty" <"$TTY" 2>/dev/null || true
    return 1
  fi
  return 0
}

refresh_terminal_size() {
  local stty_size
  stty_size=$(stty size < "$TTY" 2>/dev/null)
  terminal_rows=$(awk '{print $1}' <<< "$stty_size")
  terminal_cols=$(awk '{print $2}' <<< "$stty_size")
  [[ -n "$terminal_rows" && "$terminal_rows" -ge 1 ]] || terminal_rows=24
  [[ -n "$terminal_cols" && "$terminal_cols" -ge 1 ]] || terminal_cols=80
}

flush_overlay() {
  local rows="$1"
  if [[ -z "$rows" ]]; then
    rows=$overlay_rows
  fi

  if (( rows <= 0 )); then
    return
  fi
  if (( cursor_row <= 0 || cursor_col <= 0 )); then
    return
  fi
  local max_rows_in_view=$(( terminal_rows - cursor_row + 1 ))
  if (( max_rows_in_view <= 0 )); then
    return
  fi

  local i clear_rows row
  clear_rows=$rows
  if (( max_rows_in_view < clear_rows )); then
    clear_rows=$max_rows_in_view
  fi
  if (( clear_rows <= 0 )); then
    return
  fi

  for (( i = 0; i < clear_rows; i++ )); do
    row=$(( cursor_row + i ))
    move_cursor "$row" 1
    tty_printf '\r\033[K'
  done
  move_cursor "$cursor_row" "$cursor_col"
}

cancel_picker() {
  flush_overlay
  if (( cursor_row > 0 && cursor_col > 0 )); then
    move_cursor "$cursor_row" "$cursor_col"
  fi
  exit 130
}

trap cancel_picker INT TERM

count_matches() {
  if [[ -z "$cmd_matches" ]]; then
    matches_count=0
  else
    matches_count=$(grep -c '^' <<< "$cmd_matches")
  fi
}

expand_prompt_escapes() {
  local prompt="$1"
  local home="$HOME"
  local host_short="${HOSTNAME%%.*}"
  local host_full="$HOSTNAME"
  local prompt_char='$'
  local expanded=""
  local char next
  local i
  local non_printing=0

  if (( EUID == 0 )); then
    prompt_char="#"
  fi

  for (( i=0; i<${#prompt}; i++ )); do
    char="${prompt:i:1}"

    if (( non_printing == 1 )); then
      if [[ "$char" == "\\" && ${prompt:i+1:1} == "]" ]]; then
        non_printing=0
        ((i++))
      fi
      continue
    fi

    if [[ "$char" != "\\" ]]; then
      expanded+="$char"
      continue
    fi

    ((i++))
    if (( i >= ${#prompt} )); then
      break
    fi
    next="${prompt:i:1}"

    if [[ "$next" == "\\" ]]; then
      ((i++))
      if (( i >= ${#prompt} )); then
        expanded+="\\"
        break
      fi
      next="${prompt:i:1}"
    fi

    case "$next" in
      "[")
        non_printing=1
        ;;
      "]")
        ;;
      "u")
        expanded+="${USER}"
        ;;
      "h")
        expanded+="${host_short}"
        ;;
      "H")
        expanded+="${host_full}"
        ;;
      "w")
        expanded+="${PWD/#$home/~}"
        ;;
      "W")
        expanded+="${PWD##*/}"
        ;;
      "\$" )
        expanded+="$prompt_char"
        ;;
      "n")
        expanded+=$'\n'
        ;;
      "r")
        expanded+=$'\r'
        ;;
      "e")
        expanded+=$'\033'
        ;;
      "\\\\")
        expanded+="\\"
        ;;
      *)
        expanded+="$next"
        ;;
    esac
  done

  printf '%s' "$expanded"
}

get_prompt_line() {
  local prompt="${RHB_PROMPT:-${RHB_PS1:-${PS1:-}}}"
  local expanded
  local expanded_sanitized

  if [[ -z "$prompt" ]]; then
    build_prompt_line
    return
  fi

  if [[ "${RHB_PROMPT_EXPANDED:-0}" == "1" ]]; then
    printf '%s' "$prompt"
    return
  fi

  # Expand a minimal set of common prompt escapes without executing prompt
  # code (avoids running command substitutions from custom PS1 setups).
  if [[ -n ${BASH_VERSINFO+x} && ${BASH_VERSINFO[0]} -ge 5 ]]; then
    expanded="${prompt@P}"
  else
    expanded="$(expand_prompt_escapes "$prompt")"
  fi

  # Trim accidental wrapper quotes and recover for broken/non-printing prompts.
  expanded="${expanded#\"}"
  expanded="${expanded%\"}"
  expanded="${expanded#\'}"
  expanded="${expanded%\'}"
  expanded="${expanded//\"/}"
  expanded="${expanded//\'/}"
  expanded="${expanded//\`/}"
  expanded="${expanded//$'\n'/ }"
  expanded="${expanded//$'\r'/ }"
  if [[ -z "${expanded//[[:space:]]/}" ]]; then
    expanded="$(build_prompt_line)"
  fi
  expanded_sanitized="${expanded//[[:space:]]/}"
  if [[ -z "$expanded_sanitized" ]]; then
    expanded="$(build_prompt_line)"
  fi

  if [[ -z "$expanded" ]]; then
    expanded="$(build_prompt_line)"
  fi
  printf '%s' "$expanded"
}

build_prompt_line() {
  local prompt_host="${HOSTNAME%%.*}"
  printf '%s' "${USER}@${prompt_host}:${PWD/#$HOME/~}\$ "
}

fuzzy_search() {
  local query="$1"
  local history_file="$2"

  local input
  input=$(tr -d '\000' < "$history_file" 2>/dev/null || true)

  cmd_matches=$(awk -v query="$query" '
    function escape_regex(value, escaped, i, ch) {
      escaped = ""
      for (i = 1; i <= length(value); i++) {
        ch = substr(value, i, 1)
        if (ch ~ /[][\\.^$*+?(){}|]/) {
          escaped = escaped "\\" ch
        } else {
          escaped = escaped ch
        }
      }
      return escaped
    }

    function token_regex(token, starts, ends, body) {
      starts = substr(token, 1, 1) == "^"
      ends = substr(token, length(token), 1) == "$"
      body = token
      if (starts) {
        body = substr(body, 2)
      }
      if (ends && length(body) > 0) {
        body = substr(body, 1, length(body) - 1)
      }
      if (body !~ /\[[^]]+\]/) {
        body = escape_regex(body)
      }
      return (starts ? "^" : "") body (ends ? "$" : "")
    }

    BEGIN {
      query = tolower(query)
      token_count = split(query, raw_tokens, /[[:space:]]+/)
      for (i = 1; i <= token_count; i++) {
        if (raw_tokens[i] != "") {
          tokens[++tokens_len] = token_regex(raw_tokens[i])
        }
      }
    }

    {
      if ($0 ~ /^#[0-9]+$/) {
        next
      }
      history[++history_len] = $0
    }

    END {
      for (i = history_len; i >= 1; i--) {
        line = history[i]
        if (seen[line]++) {
          continue
        }
        lower = tolower(line)
        matched = 1
        for (j = 1; j <= tokens_len; j++) {
          if (lower !~ tokens[j]) {
            matched = 0
            break
          }
        }
        if (matched) {
          print line
        }
      }
    }
  ' <<< "$input")

  count_matches

  if (( matches_count == 0 )); then
    current_cmd_index=1
  elif (( current_cmd_index < 1 )); then
    current_cmd_index=$matches_count
  elif (( current_cmd_index > matches_count )); then
    current_cmd_index=1
  fi

  update_display_start
}

delete_last_query_char() {
  local -i len code
  if [[ -z "$search_string" ]]; then
    return
  fi

  len=${#search_string}
  while (( len > 0 )); do
    local byte
    byte=${search_string:len-1:1}
    code=$(LC_ALL=C printf '%s' "$byte" | od -An -t uC | tr -d ' \t\n')
    if (( code >= 0x80 && code <= 0xBF )); then
      (( len-- ))
      continue
    fi
    break
  done

  if (( len > 0 )); then
    local lead
    lead=${search_string:len-1:1}
    code=$(LC_ALL=C printf '%s' "$lead" | od -An -t uC | tr -d ' \t\n')
    if (( code >= 0xF0 && code <= 0xF7 )); then
      (( len -= 4 ))
    elif (( code >= 0xE0 && code <= 0xEF )); then
      (( len -= 3 ))
    elif (( code >= 0xC0 && code <= 0xDF )); then
      (( len -= 2 ))
    else
      (( len -= 1 ))
    fi
  fi

  if (( len < 0 )); then
    len=0
  fi
  search_string="${search_string:0:len}"
}

update_display_start() {
  if (( matches_count == 0 )); then
    display_start=1
  elif (( current_cmd_index < display_start )); then
    display_start=$current_cmd_index
  elif (( current_cmd_index >= display_start + MAX_DISPLAY )); then
    display_start=$(( current_cmd_index - MAX_DISPLAY + 1 ))
  fi
}

draw_overlay_line() {
  local line="$1"
  tty_printf '\r\033[K'
  tty_printf '%s' "$line"
}

truncate_line() {
  local line="$1"
  local width="$2"
  if (( width < 1 )); then
    printf ''
  elif (( ${#line} > width )); then
    printf '%s' "${line:0:width}"
  else
    printf '%s' "$line"
  fi
}

highlight_matches() {
  local line="$1"
  local token clean_token highlighted="$line"
  for token in $search_string; do
    clean_token="$token"
    clean_token="${clean_token#^}"
    clean_token="${clean_token%\$}"
    if [[ "$clean_token" == *"["*"]"* || -z "$clean_token" ]]; then
      continue
    fi
    highlighted=$(awk -v line="$highlighted" -v token="$clean_token" -v on="$HIGHLIGHT_ON" -v off="$RESET" '
      BEGIN {
        lower = tolower(line)
        needle = tolower(token)
        out = ""
        pos = 1
        n = length(needle)
        if (n == 0) {
          print line
          exit
        }
        while ((idx = index(substr(lower, pos), needle)) > 0) {
          idx += pos - 1
          out = out substr(line, pos, idx - pos) on substr(line, idx, n) off
          pos = idx + n
        }
        out = out substr(line, pos)
        print out
      }
    ')
  done
  printf '%s' "$highlighted"
}

rotate_query_words() {
  local -a words
  read -r -a words <<< "$search_string"
  if (( ${#words[@]} <= 1 )); then
    return
  fi

  local last_index=$(( ${#words[@]} - 1 ))
  search_string="${words[$last_index]}"
  local i
  for (( i = 0; i < last_index; i++ )); do
    search_string+=" ${words[$i]}"
  done
}

delete_query_word() {
  local -a words
  read -r -a words <<< "$search_string"
  if (( ${#words[@]} == 0 )); then
    search_string=""
    return
  fi

  unset 'words[${#words[@]}-1]'
  search_string="${words[*]}"
}

render_ui() {
  refresh_terminal_size
  if (( cursor_row <= 0 || cursor_col <= 0 )); then
    return
  fi

  local cols="$terminal_cols"
  local page_size="$MAX_DISPLAY"
  if (( page_size < 1 )); then
    page_size=10
  fi
  if (( page_size > 20 )); then
    page_size=20
  fi
  local draw_cols=$(( cols - 1 ))
  if (( draw_cols < 1 )); then draw_cols=1; fi
  local idx_text="[0/0]"
  local selected=""
  local selected_plain=""
  local visible_matches=""
  local visible_count=0
  if (( matches_count > 0 )); then
    idx_text="["$current_cmd_index"/"$matches_count"]"
    selected_plain=$(awk -v idx="$current_cmd_index" 'NR==idx' <<< "$cmd_matches")
  fi
  local prompt_line prefix
  prompt_line="$(get_prompt_line)"
  if [[ -n "$prompt_line" ]]; then
    if [[ -n "$search_string" && "${prompt_line: -1}" != " " ]]; then
      prefix="${prompt_line} ${search_string}"
    else
      prefix="${prompt_line}${search_string}"
    fi
  else
    prefix="$search_string"
  fi

  local prefix_with_status="$prefix"
  if [[ -n "$prefix_with_status" ]]; then
    prefix_with_status+=" "
  fi
  prefix_with_status+="$idx_text"
  local header="$prefix_with_status"
  local max_selected_len=$(( draw_cols - 4 ))
  if (( max_selected_len < 0 )); then max_selected_len=0; fi
  selected_plain=$(truncate_line "$selected_plain" "$max_selected_len")
  selected=$(highlight_matches "$selected_plain")

  local max_lines_below=$(( terminal_rows - cursor_row + 1 ))
  if (( max_lines_below <= 0 )); then
    overlay_rows=0
    flush_overlay
    return
  fi

  local max_overlay_rows=$(( page_size + 1 ))
  if (( max_overlay_rows > max_lines_below )); then
    max_overlay_rows=$max_lines_below
  fi

  if (( matches_count > 0 )); then
    local max_visible_rows=$(( max_overlay_rows - 1 ))
    visible_matches=$(awk -v start="$display_start" -v max="$max_visible_rows" 'NR >= start && NR < start + max' <<< "$cmd_matches")
    visible_count=$(awk 'END { print NR }' <<< "$visible_matches")
  fi

  local new_overlay_rows=$(( visible_count + 1 ))
  if (( new_overlay_rows > max_overlay_rows )); then
    new_overlay_rows=$max_overlay_rows
  fi

  flush_overlay "$overlay_rows"
  overlay_rows=$new_overlay_rows
  if (( overlay_rows <= 0 )); then
    flush_overlay "$overlay_rows"
    return
  fi

  move_cursor "$cursor_row" 1
  draw_overlay_line "$header"

  local idx=$display_start
  local row_num=1
  while IFS= read -r line; do
    if (( row_num >= overlay_rows )); then
      break
    fi
    move_cursor "$(( cursor_row + row_num ))" 1
    local row_prefix="  "
    if (( idx == current_cmd_index )); then
      row_prefix="> "
    fi
    local visible_line
    visible_line=$(truncate_line "$line" "$(( draw_cols - 2 ))")
    visible_line=$(highlight_matches "$visible_line")
    if (( idx == current_cmd_index )); then
      draw_overlay_line "${ACTIVE_ON}${row_prefix}${visible_line}${RESET}"
    else
      draw_overlay_line "${row_prefix}${visible_line}${RESET}"
    fi
    (( idx++ ))
    (( row_num++ ))
  done <<< "$visible_matches"
  move_cursor "$cursor_row" "$cursor_col"
}

read_key() {
  local k rest
  key=""
  if (( TTY_FD > 0 )); then
    IFS= read -rsN1 -u "$TTY_FD" k || return 1
  else
    IFS= read -rsN1 k || return 1
  fi
  if [[ "$k" == $'\x1b' ]]; then
    if (( TTY_FD > 0 )); then
      IFS= read -rsN2 -t 0.01 -u "$TTY_FD" rest || true
    else
      IFS= read -rsN2 -t 0.01 rest || true
    fi
    k+="$rest"
  fi
  key="$k"
}

MODE="exec"
if [[ "$1" == "--print" || "$1" == "--stdout" ]]; then
  MODE="print"
fi

main_loop() {
  history -a "$HISTORY_FILE"
  refresh_terminal_size
  query_cursor_position || {
    echo "reverse-history: unable to locate cursor; aborting" >&2
    exit 1
  }
  fuzzy_search "$search_string" "$HISTORY_FILE"
  render_ui
  while true; do
    if ! read_key; then
      flush_overlay
      exit 1
    fi
    case "$key" in
      $'\x7f') # backspace
      if [[ -n "$search_string" ]]; then
          delete_last_query_char
          current_cmd_index=1
        fi
        fuzzy_search "$search_string" "$HISTORY_FILE"
        render_ui
        ;;
      $'\x01') # Ctrl-A
        rotate_query_words
        current_cmd_index=1
        fuzzy_search "$search_string" "$HISTORY_FILE"
        render_ui
        ;;
      $'\x15') # Ctrl-U
        search_string=""
        current_cmd_index=1
        fuzzy_search "$search_string" "$HISTORY_FILE"
        render_ui
        ;;
      $'\x17') # Ctrl-W
        delete_query_word
        current_cmd_index=1
        fuzzy_search "$search_string" "$HISTORY_FILE"
        render_ui
        ;;
      $'\x1b[A') # up
        if (( matches_count > 0 )); then
          (( current_cmd_index-- ))
          if (( current_cmd_index < 1 )); then current_cmd_index=$matches_count; fi
          update_display_start
          render_ui
        fi
        ;;
      $'\x1b[B') # down
        if (( matches_count > 0 )); then
          (( current_cmd_index++ ))
          if (( current_cmd_index > matches_count )); then current_cmd_index=1; fi
          update_display_start
          render_ui
        fi
        ;;
      $'\n'|$'\r') # enter
        if (( matches_count > 0 )); then
          selected_line=$(awk -v idx="$current_cmd_index" 'NR==idx' <<< "$cmd_matches")
          flush_overlay
          if [[ "$MODE" == "print" ]]; then
            printf '%s' "$selected_line"
          else
            printf '%s\n' "$selected_line"
            bash -c "$selected_line"
          fi
          exit 0
        else
          flush_overlay
          exit 1
        fi
        ;;
      $'\x03'|$'\x1b') # Ctrl-C or Esc
        cancel_picker
        ;;
      *)
        if [[ -n "$key" && "$key" =~ [[:print:]] ]]; then
          search_string+="$key"
          current_cmd_index=1
          fuzzy_search "$search_string" "$HISTORY_FILE"
          render_ui
        fi
        ;;
    esac
  done
}

main_loop
