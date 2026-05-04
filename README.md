# reverse-history-bash


 
For testing it add this to .bashrc:
```bash
source /home/nybo/reverse-history-bash/rhb-bash-setup.sh
```


An attemt to impement [history-search-multi-word](https://github.com/zdharma/history-search-multi-word) in pure bash

Oneshot run (no install):

```bash
bash /home/nybo/reverse-history-bash/reverse-history-bash.sh
```

Temporary one-session test bind/unbind:
```bash
source /home/nybo/reverse-history-bash/rhb-bash-setup.sh
# ...
bind -r '\\C-r'; unset -f __rhb_bind
```

Notes:
- Up/Down arrows navigate, Enter accepts the selected command, Backspace edits the query, Esc or Ctrl-C exits.
- Ctrl-A rotates query words, Ctrl-W deletes the previous query word, and Ctrl-U clears the query.
- Matching is multi-word: space-separated terms must all appear in the command (order-insensitive, case-insensitive).
- `^word` matches the beginning of a command, `word$` matches the end, and bracket expressions like `[0-9]` are treated as patterns.
- The current command line is used as the initial query.
- Matched words are highlighted and the active row is visually marked.
- The picker is rendered with cursor save/restore so it does not wipe your current line.
