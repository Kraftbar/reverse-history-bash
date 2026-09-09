# reverse-history-bash

Ctrl+R searches your Bash history with an inline result list. Near the bottom
of the terminal, the picker scrolls enough to show its results. Short terminals
show fewer rows while keeping the selected result visible.

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

Terminal regression checks (Linux, Bash and Python 3; no extra Python packages):

```bash
bash -n reverse-history-bash.sh rhb-bash-setup.sh
python3 -m unittest discover -s tests -v
```

The checks run the picker in isolated pseudo-terminals with temporary history
files. They do not read or modify your shell history.
