#!/usr/bin/env bash

# ---------- Configuration ----------
HISTORY_FILE="$HOME/.bash_history"
MAX_DISPLAY=6
HIGHLIGHT_ON=$'\033[1;33m'
ACTIVE_ON=$'\033[7m'
RESET=$'\033[0m'
if ! [[ "$MAX_DISPLAY" =~ ^[0-9]+$ ]] || (( MAX_DISPLAY < 1 )); then
  MAX_DISPLAY=6
fi
PAGE_SIZE=$MAX_DISPLAY
if (( PAGE_SIZE > 20 )); then
  PAGE_SIZE=20
fi

# ---------- State ----------
current_cmd_index=1   # 1-based index for easier selection
display_start=1
search_string="${RHB_QUERY:-}"
cmd_matches_array=()
history_original=()
history_lower=()
history_loaded=0
previous_search_string=""
previous_search_lower=""
previous_match_indices=()
previous_match_indices_snapshot=()
matches_count=0
partial_results=0
history_stream_active=0
history_stream_fd=0
history_stream_sep=$'\034'
history_records_file=""
history_records_source=""
overlay_cap_rows=0
overlay_rows=0
cursor_row=0
cursor_col=0
cursor_saved=0
picker_prompt_line=""
picker_prompt_len=0
terminal_rows=24
terminal_cols=80
terminal_resized=1
truncated_line=""
highlighted_line=""
highlight_query=""
highlight_tokens=()
highlight_tokens_lower=()
search_results_more=0
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
  local stty_rows stty_cols
  read -r stty_rows stty_cols < <(stty size 2>/dev/null < "$TTY" || true)
  terminal_rows="$stty_rows"
  terminal_cols="$stty_cols"
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
  local print_line="${3:-$restored_line}"
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
  if [[ "$MODE" == "print" ]]; then
    printf '%s' "$print_line"
  fi
  exit 130
}

trap 'cancel_picker "${picker_prompt_line:-$(get_prompt_line)}" "$search_string"' INT TERM
trap 'terminal_resized=1' WINCH

format_prompt_pwd() {
  local dir="${1:-$PWD}"
  local home_dir="${HOME:-}"

  if [[ -n "$home_dir" ]]; then
    if [[ "$dir" == "$home_dir" ]]; then
      printf '~'
      return
    fi
    if [[ "$dir" == "$home_dir/"* ]]; then
      printf '~/%s' "${dir#"$home_dir/"}"
      return
    fi
  fi

  printf '%s' "$dir"
}

expand_prompt_escapes() {
  local prompt="$1"
  local host_short="${HOSTNAME%%.*}"
  local host_full="$HOSTNAME"
  local prompt_char='$'
  local debian_chroot_expr='${debian_chroot:+($debian_chroot)}'
  local debian_chroot_value="${debian_chroot:-}"
  local expanded=""
  local char next
  local i
  local non_printing=0

  if (( EUID == 0 )); then
    prompt_char="#"
  fi

  if [[ "$prompt" == *"$debian_chroot_expr"* ]]; then
    if [[ -n "$debian_chroot_value" ]]; then
      prompt="${prompt//"$debian_chroot_expr"/($debian_chroot_value)}"
    else
      prompt="${prompt//"$debian_chroot_expr"/}"
    fi
  fi

  for (( i=0; i<${#prompt}; i++ )); do
    char="${prompt:i:1}"

    if (( non_printing == 1 )); then
      if [[ "$char" == "\\" ]]; then
        next="${prompt:i+1:1}"
        case "$next" in
          "]")
            non_printing=0
            ((i++))
            ;;
          "e")
            expanded+=$'\033'
            ((i++))
            ;;
          "0")
            if [[ "${prompt:i+1:3}" == "033" ]]; then
              expanded+=$'\033'
              ((i += 3))
            else
              expanded+="$next"
              ((i++))
            fi
            ;;
          "\\")
            expanded+="\\"
            ((i++))
            ;;
          *)
            expanded+="$next"
            ((i++))
            ;;
        esac
      else
        expanded+="$char"
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
        expanded+="$(format_prompt_pwd "$PWD")"
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
      "0")
        if [[ "${prompt:i:3}" == "033" ]]; then
          expanded+=$'\033'
          ((i += 2))
        else
          expanded+="$next"
        fi
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
  expanded="$(expand_prompt_escapes "$prompt")"

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
  printf '%s@%s:%s\$ ' "$USER" "$prompt_host" "$(format_prompt_pwd "$PWD")"
}

