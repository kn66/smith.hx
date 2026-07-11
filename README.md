# smith.hx

A declarative Helix plugin manager backed by Steel's
[Forge](https://github.com/mattwparas/steel/tree/master/crates/forge).
Plugins listed in `init.scm` are installed with Forge and loaded at startup.
Manager-owned packages removed from `init.scm` are uninstalled as a group.

## Requirements

- Helix built with Steel support
- Steel's `forge` executable on `PATH`

A full Steel installation includes Forge:

```sh
git clone https://github.com/mattwparas/steel.git
cd steel
cargo xtask install
```

## Installation

Install this manager directly with Forge:

```sh
forge pkg install --git https://github.com/kn66/smith.hx.git
```

No copy, symlink, or installer script is required. Forge installs the module as
`smith.hx/smith.scm` under Steel's `cogs` directory.

## Declare plugins in init.scm

Add the manager import, plugin declarations, synchronization, plugin settings,
and keybindings to the Helix Steel `init.scm`. This example installs
[`forest.hx`](https://github.com/Ra77a3l3-jar/forest.hx), uses its persistent
`snacks` sidebar, hides common generated directories, and binds the explorer to
`Space e`:

```scheme
(require (only-in "smith.hx/smith.scm"
                  smith-plugin
                  smith-prune
                  smith-init))

(smith-plugin "https://github.com/Ra77a3l3-jar/forest.hx.git"
  ;; Use 'right instead of 'left to move the sidebar.
  (forest-configure! 'left #:ignore (list ".git" "target" "__pycache__"))

  ;; Select 'snacks (persistent sidebar) or 'mini (floating).
  (forest-set-style! 'snacks)

  ;; Open or focus forest.hx with Space e in normal mode.
  (keymap (global)
          (normal (space (e ":forest-open")))))

;; Synchronize after every smith-plugin declaration has been evaluated.
(smith-init)
```

Each declaration is passed to `forge pkg install --git <git-url>`. Any git URL
accepted by Forge can be used, including GitLab, Codeberg, self-hosted HTTPS or
SSH repositories, and local `file://` URLs. GitHub repositories additionally
support the short `owner/repository` form.

Smith reads the root installation path reported by Forge, obtains the package
name from that directory, and detects conventional entry files such as
`helix.scm` or `<package-name>.scm`. This is why the example needs only the
repository URL even though `forest.hx` declares the package name `forest` and
uses `forest.scm` as its entry.

For an unconventional package, the explicit form remains available as
`(smith-plugin (source package-name entry-file [revision]) ...)`.

Configuration forms inside `smith-plugin` are quoted by the macro and evaluated
only after the package has been installed and loaded. This keeps installation,
custom variables, and keybindings in one declaration without manual
`eval-string` calls.

When one or more declarations were evaluated, `smith-init` removes
manager-owned packages absent from the declarations. Forge packages installed
independently of this manager are not touched.

Disable pruning temporarily with `(smith-init #false)`. Force pruning
when there are no declarations with `(smith-init #true)`.

## Optional Helix commands

To use commands such as `:smith-list` and `:smith-prune`, expose the manager
functions from the Helix Steel `helix.scm`:

```scheme
(require (only-in "smith.hx/smith.scm"
                  smith-install
                  smith-init
                  smith-self-update
                  smith-ensure
                  smith-plugin
                  smith-configure!
                  smith-lock
                  smith-restore
                  smith-prune
                  smith-update
                  smith-remove
                  smith-enable
                  smith-disable
                  smith-load
                  smith-load-all
                  smith-list))

(provide smith-install
         smith-init
         smith-self-update
         smith-ensure
         smith-plugin
         smith-configure!
         smith-lock
         smith-restore
         smith-prune
         smith-update
         smith-remove
         smith-enable
         smith-disable
         smith-load
         smith-load-all
         smith-list)
```

Available commands include:

```text
:smith-list
:smith-install owner/repo
:smith-update
:smith-update package-name
:smith-remove package-name
:smith-prune
:smith-disable package-name
:smith-enable package-name
:smith-self-update
:smith-lock
:smith-restore
```

`smith-update` reinstalls managed plugins with Forge's `--force` option.
`smith-self-update` similarly reinstalls this manager through Forge; reload
the Steel configuration afterward.

## Lock file

Create a lock file from the exact commits currently installed by Forge:

```text
:smith-lock
```

Smith writes `<helix-config>/steel/plugins/smith-lock.scm`. Commit this file
with your Helix configuration to reproduce the same plugin versions elsewhere.
Each entry records the package name, source URL, entry file, enabled state, and
the installed git commit SHA.

Restore every managed plugin at the locked commits with:

```text
:smith-restore
```

Restoration runs `forge pkg install --git <source> --rev <sha> --force`, checks
out and verifies the exact locked SHA in the installed package, replaces the
Smith registry only after all packages restore successfully, and reloads enabled
plugins. Both commands optionally accept another lock-file path when called
from Scheme.

## Storage

The manager stores its ownership and load metadata at:

```text
<helix-config>/steel/plugins/registry.scm
```

Forge owns the installed package files:

```text
<STEEL_HOME>/cogs/<package-name>/
```

This registry boundary prevents pruning from uninstalling unrelated Forge
packages.
