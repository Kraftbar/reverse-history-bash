
extract_current_cursor_position () {
    export $1
    exec < /dev/tty
    oldstty=$(stty -g)
    stty raw -echo min 0
    echo -en "\033[6n" > /dev/tty
    IFS=';' read -r -d R -a pos
    stty $oldstty
    eval "$1[0]=$((${pos[0]:2} - 2))"
    eval "$1[1]=$((${pos[1]} - 1))"
}
colstot=$(tput lines)
totrows=$(tput cols)


# Save the current history to a file
history -a ~/.bash_history

# Search for a fuzzy match of a given string in the history file
# todo: if the string is over totrows or over several lines then cut the string and add ... at the end 
fuzzy_search() {
  local search_string="$1"
  local history_file="$2"
  local matches

  matches=$(grep -i "$search_string" "$history_file" | awk '{print $0}')

  echo "$matches" | tail -5
}


# Use the fuzzy_search function to search the history file for a string
# entered by the user, updating the match at every character written
search_string=""
extract_current_cursor_position pos1
pos1[0]=$((pos1[0]+1))
tput cup ${pos1[0]} 27
diff=$((colstot - pos1[0]))

# todo: sub make $((27 + 21)) not hardcoded
echo  "Enter search string: "
echo  -e "\n\n\n "
echo $diff >> test.log
if [ $diff -lt 5 ]; then
  tput cup $((pos1[0] + diff-6)) $((27 + 21))
  pos1[0]=$((pos1[0] + diff-6))
  pos1[1]=$((27 + 21))
else
  tput cup ${pos1[0]-1} $((27 + 21))
  pos1[0]=$((pos1[0] +1))
  pos1[1]=$((27 + 21))
fi



while read -r -n 1 char; do

  if [ "$char" = $'\x7f' ]; then
    # Handle backspace by removing the last character from the search string
    search_string="${search_string%?}"
    pos1[0]=$((pos1[0]-2))
  else
    # Append the entered character to the search string
    search_string="$search_string$char"
  fi

  echo $search_string
  fuzzy_search "$search_string" ~/.bash_history
  tput cup $((${pos1[0]}-1)) $((27 + 21 +${#search_string}-1))

done

