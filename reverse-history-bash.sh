# ---------- Manage Cursor ----------
HISTORY_FILE="~/.bash_history"
PROMPT_COLUMN=49
OFFSET=1
current_cmd_index=0
cmd_matches=''
extract_current_cursor_position() {
    exec < /dev/tty
    oldstty=$(stty -g)
    stty raw -echo min 0
    echo -en "\033[6n" > /dev/tty
    IFS=';' read -r -d R -a queried_cursor_data
    stty $oldstty
    current_cursor_position[0]=$((${queried_cursor_data[0]:2} - 1))
    current_cursor_position[1]=$((${queried_cursor_data[1]}   - 1))
    echo aaaaa$((${queried_cursor_data[0]:2} - 1)) >>test.log
}

adjust_cursor_position() {
    local diff=$(( $(tput lines) - ${current_cursor_position[0]} ))

        tput cup $((${current_cursor_position[0]}     - 1)) $(($PROMPT_COLUMN + $OFFSET))
        current_cursor_position[0]=$((current_cursor_position[0]        + 1))
        current_cursor_position[1]=$(($PROMPT_COLUMN + $OFFSET))
}

# ---------- User Interface Functions ----------


capture_user_input() {
    while IFS= read -r -n 1 char; do
        flush_screen
        if [ "$char" = $'\x7f' ]; then  # Backspace
            search_string="${search_string%?}"
        # TODO: selected_line, global?
        elif [ "$char" =  $'\0A' ]; then  # Enter

            selected_line=$(echo "$cmd_matches" | awk -v idx="$current_cmd_index" 'NR==idx')
            eval "$selected_line"
           echo "Selected line is: $selected_line" >> test.log
            exit 0
        elif [ "$char" = $'\x1b' ]; then  # Escape character
            # Read the next two characters to complete the ANSI escape sequence
            read -r -n 2 next_chars
            escape_sequence="$char$next_chars"
            if [ "$escape_sequence" = $'\x1b[A' ]; then  # Up arrow
                # Increment or do something with current_cmd_index
                current_cmd_index=$((current_cmd_index - 1))
            elif [ "$escape_sequence" = $'\x1b[B' ]; then  # Down arrow
                # Decrement or do something with current_cmd_index
                current_cmd_index=$((current_cmd_index + 1))
            fi
        else
            search_string="$search_string$char"
        fi

        display_search_results
        reposition_cursor
        echo "char: $char" >> test.log
        echo "search string: $search_string" >> test.log
    done
}

# ---------- Search Logic ----------

flush_screen(){
    echo -en "\e[J"
}


print_matches(){
    string="$1"

    count=0
  echo "$string" | while IFS= read -r line; do
    if [ "$current_cmd_index" -eq "$count" ]; then
      echo ">$line"
    else
      echo " $line"
    fi
    count=$((count + 1))
    [ "$count" -ge 5 ] && break
  done
}

fuzzy_search() {   ## active
    local search_string="$1"
    local history_file="$2"
    local matches=$(grep -i "$search_string" "$history_file" | tac | awk '!x[$0]++' )
    matches=$(echo "$matches" | head -5)
    cmd_matches="$matches"
    print_matches "$matches"

}

display_search_results() {  ## active 
    echo -e "\n$(fuzzy_search "$search_string" ~/.bash_history)\n"
    
}

reposition_cursor() {   ## active 
    tput cup $((${current_cursor_position[0]} - 2)) $(($PROMPT_COLUMN + $OFFSET + ${#search_string} ))
    echo     $((${current_cursor_position[0]} - 2)) $(($PROMPT_COLUMN + $OFFSET + ${#search_string} )) >> test.log
}

# ---------- Main Program ----------

history -a ~/.bash_history
search_string=""
extract_current_cursor_position 
adjust_cursor_position
capture_user_input
