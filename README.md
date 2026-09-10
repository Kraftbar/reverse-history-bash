# reverse-history-bash

Ctrl+R history picker for Bash.

Install:

```bash
git clone https://github.com/Kraftbar/reverse-history-bash ~/.reverse-history-bash && { grep -qxF 'source ~/.reverse-history-bash/rhb-bash-setup.sh' ~/.bashrc || printf '\nsource ~/.reverse-history-bash/rhb-bash-setup.sh\n' >> ~/.bashrc; } && source ~/.reverse-history-bash/rhb-bash-setup.sh
```

Update/reload:

```bash
git -C ~/.reverse-history-bash pull --ff-only && source ~/.reverse-history-bash/rhb-bash-setup.sh
```

Test:

```bash
bash -n reverse-history-bash.sh rhb-bash-setup.sh && python3 -m unittest -v test_terminal
```
