#!/usr/bin/env bash

# ---------- Configuration ----------
HISTORY_FILE="$HOME/.bash_history"
MAX_DISPLAY=5
HIGHLIGHT_ON=$'\033[1;33m'
ACTIVE_ON=$'\033[7m'
RESET=$'\033[0m'
if ! [[ "$MAX_DISPLAY" =~ ^[0-9]+$ ]] || (( MAX_DISPLAY < 1 )); then
  MAX_DISPLAY=5
fi

# ---------- State ----------
current_cmd_index=1   # 1-based index for easier selection
display_start=1
search_string="${RHB_QUERY:-}"
cmd_matches=""
cmd_matches_array=()
matches_count=0
overlay_cap_rows=0
overlay_rows=0
cursor_row=0
cursor_col=0
cursor_saved=0
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
  # Avoid depending on terminal save/restore semantics across prompt implementations.
  # We still keep the escape for compatibility, but we always reposition using
  # the measured cursor coordinates recorded before rendering.
  tty_printf '\0337'
  cursor_saved=1
}

restore_cursor() {
  if (( cursor_saved == 1 && cursor_row > 0 && cursor_col > 0 )); then
    move_cursor "$cursor_row" "$cursor_col"
  fi
}

hide_cursor() {
  tty_printf '\033[?25l'
}

show_cursor() {
  tty_printf '\033[?25h'
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
    rows=$overlay_cap_rows
  fi

  if (( rows <= 0 )); then
    return
  fi
  if (( cursor_row <= 0 || cursor_col <= 0 )); then
    return
  fi
  local clear_rows=$(( rows > 0 ? rows : 1 ))
  if (( rows > terminal_rows )); then
    clear_rows=$terminal_rows
  fi
  if (( clear_rows > terminal_rows - cursor_row + 1 )); then
    clear_rows=$(( terminal_rows - cursor_row + 1 ))
  fi
  if (( clear_rows <= 0 )); then
    return
  fi

  move_cursor "$cursor_row" 1
  tty_printf '\r\033[2K'
  if (( clear_rows > 1 )); then
    tty_printf '\033[J'
  fi
}

cancel_picker() {
  local prompt_line="$1"
  local restored_line="$2"
  flush_overlay
  if (( cursor_row > 0 )); then
    move_cursor "$cursor_row" 1
    tty_printf '\r\033[2K'
    if [[ -n "$prompt_line" ]]; then
      if [[ -n "$restored_line" && "${prompt_line: -1}" != " " ]]; then
        tty_printf '%s %s' "$prompt_line" "$restored_line"
      else
        tty_printf '%s%s' "$prompt_line" "$restored_line"
      fi
    else
      tty_printf '%s' "$restored_line"
    fi
  fi
  show_cursor
  exit 130
}

trap 'cancel_picker "$(get_prompt_line)" "${RHB_QUERY:-}"' INT TERM

