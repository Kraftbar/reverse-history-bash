# reverse-history-bash

```bash
bind -r '\C-r'; unset -f __rhb_bind 2>/dev/null; source /home/nybo/reverse-history-bash/rhb-bash-setup.sh; bind -X | grep -E '__rhb_|reverse-history'
```
