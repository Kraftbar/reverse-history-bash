# ---------- Manage Cursor ----------
HISTORY_FILE="~/.bash_history"
PROMPT_COLUMN=49
OFFSET=1
current_cmd_index=0

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

    if [ $diff -lt 5 ]; then
        tput cup $((current_cursor_position[0] + diff - 6)) $(($PROMPT_COLUMN + $OFFSET))
        current_cursor_position[0]=$((current_cursor_position[0] + diff - 6))
        current_cursor_position[1]=$(($PROMPT_COLUMN + $OFFSET))
    else
        tput cup $((${current_cursor_position[0]}     - 1)) $(($PROMPT_COLUMN + $OFFSET))
        current_cursor_position[0]=$((current_cursor_position[0]        + 1))
        current_cursor_position[1]=$(($PROMPT_COLUMN + $OFFSET))
    fi
}

# ---------- User Interface Functions ----------


capture_user_input() {    ## active 
    while IFS= read -r -n 1 char; do
    flush_screen
        if [ "$char" = $'\x7f' ]; then
            search_string="${search_string%?}"
        else
            search_string="$search_string$char"
        fi

        display_search_results
        reposition_cursor
        echo "sadad"$char"sda" >> test.log
        echo $search_string >> test.log
    done
}

# ---------- Search Logic ----------

flush_screen(){
    echo -en "\e[J"
}

fuzzy_search() {   ## active
    local search_string="$1"
    local history_file="$2"
    local matches=$(grep -i "$search_string" "$history_file" | tac | awk '!x[$0]++' )
    echo "$matches" | head -5
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
