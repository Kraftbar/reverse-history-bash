# ---------- Manage Cursor ----------
HISTORY_FILE="~/.bash_history"
PROMPT_COLUMN=49
OFFSET=1

extract_current_cursor_position() {
    export $1
    exec < /dev/tty
    oldstty=$(stty -g)
    stty raw -echo min 0
    echo -en "\033[6n" > /dev/tty
    IFS=';' read -r -d R -a pos
    stty $oldstty
    eval "$1[0]=$((${pos[0]:2} - 1))"
    eval "$1[1]=$((${pos[1]}   - 1))"
}

adjust_cursor_position() {
    local diff=$(( $(tput lines) - ${pos1[0]} ))

    if [ $diff -lt 5 ]; then
        tput cup $((pos1[0] + diff - 6)) $(($PROMPT_COLUMN + $OFFSET))
        pos1[0]=$((pos1[0] + diff - 6))
        pos1[1]=$(($PROMPT_COLUMN + $OFFSET))
    else
        tput cup $((${pos1[0]} - 1)) $(($PROMPT_COLUMN + $OFFSET))
        pos1[0]=$((pos1[0] + 1))
        pos1[1]=$(($PROMPT_COLUMN + $OFFSET))
    fi
}

# ---------- User Interface Functions ----------


capture_user_input() {    ## active 
    while IFS= read -r -n 1 char; do
        if [ "$char" = $'\x7f' ]; then
            echo "testestetsetst1" >> test.log
            search_string="${search_string%?}"
        else
            echo "testestetsetst2" >> test.log
            search_string="$search_string$char"
        fi
        display_search_results
        reposition_cursor

        echo "sadad"$char"sda" >> test.log
        echo $search_string >> test.log
    done
}

# ---------- Search Logic ----------

fuzzy_search() {
    local search_string="$1"
    local history_file="$2"
    local matches=$(grep -i "$search_string" "$history_file" | awk '{print $0}')
    echo "$matches" | head -5
}

display_search_results() {  ## active 
    tput cup $((${pos1[0]}-2)) $PROMPT_COLUMN
    echo -e "\n$(fuzzy_search "$search_string" ~/.bash_history)\n"
}

reposition_cursor() {   ## active 
    tput cup $((${pos1[0]} - 2)) $(($PROMPT_COLUMN + $OFFSET + ${#search_string} ))
    echo     $((${pos1[0]} - 2)) $(($PROMPT_COLUMN + $OFFSET + ${#search_string} )) >> test.log
}

# ---------- Main Program ----------

history -a ~/.bash_history
search_string=""
extract_current_cursor_position pos1
adjust_cursor_position
capture_user_input
