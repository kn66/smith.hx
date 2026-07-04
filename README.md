# Helix Steel Plugin Manager

A small plugin manager for Helix's Steel/Scheme configuration. It clones git repositories and loads their Scheme entry files as Helix plugins.

## Requirements

- Helix built with Steel support
- `git` available on `PATH`
- A Steel setup that uses `helix.scm` and `init.scm`

## Installation

The most reliable path is the bundled POSIX `sh` installer. With `--configure`, it installs `plugin-manager.scm` and appends the required blocks to `helix.scm` and `init.scm`. Existing installer-managed blocks are not duplicated.

```sh
cd "$HOME/src/helix/helix-steel-plugin-manager"
sh install.sh --configure
```

If `helix/plugin-manager.scm` already exists, the installer stops. Use `--force` to back up the existing file and replace it.

```sh
sh install.sh --configure --force
```

Use copy mode on systems where symlinks are unavailable or inconvenient.

```sh
sh install.sh --configure --copy
```

To install into a specific Helix Steel config directory:

```sh
sh install.sh --configure --config-dir "$HOME/.config/helix"
```

For a manual install, symlink this project into a path Helix can find. With the default config directory:

```sh
mkdir -p "${XDG_CONFIG_HOME:-$HOME/.config}/helix/helix"
ln -sf "$HOME/src/helix/helix-steel-plugin-manager/plugin-manager.scm" \
  "${XDG_CONFIG_HOME:-$HOME/.config}/helix/helix/plugin-manager.scm"
```

If you use `HELIX_STEEL_CONFIG`, symlink into that directory instead.

```sh
mkdir -p "$HELIX_STEEL_CONFIG/helix"
ln -sf "$HOME/src/helix/helix-steel-plugin-manager/plugin-manager.scm" \
  "$HELIX_STEEL_CONFIG/helix/plugin-manager.scm"
```

Expose the commands from `helix.scm`.

```scheme
(require (only-in "helix/plugin-manager.scm"
                  plugin-install
                  plugin-update
                  plugin-remove
                  plugin-enable
                  plugin-disable
                  plugin-load
                  plugin-load-all
                  plugin-list))

(provide plugin-install
         plugin-update
         plugin-remove
         plugin-enable
         plugin-disable
         plugin-load
         plugin-load-all
         plugin-list)
```

Load enabled plugins from `init.scm`.

```scheme
(require (only-in "helix/plugin-manager.scm" plugin-load-all))
(plugin-load-all)
```

Restart Helix or reload the Steel configuration after installation.

## How Helix Loads the Manager

Helix Steel reads configuration from the Helix config directory. By default, this directory is `${XDG_CONFIG_HOME:-$HOME/.config}/helix`, so the files are usually:

```text
~/.config/helix/helix.scm
~/.config/helix/init.scm
~/.config/helix/helix/plugin-manager.scm
```

`helix.scm` exposes Scheme functions as Helix commands. The installer adds the plugin manager functions there so commands such as `:plugin-install` and `:plugin-list` are available from Helix's command line.

`init.scm` runs when the Steel configuration is initialized. The installer adds this block so previously installed and enabled plugins are loaded automatically:

```scheme
(require (only-in "helix/plugin-manager.scm" plugin-load-all))
(plugin-load-all)
```

If `HELIX_STEEL_CONFIG` is set, Helix Steel uses that directory instead of the default config directory. In that case, write `helix.scm`, `init.scm`, and the `helix/plugin-manager.scm` module under `$HELIX_STEEL_CONFIG`.

After installation, type the full command names in Helix. There is no `:plugin` command by itself; the provided commands are named with the `plugin-` prefix, for example `:plugin-list` and `:plugin-install`.

## Usage

You can install from a GitHub `owner/repo` shorthand or from a regular git URL.

```scheme
(plugin-install "owner/repo")
(plugin-install "https://github.com/owner/repo.git")
```

Pass an explicit name, entry file, or branch when needed.

```scheme
(plugin-install "https://github.com/owner/repo.git" "repo-name" "plugin/main.scm")
(plugin-install "owner/repo" "repo-name" "helix.scm" "main")
```

After exposing the functions from `helix.scm`, you can use them from Helix's command line.

```text
:plugin-install owner/repo
:plugin-list
:plugin-update
:plugin-load repo
:plugin-disable repo
:plugin-enable repo
:plugin-remove repo
```

## Plugin Format

The manager loads the selected entry file from the cloned repository as a Scheme module with `require`. The entry file should `provide` the commands or values it wants to expose, like any other Helix Steel plugin.

```scheme
(provide hello-plugin)

(define (hello-plugin)
  "hello from plugin")
```

If no entry file is given, the manager uses the first existing file in this order:

- `helix.scm`
- `init.scm`
- `plugin.scm`
- `cog.scm`
- `<plugin-name>.scm`

## Storage

Installed plugins and the registry are stored under the parent directory of `get-init-scm-path`.

```text
<steel-config-dir>/steel/plugins/
<steel-config-dir>/steel/plugins/registry.scm
```

With the default Helix config layout, this is usually:

```text
~/.config/helix/steel/plugins/
~/.config/helix/steel/plugins/registry.scm
```

## Project Maintenance

This repository is intended to be managed separately from the Helix source tree.

```sh
cd "$HOME/src/helix/helix-steel-plugin-manager"
git init
git add README.md plugin-manager.scm install.sh
git commit -m "Initial plugin manager"
```

When `plugin-manager.scm` changes, an existing symlink-based install picks up the update after Helix is restarted or the Steel configuration is reloaded. Copy-based installs need to rerun `sh install.sh --copy`.

## Notes

- `plugin-disable` only excludes the plugin from future `plugin-load-all` calls. It does not unload definitions already evaluated in the current Steel engine.
- `plugin-update` runs `git pull --ff-only`. Plugins with local changes may fail to update.
- `plugin-remove` deletes the cloned directory by default.
