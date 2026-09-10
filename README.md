# reverse-history-bash

Ctrl+R searches your Bash history with an inline result list. Near the bottom
of the terminal, the picker scrolls enough to show its results. Short terminals
show fewer rows while keeping the selected result visible.

Install (new checkout):

```bash
git clone https://github.com/Kraftbar/reverse-history-bash "$HOME/.reverse-history-bash"
```

After cloning successfully, enable it for new shells and the current shell:

```bash
if [[ -f "$HOME/.reverse-history-bash/rhb-bash-setup.sh" ]]; then
  grep -qxF 'source ~/.reverse-history-bash/rhb-bash-setup.sh' "$HOME/.bashrc" ||
    printf '\nsource ~/.reverse-history-bash/rhb-bash-setup.sh\n' >> "$HOME/.bashrc"
  source "$HOME/.reverse-history-bash/rhb-bash-setup.sh"
fi
```

Update an existing install:

```bash
git -C "$HOME/.reverse-history-bash" pull --ff-only &&
  source "$HOME/.reverse-history-bash/rhb-bash-setup.sh"
```

Reload/debug:

```bash
source "$HOME/.reverse-history-bash/rhb-bash-setup.sh"
bind -X | grep -E '__rhb_|reverse-history'
```

Terminal regression checks (Linux, Bash and Python 3; no extra Python packages):

```bash
bash -n reverse-history-bash.sh rhb-bash-setup.sh
python3 -m unittest -v test_terminal
```

The checks run the picker in isolated pseudo-terminals with temporary history
files. They do not read or modify your shell history.
