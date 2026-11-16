# dynamic-environment

Compose multi-repo development environments on demand. Each **slot** gets its
own directory tree of **git worktrees** — multiple slots can be active
simultaneously, even sharing repos on different branches, without interfering
with each other. Activating a slot opens a tmuxinator session with a window
per repo, and can start everything in it straight away: apps running, local
hostnames and a Chrome tab group.

Repos are discovered from existing clones under `~/repositories` (or the
`repo_root` setting); a fresh clone is only made when none is found.

It's built around one person's setup (macOS, Homebrew, tmux, Chrome, Claude
Code), but the editor, browser, Claude and clone root are [settings](#settings),
and everything except tmux and fzf is optional. Run `./env.sh doctor` to see
what you have and what each missing piece turns off.

## Prerequisites

- **bash 4+** — macOS ships with 3.2; install via `brew install bash`
  (`env.sh` re-execs itself under the Homebrew bash automatically)
- **fzf** — for interactive selection; `brew install fzf`
- **tmux** and **tmuxinator** — for session management; `brew install tmux`,
  `gem install tmuxinator`
- Optional: **Caddy** for [local hostnames](#local-hostnames), **Chrome** with
  the [extension](#chrome-tab-groups) for tab groups, **Claude Code**, **nvim**
  (or set `editor`)
- **Bitbucket API token** — only needed for `adhoc` repo discovery; stored at
  `~/.config/dev-env/config.yml`. Repos are discovered and cloned from one
  Bitbucket workspace; GitHub isn't supported.

## Usage

```bash
./env.sh activate <preset> [--as <slot>] [--feature <name>] [--checkout] [--start|--no-start]
                                           # activate a preset (slot = preset name by default)
./env.sh adhoc [--as <slot>] [--feature <name>] [--start|--no-start]
                                           # Bitbucket + fzf selection, then activate
./env.sh start [<slot>]                    # run the apps of a slot opened with --no-start
./env.sh slots                             # list active slots
./env.sh status [<slot>]                   # show details of one or all slots
./env.sh deactivate [<slot>]               # tear down a slot's symlinks and worktrees
./env.sh save <name> [--slot <slot>]       # save a slot's selection as a preset
./env.sh list                              # list available presets
./env.sh hosts [<slot>]                    # <repo>.<slot>.localhost names for running apps
./env.sh shared [add|remove|update|start]  # tools kept running outside any slot
./env.sh open [<slot>] [--all]             # open the slot's apps as a Chrome tab group
./env.sh kits [apply] [<slot>]             # repo kit status; apply new kits to a slot
./env.sh ref [add|remove|update] [<slot>] [<repo>...]
                                           # reference repos: read, not changed or run
./env.sh doctor                            # check what's installed and set up
```

## Settings

Optional, in `~/.config/dev-env/config.yml` alongside the Bitbucket credentials.
Each has an environment variable that overrides it.

| Setting | Variable | Default | What it does |
|---|---|---|---|
| `repo_root` | `DEV_ENV_REPO_ROOT` | `~/repositories` | Where clones are searched for (4 levels deep) and new ones made |
| `editor` | `DEV_ENV_EDITOR` | `nvim` if installed, else `$EDITOR` | Command for each repo window's left pane, run with `.`; `none` for a plain shell |
| `claude` | `DEV_ENV_CLAUDE` | `auto` (on if `claude` is installed) | `on`/`off`: Claude Code in each slot's `environment` window |
| `base_branches` | `DEV_ENV_BASE_BRANCHES` | `main master` | Branches a new feature branch can start from: globs, case-insensitive, most recently committed wins (e.g. `master candidate */DevReady`) |
| `skip_repos` | `DEV_ENV_SKIP_REPOS` | `*-development-environment` | Folder-name globs that clone discovery ignores |
| `browser` | `DEV_ENV_BROWSER` | `auto` (`chrome` if installed, else `default`) | How `open` and the `hosts` window show a slot's apps: `chrome` (tab group), `default` (a tab each in the default browser), `none` |

```yaml
workspace: your-workspace
email: you@example.com
api_token: ...
editor: code
browser: default
base_branches: main develop release/*
```

Repo kits (below) and tmux overrides are personal too: they live in
`~/.config/dev-env/`, not this repo, and start empty.

Running `adhoc` twice creates two independent slots:

```bash
./env.sh adhoc --as push-notifications
./env.sh adhoc --as tech-tracker         # can share repos with the first slot
```

## How it works

1. **Discovery** — `find ~/repositories -maxdepth 4 -name .git` locates every
   clone (skipping this repo and the `*-development-environment` scaffolding
   repos). Repos are matched by the slug of their `origin` remote URL.
2. **Resolution** — found once: use it. Found in several places: you're
   prompted to choose (showing path, branch, clean/dirty). Not found: cloned
   fresh to `~/repositories/<slug>`.
3. **Worktree creation** — for each repo, `git worktree add` creates an
   isolated working directory at `~/.local/share/dev-env/worktrees/<slot>/<slug>`.
   Every worktree in the slot goes on `feature/<name>/feature` (see
   [Feature branches](#feature-branches)). You're only prompted for a branch
   name if that fails (e.g. the branch is already checked out by another
   worktree), and any repo that isn't linked is listed at the end of activation.
4. **Activation** — symlinks land in `slots/<slot>/<category>/`, `ACTIVE.md` is
   regenerated, and `.active-env-<slot>` records what was created.
5. **tmuxinator** — a config is written to
   `~/.config/tmux/tmuxinator/<slot>.yml`, and the session always opens.
   You're asked whether to start the apps too (`--start` / `--no-start` skip
   the question). With the apps started, every app runs, their hostnames stay
   current, and the slot's Chrome tab group opens once its clients are up.
   Without them, the windows open with their editors and Claude, and the run,
   test and `hosts` panes wait at a prompt until `./env.sh start <slot>` runs
   them.
   Setup also shows the [shared tools](#shared-tools). It offers to add more,
   and to start them if their session isn't running. Each repo gets a window: nvim on the left, build/dev server
   and test watcher on the right (layout depends on repo type; see below).
   A final `environment` window opens Claude Code and a free shell at the slot root.
6. **Deactivation** — symlinks are removed, each worktree is cleaned up with
   `git worktree remove`, empty directories are `rmdir`'d, the tmuxinator config
   is deleted, and `ACTIVE.md` is updated.

## Reference repos

Some repos are only needed to read: how another service calls an API, what a
shared library does, an older implementation to follow. Put them in the
`reference` category (offered by `adhoc`, or `reference,<repo>` in a preset), or
add them to an active slot:

```bash
./env.sh ref add <slot> api-server auth-server  # no prompts
./env.sh ref add <slot>                         # pick with fzf
./env.sh ref update <slot>       # move them to the latest base branch
./env.sh ref remove <slot> <repo>
./env.sh ref <slot>              # list them
```

A reference repo gets a worktree at `slots/<slot>/reference/<repo>`, detached
at the latest base branch (see `find_base_ref`). So it's never on the feature
branch, and it doesn't hold a branch another worktree needs. It has no tmux
window, repo kit, hostname, tab or setup check. The slot's `CLAUDE.md` tells
its Claude not to edit them, and how to add more when the work needs them.

## Tmux window layout

Repo type is detected automatically from the worktree contents:

| Type | Detection | Top-right pane | Bottom-right pane |
|---|---|---|---|
| Java | `gradlew` / `build.gradle` | `./gradlew build` | `./gradlew test --continuous` |
| Expo / React Native | `package.json` with `expo` dep | `npm install && npx expo start` | `npx jest --watchAll` |
| React web | `package.json` with `react-scripts` or `vite` | `npm install && npm start` | `npm test` |
| npm lib | `package.json` (other) | `npm install` | `npm test -- --watch` |
| Unknown | — | *(empty)* | *(empty)* |

The `environment` window always opens at `slots/<slot>/` with `claude` on the
left and an empty shell on the right. React web repos run `npm start` when
`package.json` has a `start` script, otherwise `npm run dev`.

### Per-slot overrides

To change what a slot's windows run (and keep it when the config is
regenerated), create `~/.config/dev-env/tmux-overrides/<slot>.tsv` with
tab-separated lines:

```
# replace a repo window's top (2) or bottom (3) pane; '-' leaves it empty
pane	api-server	2	./run_server.sh
pane	api-server	3	-
# add a window before 'environment' (dir may start with ~)
window	admin-console	~/path/to/admin-console	PORT=3001 npm start
```

## Repo kits

Kits are personal and start empty. To give the Claude that builds them notes on
your local setup (auth server URL and realm, databases, ...), write them in
`~/.config/dev-env/setup-notes.md`; they're included in its instructions.

A fresh worktree is missing everything git ignores, such as `config.yml` or a
UI's `public/keycloak.json`. It also only gets the repo type's default commands,
so a Java server builds rather than runs. A repo kit fixes both, for every slot
and the shared tools. Keep it in `~/.config/dev-env/repos/<repo>/`:

```
panes.tsv      2<TAB>command    the window's run pane (top right)
               3<TAB>command    its test pane (bottom right); '-' = empty
files/...      local files, put at the same path in every new worktree
```

- Plain files are symlinked, so one copy serves every slot.
- Files ending `.tmpl` are rendered instead, with these filled in:
  - `{{slot}}`;
  - `{{worktree}}`;
  - `{{url:<repo>|<default>}}`: `<repo>`'s hostname in the slot, else in the
    shared tools, else `<default>`. For example,
    `"baseRequestURL": "{{url:api-server|http://localhost:8080}}/service"`.

Kits are applied when a slot is activated or a shared tool is added. Files a
worktree already has are left alone. A slot's own `pane` overrides still win
over its kits.

**Repos that aren't set up yet.** A repo with no kit is flagged when it looks
like it can't run from a fresh worktree:
- it has committed config templates (`template_config.yml`,
  `public/config-template.json`, `example-config.json`, `*.sample`, ...) whose
  local copy is missing or unfilled (placeholder markers such as `GOES-HERE`,
  or a JSON file with mostly blank values); or
- it's a Java server with no run command, so it would only build.

What happens then:
- Slot setup lists those repos, in the slot and in the shared tools.
  `shared add` lists any it adds.
- The slot's `CLAUDE.md` gets a "Repos that need setting up" section explaining
  how to build their kits.
- Claude in the `environment` window starts by offering to help, asking you
  only for what it can't work out, such as client ids or secrets.
- `./env.sh kits [<slot>]` shows each repo's status, and `./env.sh kits apply
  [<slot>]` puts new kits into an existing slot.
- A repo that needs nothing gets an empty kit directory, which stops it being
  flagged.
- Some repos commit their config as a blank placeholder. A kit file replaces
  that placeholder in the worktree, and the file is marked `skip-worktree` so
  the local values never show up as a change to commit.

## Shared tools

Some apps should be available whatever you're working on, e.g. an internal
admin console. Keep them in the shared set rather than in a slot:

```bash
./env.sh shared add [--refresh]   # pick repos per category with fzf, as in adhoc
./env.sh shared remove            # pick shared repos to remove
./env.sh shared update            # move clean shared worktrees to the latest base
./env.sh shared start             # start the 'shared' tmux session if it's stopped
./env.sh shared                   # status
./env.sh hosts shared             # http://<repo>.localhost for the running ones
```

- **Worktrees:** shared worktrees live in `~/.local/share/dev-env/worktrees/shared/`.
  They're detached at the latest base branch (see `base_branches`; as for new
  feature branches) rather than on a feature branch, so they never hold a branch
  a slot needs.
- **tmux:** they run in their own `shared` session, laid out like a slot's
  windows, with pane overrides in `tmux-overrides/shared.tsv`. There's no Claude
  window.
- **Hostnames:** short ones, `<repo>.localhost`. A slot can include the same repo
  on its feature branch at the same time, and it gets `<repo>.<slot>.localhost`.
  If both run, the second dev server takes the next free port, and `hosts`
  follows it.
- **Naming:** `shared` is reserved as a slot name. It isn't listed by `slots` or
  written to ACTIVE.md.

## Local hostnames

Each of a slot's running apps gets a name, `http://<repo>.<slot>.localhost`
(e.g. `http://web-ui.my-feature.localhost`). Every slot's tmux
session (and the shared one) has a `hosts` window running
`./env.sh hosts <slot> --watch --open`. It does three things:
- adds names as apps come up;
- follows them if their port changes and drops them when they stop;
- once the slot's clients are up (or after three minutes, if some are), opens
  the slot's [tab group](#chrome-tab-groups).

`./env.sh hosts [<slot>]` does a one-off refresh.

- Browsers resolve every `*.localhost` name to loopback, so there is nothing to
  add to `/etc/hosts`.
- Caddy proxies each name to the port the app is listening on. The port is found
  by matching listening processes' working directories to the slot's worktrees
  (and override windows), and taking the lowest one that answers HTTP. Debugger,
  admin and build-daemon ports are skipped that way, and slots don't fight over
  fixed ports.
- `status` lists the slot's names, and `deactivate` removes them.
- Pin a port, or leave an app out, with a `host` line in the slot's tmux
  overrides file:

  ```
  host	api-server	8080
  host	web-ui	-
  ```

- A `host` line whose name isn't one of the slot's repos names something
  else, such as a Docker container. For example, in `tmux-overrides/shared.tsv`,
  `host	keycloak	8080` gives `http://keycloak.localhost` (admin console
  at `/auth/admin/`).
- Keycloak builds its token issuer from the hostname each request used. Use
  `keycloak.localhost` for browsing, but keep apps' and servers' Keycloak
  config on `localhost:<port>`, so their tokens' issuer matches what the servers
  validate against.

One-off setup:

```bash
brew install caddy
cat > "$(brew --prefix)/etc/Caddyfile" << EOF
{
	auto_https off
	admin localhost:2019
}

import $HOME/.config/dev-env/caddy/*.caddy
EOF
brew services start caddy
```

Pointing a UI at the names may mean updating its runtime config (e.g. a
`baseRequestURL`) and allowing the new origin as a Keycloak redirect URI. Keycloak
itself is left on `localhost:<port>` so token issuers don't change.

## Chrome tab groups

`./env.sh open [<slot>] [--all]` opens a slot's named apps (see
[Local hostnames](#local-hostnames)) in Chrome as a tab group titled after the
slot. It opens the clients and extra windows, and `--all` adds servers too.
`./env.sh open shared` does the same for the shared tools. Running it again
reuses the group and only opens apps that aren't in it yet.

Chrome only lets extensions create tab groups, so this needs the small
extension in `chrome-extension/`. Load it once: in `chrome://extensions`, turn
on Developer mode, choose **Load unpacked** and pick the `chrome-extension`
folder. `hosts` writes each slot's app list to
`~/.config/dev-env/caddy/www/slots/<slot>.json`, and Caddy serves it at
`http://dev-env.localhost`. `open` opens `http://dev-env.localhost/open?slot=<slot>`,
and the extension turns that tab into the group.

## Preset format — `presets/<name>.env`

```
# category,slug[,branch]
@feature my-feature
clients,web-ui
servers,api-server
libraries,shared-models

@context
Freeform notes injected verbatim into ACTIVE.md — describe what this
environment is for, focus areas, gotchas.
@end
```

Categories are derived from the first field — any folder name works. The branch
field records which branch the worktree was on when `save` was run; it is only
used with `activate --checkout`, which puts that repo on the recorded branch
instead of the feature branch. `@feature` sets the feature name (written by
`save`).

## Feature branches

All worktrees in a slot share one branch name: `feature/<name>/feature`.

- **Name** — from `--feature <name>`, then the preset's `@feature` line, then a
  prompt that defaults to the slot name. Stored as `feature=` in the slot state
  and shown by `./env.sh status`.
- **Existing branch** — if `feature/<name>/feature` already exists locally it is
  reused; if it only exists on `origin` it is checked out tracking origin.
- **New branch** — created from whichever `origin` branch matching
  `base_branches` (default `main master`) was committed to most recently. Local
  branches with those names are used if origin has none, and the clone's
  current branch as a last resort. New branches don't track their base, so a
  `git push` can never land on it.

The easiest way to create a preset: `./env.sh adhoc`, then `./env.sh save <name>`.

`ACTIVE.md` always has a **Context** section. Context can come from a preset's
`@context` block, the prompt at the end of `adhoc`, or the prompt in `save`
when none exists yet.

## Repo-list cache

`adhoc` caches the Bitbucket repo list at `~/.cache/dev-env/repos.txt` for
24 hours. Use `--refresh` to force a re-fetch.

## Files

| Path | Committed? | Purpose |
|---|---|---|
| `env.sh` | yes | entry point with all subcommands |
| `lib/common.sh` | yes | shared helpers (discovery, worktrees, tmux, state) |
| `scripts/fetch-repos.sh` | yes | Bitbucket workspace repo listing |
| `scripts/select-repos.sh` | yes | fzf multi-select per category |
| `presets/*.env` | yes | saved environment definitions |
| `CLAUDE.md` | yes | static; includes `@ACTIVE.md` |
| `ACTIVE.md` | no | regenerated on every slot change |
| `.active-env-<slot>` | no | state: active preset + created symlinks/worktrees |
| `slots/<slot>/` | no | symlinks into worktrees for that slot |