emit_normalized_history() {
  local history_file="$1"
  local sep="$2"

  awk -v merge_multiline="${RHB_MERGE_MULTILINE:-1}" -v sep="$sep" '
    function flush_pending() {
      if (pending_set == 1) {
        history[++history_len] = pending
        pending_set = 0
        pending = ""
      }
    }

    BEGIN {
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
      for (i = history_len; i >= 1; i--) {
        line = history[i]
        if (line == "") {
          continue
        }
        if (seen[line]++) {
          continue
        }
        print tolower(line) sep line
      }
    }
  ' < <(tr -d '\000' < "$history_file" 2>/dev/null || true)
}

load_history_records() {
  local record_file="$1"
  local sep="$2"
  local record line lower

  history_original=()
  history_lower=()

  while IFS= read -r record; do
    [[ "$record" == *"$sep"* ]] || continue
    lower="${record%%"$sep"*}"
    line="${record#*"$sep"}"
    history_lower+=("$lower")
    history_original+=("$line")
  done < "$record_file"
}

load_history_entries_uncached() {
  local history_file="$1"
  local sep="$2"
  local record line lower

  history_original=()
  history_lower=()

  while IFS= read -r record; do
    [[ "$record" == *"$sep"* ]] || continue
    lower="${record%%"$sep"*}"
    line="${record#*"$sep"}"
    history_lower+=("$lower")
    history_original+=("$line")
  done < <(emit_normalized_history "$history_file" "$sep")
}

history_cache_paths() {
  local history_file="$1"
  local cache_root cache_key

  cache_root="${RHB_CACHE_DIR:-${XDG_CACHE_HOME:-$HOME/.cache}/reverse-history-bash}"
  cache_key="${history_file//\//_}"
  cache_key="${cache_key//[^[:alnum:]_.-]/_}"
  if [[ -z "$cache_key" ]]; then
    cache_key="history"
  fi
  printf '%s\n%s\n%s\n' "$cache_root" "${cache_root}/${cache_key}.cache" "${cache_root}/${cache_key}.meta"
}

history_cache_valid() {
  local history_file="$1"
  local cache_data="$2"
  local cache_meta="$3"
  local history_size history_mtime
  local meta_version meta_file meta_size meta_mtime meta_merge

  [[ -r "$cache_data" && -r "$cache_meta" ]] || return 1

  read -r history_size history_mtime < <(stat -c '%s %Y' "$history_file" 2>/dev/null || printf '0 0\n')
  {
    IFS= read -r meta_version
    IFS= read -r meta_file
    IFS= read -r meta_size
    IFS= read -r meta_mtime
    IFS= read -r meta_merge
  } < "$cache_meta"

  [[ "$meta_version" == "v1" &&
     "$meta_file" == "$history_file" &&
     "$meta_size" == "$history_size" &&
     "$meta_mtime" == "$history_mtime" &&
     "$meta_merge" == "${RHB_MERGE_MULTILINE:-1}" ]]
}

ensure_history_records_file() {
  local history_file="$1"
  local cache_root cache_data cache_meta tmp_data tmp_meta
  local history_size history_mtime

  if [[ "$history_records_source" == "$history_file" && -n "$history_records_file" && -r "$history_records_file" ]]; then
    return 0
  fi

  history_records_file=""
  history_records_source=""

  {
    IFS= read -r cache_root
    IFS= read -r cache_data
    IFS= read -r cache_meta
  } < <(history_cache_paths "$history_file")

  if history_cache_valid "$history_file" "$cache_data" "$cache_meta"; then
    history_records_file="$cache_data"
    history_records_source="$history_file"
    return 0
  fi

  read -r history_size history_mtime < <(stat -c '%s %Y' "$history_file" 2>/dev/null || printf '0 0\n')

  if ! mkdir -p "$cache_root" 2>/dev/null; then
    return 1
  fi

  tmp_data="${cache_data}.$$"
  tmp_meta="${cache_meta}.$$"
  if ! emit_normalized_history "$history_file" "$history_stream_sep" > "$tmp_data"; then
    return 1
  fi

  {
    printf '%s\n' "v1"
    printf '%s\n' "$history_file"
    printf '%s\n' "$history_size"
    printf '%s\n' "$history_mtime"
    printf '%s\n' "${RHB_MERGE_MULTILINE:-1}"
  } > "$tmp_meta"

  if mv "$tmp_data" "$cache_data" 2>/dev/null; then
    mv "$tmp_meta" "$cache_meta" 2>/dev/null || true
    history_records_file="$cache_data"
  else
    history_records_file="$tmp_data"
  fi
  history_records_source="$history_file"
  return 0
}

