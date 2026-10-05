# Omarci

GitHub Actions in the [Omarchy](https://omarchy.org/) bar.

Tell it which repos to watch and the bar shows a test-tube pill: a spinner while a run is in progress, red when your latest run failed, green when it passed. Click it for each repo's latest runs, the selected run's jobs, steps and log, and Open, Retry and Cancel. You get a desktop notification when a run you started finishes.

![Omarci panel](preview.png)

## Install

Needs the [GitHub CLI](https://cli.github.com/) signed in (`gh auth login`); omarci uses its login and nothing else.

```bash
omarchy plugin add https://github.com/matiacone/omarci.git --enable
ln -sf ~/.config/omarchy/plugins/io.github.matiacone.omarci/bin/omarci ~/.local/bin/omarci
```

The widget lands on the right. Move it if you want:

```bash
omarchy bar move io.github.matiacone.omarci --section right --before omarchy.agents
```

## Use

Add repos from the panel (the gear → **Watched repos**, paste `owner/repo` or a github.com URL), or from a terminal:

```bash
omarci repos add owner/repo
omarci repos remove owner/repo
omarci repos              # list
```

Down the left, a card per watched repo with its latest 10 runs: status, workflow, branch, commit title, how long ago. On the right, the selected run's jobs and steps and the end of its log: the failed jobs' log when something failed, the whole run's otherwise. GitHub has no log for a run still in progress; its steps refresh every few seconds instead. The widget syncs every 15 s while a run is in progress and every minute otherwise.

Top right, three actions for the selected run:

| Button | Key | Does |
| --- | --- | --- |
| **Open** | `Enter` | The run on github.com |
| **Retry** | `r` | Re-runs a failed run's failed jobs, or the whole run otherwise |
| **Cancel** | `c` | Cancels a run in progress |

`j` / `k` select, `s` opens settings (the gear), `Esc` closes. A finished run's details are cached, and the newest are fetched ahead in the background, so selecting a run is instant.

The same actions work from a terminal:

```bash
omarci gh sync                              # refresh now
omarci gh open owner/repo RUN_ID
omarci gh rerun owner/repo RUN_ID [--failed]
omarci gh cancel owner/repo RUN_ID
omarci gh log owner/repo RUN_ID [--all]     # failed jobs' log, or all of it
omarci gh view owner/repo RUN_ID            # jobs, steps and log tail as JSON (cached once finished)
```

Turn notifications off with the toggle in settings, or `OMARCI_NOTIFY=0`. `OMARCI_DIR` overrides the state directory (`$XDG_STATE_HOME/omarci`).

## Update

```bash
omarchy plugin update io.github.matiacone.omarci
```

## Uninstall

```bash
omarchy plugin remove io.github.matiacone.omarci
rm -f ~/.local/bin/omarci
```

Settings and cached runs in `~/.local/state/omarci/` are left in place.

## Security

Omarci runs unsandboxed inside `omarchy-shell` when enabled. Review the source before installing.

- **Files:** reads and writes `$XDG_STATE_HOME/omarci/`: settings with the watched repos, `github.json` with their latest runs, and `runs/` with finished runs' details (dropped after a week). Toggling notifications may update this plugin's entry in `~/.config/omarchy/shell.json`.
- **Commands:** `gh` for everything GitHub (it uses your `gh` login; omarci never sees a token); `xdg-open` to open a run; `notify-send` when a run you started finishes.
- **Network:** only through `gh`, to the GitHub API, for the repos you watch: reading runs and their logs, and re-running or cancelling the ones you choose.
- **Privilege:** no sudo, no install hooks.

## License

MIT