count_matches() {
  if [[ -z "$cmd_matches" ]]; then
    matches_count=0
    cmd_matches_array=()
  else
    mapfile -t cmd_matches_array <<< "$cmd_matches"
    matches_count=${#cmd_matches_array[@]}
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

prompt_visible_length() {
  local prompt="$1"
  local sanitized
  sanitized="$(printf '%s' "$prompt" | awk '{
    gsub(/\x1b\[[0-9;]*[[:alpha:]]/, "", $0)
    gsub(/\x1b\][^\a]*\a/, "", $0)
    gsub(/\r/, "", $0)
    print
  }')"
  printf '%s' "${#sanitized}"
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
  cmd_matches=$(awk -v query="$query" -v merge_multiline="${RHB_MERGE_MULTILINE:-1}" '
    function flush_pending() {
      if (pending_set == 1) {
        history[++history_len] = pending
        pending_set = 0
        pending = ""
      }
    }

    BEGIN {
      query = tolower(query)
      token_count = split(query, raw_tokens, /[[:space:]]+/)
      for (i = 1; i <= token_count; i++) {
        if (raw_tokens[i] != "") {
          tokens[++tokens_len] = tolower(raw_tokens[i])
        }
      }
      pending = ""
      pending_set = 0
    }

    {
      line = $0
      sub(/\r$/, "", line)

      if (line ~ /^#[0-9]+$/) {
        next
      }

      if (length(line) == 0) {
        flush_pending()
        next
      }

      if (merge_multiline != 1) {
        history[++history_len] = line
        next
      }

      if (pending_set == 1 && (line ~ /^[[:space:]]/ || pending ~ /\\$/)) {
        pending = pending " " line
      } else {
        flush_pending()
        pending = line
        pending_set = 1
      }
    }

    END {
      flush_pending()
      if (history_len == 0) {
        exit
      }
      if (token_count == 0) {
        for (i = history_len; i >= 1; i--) {
          line = history[i]
          if (line == "") {
            continue
          }
          if (seen[line]++) {
            continue
          }
          print line
        }
        exit
      }

      for (i = history_len; i >= 1; i--) {
        line = history[i]
        if (line == "") {
          continue
        }
        lower = tolower(line)
        if (seen[line]++) {
          continue
        }
        matched = 1
        for (j = 1; j <= token_count; j++) {
          if (index(lower, tokens[j]) == 0) {
            matched = 0
            break
          }
        }
        if (matched) {
          print line
        }
      }
    }
  ' < <(tr -d '\000' < "$history_file" 2>/dev/null || true))

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

page_size() {
  local size="$MAX_DISPLAY"
  if (( size < 1 )); then
    size=10
  fi
  if (( size > 20 )); then
    size=20
  fi
  printf '%s' "$size"
}

page_up() {
  local size visible_top new_start
  size="$(page_size)"
  if (( matches_count <= 0 )); then
    return
  fi

  visible_top=$display_start
  if (( current_cmd_index > visible_top )); then
    current_cmd_index=$visible_top
    return
  fi

  new_start=$(( display_start - size ))
  if (( new_start < 1 )); then
    new_start=1
  fi
  display_start=$new_start
  current_cmd_index=$display_start
}

page_down() {
  local size max_start visible_bottom new_start
  size="$(page_size)"
  if (( matches_count <= 0 )); then
    return
  fi

  visible_bottom=$(( display_start + size - 1 ))
  if (( visible_bottom > matches_count )); then
    visible_bottom=$matches_count
  fi
  if (( current_cmd_index < visible_bottom )); then
    current_cmd_index=$visible_bottom
    return
  fi

  max_start=$(( matches_count - size + 1 ))
  if (( max_start < 1 )); then
    max_start=1
  fi
  new_start=$(( display_start + size ))
  if (( new_start > max_start )); then
    new_start=$max_start
  fi
  display_start=$new_start
  current_cmd_index=$(( display_start + size - 1 ))
  if (( current_cmd_index > matches_count )); then
    current_cmd_index=$matches_count
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
  local restore_after_match="${2:-$RESET}"
  local token clean_token token_escaped highlighted="$line"
  for token in $search_string; do
    clean_token="$token"
    clean_token="${clean_token#^}"
    clean_token="${clean_token%\$}"
    if [[ "$clean_token" == *"["*"]"* || -z "$clean_token" ]]; then
      continue
    fi
    token_escaped="${clean_token//\\/\\\\}"
    highlighted=$(printf '%s\n' "$highlighted" | awk -v token="$token_escaped" -v on="$HIGHLIGHT_ON" -v off="$restore_after_match" '
      BEGIN {
        lower_line = ""
        line = ""
        needle = tolower(token)
        n = length(needle)
        if (n == 0) {
          print ""
          exit
        }
        if (getline line != 1) {
          exit
        }
        lower_line = tolower(line)
        out = ""
        pos = 1
        while ((idx = index(substr(lower_line, pos), needle)) > 0) {
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

  save_cursor
  hide_cursor

  local cols="$terminal_cols"
  local page_size
  page_size="$(page_size)"
  local draw_cols=$(( cols - 1 ))
  if (( draw_cols < 1 )); then draw_cols=1; fi
  local idx_text="[0/0]"
  local selected=""
  local selected_plain=""
  local visible_count=0
  local query_cursor_col="$cursor_col"
  if (( matches_count > 0 )); then
    idx_text="["$current_cmd_index"/"$matches_count"]"
    selected_plain="${cmd_matches_array[current_cmd_index-1]}"
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

  if [[ -n "$prompt_line" ]]; then
    local prompt_len
    prompt_len="$(prompt_visible_length "$prompt_line")"
    if [[ "$prompt_len" =~ ^[0-9]+$ ]]; then
      query_cursor_col=$(( prompt_len + ${#search_string} + 1 ))
    fi
  fi
  if (( query_cursor_col < 1 )); then
    query_cursor_col=1
  fi
  if (( query_cursor_col > terminal_cols )); then
    query_cursor_col=$terminal_cols
  fi

  local max_selected_len=$(( draw_cols - 4 ))
  if (( max_selected_len < 0 )); then max_selected_len=0; fi
  selected_plain=$(truncate_line "$selected_plain" "$max_selected_len")
  selected=$(highlight_matches "$selected_plain")

  local max_lines_below=$(( terminal_rows - cursor_row + 1 ))
  if (( max_lines_below <= 0 )); then
    overlay_cap_rows=$overlay_rows
    overlay_rows=0
    flush_overlay
    show_cursor
    restore_cursor
    return
  fi

  local max_overlay_rows=$(( page_size + 1 ))
  if (( max_overlay_rows > max_lines_below )); then
    max_overlay_rows=$max_lines_below
  fi

  if (( matches_count > 0 )); then
    local max_visible_rows=$(( max_overlay_rows - 1 ))
    visible_count=$(( matches_count - display_start + 1 ))
    if (( visible_count > max_visible_rows )); then
      visible_count=$max_visible_rows
    fi
    if (( visible_count < 0 )); then
      visible_count=0
    fi
  fi

  local new_overlay_rows=$(( visible_count + 1 ))
  if (( new_overlay_rows > max_overlay_rows )); then
    new_overlay_rows=$max_overlay_rows
  fi

  flush_overlay "$overlay_cap_rows"
  overlay_rows=$new_overlay_rows
  if (( overlay_rows > overlay_cap_rows )); then
    overlay_cap_rows=$overlay_rows
  fi
  if (( overlay_rows <= 0 )); then
    flush_overlay
    show_cursor
    restore_cursor
    return
  fi

  restore_cursor
  draw_overlay_line "$header"

  local idx=$display_start
  local row_num=1
  while (( row_num < overlay_rows )); do
    local line="${cmd_matches_array[idx-1]}"
    local row_prefix="  "
    if (( idx == current_cmd_index )); then
      row_prefix="> "
    fi
    local visible_line
    visible_line=$(truncate_line "$line" "$(( draw_cols - 2 ))")
    if (( idx == current_cmd_index )); then
      visible_line=$(highlight_matches "$visible_line" "${RESET}${ACTIVE_ON}")
    else
      visible_line=$(highlight_matches "$visible_line")
    fi
    local row_text
    tty_printf '\n'
    if (( idx == current_cmd_index )); then
      row_text="${ACTIVE_ON}${row_prefix}${visible_line}${RESET}"
    else
      row_text="${row_prefix}${visible_line}"
    fi
    draw_overlay_line "$row_text"
    (( idx++ ))
    (( row_num++ ))
  done

  show_cursor
  move_cursor "$cursor_row" "$query_cursor_col"
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
      IFS= read -rsN1 -t 0.01 -u "$TTY_FD" rest || true
      if [[ -n "$rest" ]]; then
        k+="$rest"
      fi
      if [[ "$k" == $'\x1b[' ]]; then
        IFS= read -rsN1 -t 0.01 -u "$TTY_FD" rest || true
        if [[ -n "$rest" ]]; then
          k+="$rest"
          if [[ "$rest" == [0-9] ]]; then
            IFS= read -rsN1 -t 0.01 -u "$TTY_FD" rest || true
            if [[ -n "$rest" ]]; then
              k+="$rest"
            fi
          fi
        fi
      fi
    else
      IFS= read -rsN1 -t 0.01 rest || true
      if [[ -n "$rest" ]]; then
        k+="$rest"
      fi
      if [[ "$k" == $'\x1b[' ]]; then
        IFS= read -rsN1 -t 0.01 rest || true
        if [[ -n "$rest" ]]; then
          k+="$rest"
          if [[ "$rest" == [0-9] ]]; then
            IFS= read -rsN1 -t 0.01 rest || true
            if [[ -n "$rest" ]]; then
              k+="$rest"
            fi
          fi
        fi
      fi
    fi
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
    if [[ "$key" == $'\x7f' ]]; then
      if [[ -n "$search_string" ]]; then
        delete_last_query_char
        current_cmd_index=1
      fi
      fuzzy_search "$search_string" "$HISTORY_FILE"
      render_ui
    elif [[ "$key" == $'\x01' ]]; then
      rotate_query_words
      current_cmd_index=1
      fuzzy_search "$search_string" "$HISTORY_FILE"
      render_ui
    elif [[ "$key" == $'\x15' ]]; then
      search_string=""
      current_cmd_index=1
      fuzzy_search "$search_string" "$HISTORY_FILE"
      render_ui
    elif [[ "$key" == $'\x17' ]]; then
      delete_query_word
      current_cmd_index=1
      fuzzy_search "$search_string" "$HISTORY_FILE"
      render_ui
    elif [[ "$key" == $'\x1b[A' ]]; then
      if (( matches_count > 0 )); then
        (( current_cmd_index-- ))
        if (( current_cmd_index < 1 )); then current_cmd_index=$matches_count; fi
        update_display_start
        render_ui
      fi
    elif [[ "$key" == $'\x1b[B' ]]; then
      if (( matches_count > 0 )); then
        (( current_cmd_index++ ))
        if (( current_cmd_index > matches_count )); then current_cmd_index=1; fi
        update_display_start
        render_ui
      fi
    elif [[ "$key" == $'\x1b[5~' ]]; then
      if (( matches_count > 0 )); then
        page_up
        render_ui
      fi
    elif [[ "$key" == $'\x1b[6~' ]]; then
      if (( matches_count > 0 )); then
        page_down
        render_ui
      fi
    elif [[ "$key" == $'\x0A' || "$key" == $'\x0D' ]]; then
      if (( matches_count > 0 )); then
        selected_line="${cmd_matches_array[current_cmd_index-1]}"
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
    elif [[ "$key" == $'\x03' || "$key" == $'\x1b' ]]; then
      cancel_picker "$(get_prompt_line)" "${RHB_QUERY:-}"
    elif [[ -n "$key" && "$key" =~ [[:print:]] ]]; then
      search_string+="$key"
      current_cmd_index=1
      fuzzy_search "$search_string" "$HISTORY_FILE"
      render_ui
    fi
  done
}

main_loop