close_history_stream() {
  if (( history_stream_active == 1 )); then
    exec {history_stream_fd}<&- 2>/dev/null || true
  fi
  history_stream_active=0
}

load_initial_cached_page() {
  local history_file="$1"
  local sep=$'\034'
  local records_file
  local record line lower limit read_count

  if [[ -n "$search_string" ]]; then
    return 1
  fi

  ensure_history_records_file "$history_file" || return 1
  records_file="$history_records_file"

  close_history_stream
  exec {history_stream_fd}< "$records_file" || return 1
  history_stream_active=1
  history_stream_sep="$sep"
  history_loaded=0
  history_original=()
  history_lower=()
  cmd_matches_array=()
  matches_count=0
  partial_results=0
  limit="$PAGE_SIZE"
  read_count=0

  while IFS= read -r -u "$history_stream_fd" record; do
    [[ "$record" == *"$sep"* ]] || continue
    lower="${record%%"$sep"*}"
    line="${record#*"$sep"}"
    history_lower+=("$lower")
    history_original+=("$line")
    (( read_count++ ))
    if (( read_count > limit )); then
      partial_results=1
      break
    fi
    cmd_matches_array+=("$line")
  done

  matches_count=${#cmd_matches_array[@]}
  if (( matches_count == 0 )); then
    exec {history_stream_fd}<&- 2>/dev/null || true
    history_stream_active=0
    history_loaded=1
    return 1
  fi

  if (( partial_results == 0 )); then
    exec {history_stream_fd}<&- 2>/dev/null || true
    history_stream_active=0
    history_loaded=1
  fi

  current_cmd_index=1
  display_start=1
  return 0
}

preload_history_chunk() {
  local limit="${1:-512}"
  local record line lower loaded=0

  if (( history_stream_active != 1 )); then
    return 1
  fi

  while (( loaded < limit )) && IFS= read -r -u "$history_stream_fd" record; do
    [[ "$record" == *"$history_stream_sep"* ]] || continue
    lower="${record%%"$history_stream_sep"*}"
    line="${record#*"$history_stream_sep"}"
    history_lower+=("$lower")
    history_original+=("$line")
    (( loaded++ ))
  done

  if (( loaded < limit )); then
    exec {history_stream_fd}<&- 2>/dev/null || true
    history_stream_active=0
    history_loaded=1
    if [[ -z "$search_string" ]]; then
      cmd_matches_array=("${history_original[@]}")
      matches_count=${#cmd_matches_array[@]}
      partial_results=0
    fi
    return 1
  fi

  return 0
}

finish_history_preload() {
  while (( history_stream_active == 1 )); do
    preload_history_chunk 2048 || break
  done
}

ensure_full_results() {
  if (( partial_results != 1 )); then
    return
  fi

  finish_history_preload
  partial_results=0
  previous_search_string=""
  previous_search_lower=""
  previous_match_indices=()
  previous_match_indices_snapshot=()
  if [[ -z "$search_string" ]]; then
    cmd_matches_array=("${history_original[@]}")
    matches_count=${#cmd_matches_array[@]}
    if (( matches_count == 0 )); then
      current_cmd_index=1
    elif (( current_cmd_index < 1 )); then
      current_cmd_index=$matches_count
    elif (( current_cmd_index > matches_count )); then
      current_cmd_index=1
    fi
    update_display_start
    return
  fi
  fuzzy_search "$search_string" "$HISTORY_FILE" full
}

load_history_entries() {
  local history_file="$1"
  local sep=$'\034'

  if (( history_loaded == 1 )); then
    return
  fi

  if ensure_history_records_file "$history_file"; then
    load_history_records "$history_records_file" "$sep"
  else
    load_history_entries_uncached "$history_file" "$sep"
  fi

  history_loaded=1
}

search_history_records_file() {
  local lower_query="$1"
  local records_file="$2"
  local result_limit="${3:-0}"
  local sep=$'\034'
  local count_marker="${sep}count${sep}"
  local result_count

  [[ -r "$records_file" ]] || return 1

  search_results_more=0
  mapfile -t cmd_matches_array < <(
    awk -v sep="$sep" -v query="$lower_query" -v result_limit="$result_limit" -v count_marker="$count_marker" '
      BEGIN {
        count = 0
        raw_count = split(query, raw_tokens, /[[:space:]]+/)
        for (idx = 1; idx <= raw_count; idx++) {
          if (raw_tokens[idx] != "") {
            tokens[++token_count] = raw_tokens[idx]
          }
        }
        if (token_count == 1) {
          single_token = tokens[1]
        }
      }

      {
        sep_pos = index($0, sep)
        if (sep_pos == 0) {
          next
        }

        lower_line = substr($0, 1, sep_pos - 1)
        if (single_token != "") {
          matched = (index(lower_line, single_token) != 0)
        } else {
          matched = 1
          for (idx = 1; idx <= token_count; idx++) {
            if (index(lower_line, tokens[idx]) == 0) {
              matched = 0
              break
            }
          }
        }

        if (matched == 1) {
          count++
          line = substr($0, sep_pos + length(sep))
          if (result_limit > 0) {
            if (count <= result_limit) {
              results[count] = line
            }
            if (count > result_limit) {
              exit
            }
          } else {
            print line
          }
        }
      }

      END {
        if (result_limit > 0) {
          print count_marker count
          for (idx = 1; idx <= count && idx <= result_limit; idx++) {
            print results[idx]
          }
        }
      }
    ' "$records_file"
  )
  if (( result_limit > 0 )); then
    if [[ "${cmd_matches_array[0]:-}" == "$count_marker"* ]]; then
      result_count="${cmd_matches_array[0]#"$count_marker"}"
      cmd_matches_array=("${cmd_matches_array[@]:1}")
      if (( result_count > result_limit )); then
        search_results_more=1
        matches_count=${#cmd_matches_array[@]}
      else
        matches_count=$result_count
      fi
    else
      return 1
    fi
  else
    matches_count=${#cmd_matches_array[@]}
  fi
  return 0
}

fuzzy_search() {
  local query="$1"
  local history_file="$2"
  local result_mode="${3:-page}"
  local lower_query
  local -a tokens
  local idx token lower_line matched history_len
  local result_limit="$PAGE_SIZE"

  partial_results=0
  if [[ "$result_mode" == "full" ]]; then
    result_limit=0
  fi
  lower_query="${query,,}"
  read -r -a tokens <<< "$lower_query"

  cmd_matches_array=()
  previous_match_indices=()

  if (( ${#tokens[@]} == 0 )); then
    previous_search_string=""
    previous_search_lower=""
    previous_match_indices_snapshot=()

    if load_initial_cached_page "$history_file"; then
      return
    fi

    finish_history_preload
    load_history_entries "$history_file"
    cmd_matches_array=("${history_original[@]}")
    matches_count=${#cmd_matches_array[@]}
    current_cmd_index=1
    update_display_start
    return
  fi

  close_history_stream

  if ensure_history_records_file "$history_file" && search_history_records_file "$lower_query" "$history_records_file" "$result_limit"; then
    if (( result_limit > 0 && search_results_more == 1 )); then
      partial_results=1
    fi
    previous_search_string="$query"
    previous_search_lower="$lower_query"
    previous_match_indices_snapshot=()

    if (( matches_count == 0 )); then
      current_cmd_index=1
    elif (( current_cmd_index < 1 )); then
      current_cmd_index=$matches_count
    elif (( current_cmd_index > matches_count )); then
      current_cmd_index=1
    fi

    update_display_start
    return
  fi

  finish_history_preload
  load_history_entries "$history_file"

  if [[ -n "$previous_search_string" && "$lower_query" == "$previous_search_lower"* ]]; then
    for idx in "${previous_match_indices_snapshot[@]}"; do
      lower_line="${history_lower[idx]}"
      matched=1
      for token in "${tokens[@]}"; do
        if [[ "$lower_line" != *"$token"* ]]; then
          matched=0
          break
        fi
      done
      if (( matched == 1 )); then
        cmd_matches_array+=("${history_original[idx]}")
        previous_match_indices+=("$idx")
      fi
    done
  else
    history_len=${#history_original[@]}
    for (( idx = 0; idx < history_len; idx++ )); do
      lower_line="${history_lower[idx]}"
      matched=1
      for token in "${tokens[@]}"; do
        if [[ "$lower_line" != *"$token"* ]]; then
          matched=0
          break
        fi
      done
      if (( matched == 1 )); then
        cmd_matches_array+=("${history_original[idx]}")
        previous_match_indices+=("$idx")
      fi
    done
  fi

  matches_count=${#cmd_matches_array[@]}
  previous_search_string="$query"
  previous_search_lower="$lower_query"
  previous_match_indices_snapshot=("${previous_match_indices[@]}")

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

  if [[ "$search_string" != *[![:ascii:]]* ]]; then
    search_string="${search_string%?}"
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

page_up() {
  local size visible_top new_start
  size="$PAGE_SIZE"
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
  size="$PAGE_SIZE"
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
    truncated_line=""
  elif (( ${#line} > width )); then
    truncated_line="${line:0:width}"
  else
    truncated_line="$line"
  fi
}

prepare_highlight_tokens() {
  local token clean_token

  if [[ "$highlight_query" == "$search_string" ]]; then
    return
  fi

  highlight_tokens=()
  highlight_tokens_lower=()
  for token in $search_string; do
    clean_token="$token"
    clean_token="${clean_token#^}"
    clean_token="${clean_token%\$}"
    if [[ "$clean_token" == *"["*"]"* || -z "$clean_token" ]]; then
      continue
    fi
    highlight_tokens+=("$clean_token")
    highlight_tokens_lower+=("${clean_token,,}")
  done
  highlight_query="$search_string"
}

highlight_matches() {
  local line="$1"
  local restore_after_match="${2:-$RESET}"
  local token lower_line lower_token
  local highlighted="" best_match best_len
  local pos token_idx token_len

  if (( ${#highlight_tokens[@]} == 0 )); then
    highlighted_line="$line"
    return
  fi

  lower_line="${line,,}"
  pos=0
  while (( pos < ${#line} )); do
    best_match=""
    best_len=0
    for (( token_idx = 0; token_idx < ${#highlight_tokens[@]}; token_idx++ )); do
      token="${highlight_tokens[token_idx]}"
      lower_token="${highlight_tokens_lower[token_idx]}"
      token_len=${#token}
      if [[ "${lower_line:pos:token_len}" == "$lower_token" && token_len -gt best_len ]]; then
        best_match="${line:pos:token_len}"
        best_len=$token_len
      fi
    done

    if (( best_len > 0 )); then
      highlighted+="${HIGHLIGHT_ON}${best_match}${restore_after_match}"
      pos=$(( pos + best_len ))
    else
      highlighted+="${line:pos:1}"
      (( pos++ ))
    fi
  done

  highlighted_line="$highlighted"
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
  if (( terminal_resized == 1 )); then
    refresh_terminal_size
    terminal_resized=0
  fi
  if (( cursor_row <= 0 || cursor_col <= 0 )); then
    return
  fi

  save_cursor
  hide_cursor

  local cols="$terminal_cols"
  local page_size
  page_size="$PAGE_SIZE"
  local draw_cols=$(( cols - 1 ))
  if (( draw_cols < 1 )); then draw_cols=1; fi
  local idx_text="[0/0]"
  local visible_count=0
  local loading_text=""
  if (( matches_count > 0 )); then
    if (( partial_results == 1 )); then
      idx_text="["$current_cmd_index"/"$matches_count"+]"
    else
      idx_text="["$current_cmd_index"/"$matches_count"]"
    fi
  fi
  if (( history_stream_active == 1 )); then
    loading_text=" loading..."
  fi
  local prompt_line prefix
  prompt_line="$picker_prompt_line"
  if [[ -z "$prompt_line" ]]; then
    prompt_line="$(get_prompt_line)"
  fi
  if [[ -n "$prompt_line" ]]; then
    if [[ -n "$search_string" && "${prompt_line: -1}" != " " ]]; then
      prefix="${prompt_line} ${search_string}"
    else
      prefix="${prompt_line}${search_string}"
    fi
  else
    prefix="$search_string"
  fi

  local status_text="$idx_text$loading_text"

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
  draw_overlay_line "$prefix"
  tty_printf '\0337'
  if [[ -n "$status_text" ]]; then
    if [[ -n "$prefix" && "${prefix: -1}" != " " ]]; then
      tty_printf ' '
    fi
    tty_printf '%s' "$status_text"
  fi

  prepare_highlight_tokens
  local idx=$display_start
  local row_num=1
  while (( row_num < overlay_rows )); do
    local line="${cmd_matches_array[idx-1]}"
    local row_prefix="  "
    if (( idx == current_cmd_index )); then
      row_prefix="> "
    fi
    local visible_line
    truncate_line "$line" "$(( draw_cols - 2 ))"
    visible_line="$truncated_line"
    if (( idx == current_cmd_index )); then
      highlight_matches "$visible_line" "${RESET}${ACTIVE_ON}"
    else
      highlight_matches "$visible_line"
    fi
    visible_line="$highlighted_line"
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
  tty_printf '\0338'
}

read_key() {
  local timeout="${1:-}"
  local k rest
  key=""
  if (( TTY_FD > 0 )); then
    if [[ -n "$timeout" ]]; then
      IFS= read -rsN1 -t "$timeout" -u "$TTY_FD" k || {
        [[ -z "$k" ]] && return 2
        return 1
      }
    else
      IFS= read -rsN1 -u "$TTY_FD" k || return 1
    fi
  else
    if [[ -n "$timeout" ]]; then
      IFS= read -rsN1 -t "$timeout" k || {
        [[ -z "$k" ]] && return 2
        return 1
      }
    else
      IFS= read -rsN1 k || return 1
    fi
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
  terminal_resized=0
  query_cursor_position || {
    echo "reverse-history: unable to locate cursor; aborting" >&2
    exit 1
  }
  picker_prompt_line="$(get_prompt_line)"
  picker_prompt_len="$(prompt_visible_length "$picker_prompt_line")"
  load_initial_cached_page "$HISTORY_FILE" || fuzzy_search "$search_string" "$HISTORY_FILE"
  render_ui
  while true; do
    if (( history_stream_active == 1 )); then
      read_key 0.001
      read_rc=$?
      if (( read_rc == 2 )); then
        if ! preload_history_chunk 64; then
          render_ui
        fi
        continue
      elif (( read_rc != 0 )); then
        flush_overlay
        exit 1
      fi
    elif ! read_key; then
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
      if (( partial_results == 1 && matches_count > 0 && current_cmd_index > 1 )); then
        (( current_cmd_index-- ))
        update_display_start
        render_ui
      else
        ensure_full_results
        if (( matches_count > 0 )); then
          (( current_cmd_index-- ))
          if (( current_cmd_index < 1 )); then current_cmd_index=$matches_count; fi
          update_display_start
          render_ui
        fi
      fi
    elif [[ "$key" == $'\x1b[B' ]]; then
      if (( partial_results == 1 && matches_count > 0 && current_cmd_index < ${#cmd_matches_array[@]} )); then
        (( current_cmd_index++ ))
        update_display_start
        render_ui
      else
        ensure_full_results
        if (( matches_count > 0 )); then
          (( current_cmd_index++ ))
          if (( current_cmd_index > matches_count )); then current_cmd_index=1; fi
          update_display_start
          render_ui
        fi
      fi
    elif [[ "$key" == $'\x1b[5~' ]]; then
      ensure_full_results
      if (( matches_count > 0 )); then
        page_up
        render_ui
      fi
    elif [[ "$key" == $'\x1b[6~' ]]; then
      ensure_full_results
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
    elif [[ "$key" == $'\x03' ]]; then
      cancel_picker "${picker_prompt_line:-$(get_prompt_line)}" "$search_string"
    elif [[ -n "$key" && "$key" =~ [[:print:]] ]]; then
      search_string+="$key"
      current_cmd_index=1
      fuzzy_search "$search_string" "$HISTORY_FILE"
      render_ui
    fi
  done
}

main_loop
