# reverse-history-bash

Install:

```bash
git clone https://github.com/Kraftbar/reverse-history-bash ~/.reverse-history-bash && grep -qxF 'source ~/.reverse-history-bash/rhb-bash-setup.sh' ~/.bashrc || printf '\nsource ~/.reverse-history-bash/rhb-bash-setup.sh\n' >> ~/.bashrc
```

Update an existing install:

```bash
git -C ~/.reverse-history-bash pull --ff-only && source ~/.reverse-history-bash/rhb-bash-setup.sh
```

Add to startup:

```bash
grep -qxF 'source /home/nybo/reverse-history-bash/rhb-bash-setup.sh' ~/.bashrc || printf '\nsource /home/nybo/reverse-history-bash/rhb-bash-setup.sh\n' >> ~/.bashrc
```

Reload/debug:

```bash
bind -r '\C-r'; unset -f __rhb_bind 2>/dev/null; source /home/nybo/reverse-history-bash/rhb-bash-setup.sh; bind -X | grep -E '__rhb_|reverse-history'
```
