# Arch Linux · niri or Hyprland · Noctalia · Zsh

A portable desktop setup prepared from the original computer. It includes two separate installers: one for niri and one for Hyprland. Both use the same shell, Noctalia, terminal, appearance, and application files; each installs its own compositor, configuration, packages, checks, and login session. HyprMod is exclusive to Hyprland, and nirimod is exclusive to niri. The installer has not been run. The bundle targets Arch Linux x86_64, for example in a virtual machine.

## Git-ready bundle and payload archives

The Git upload copy is the compact `dotfiles-arch-git` directory. The prepared upload contains **71 files** in total, including **23 archive parts** of at most **24 MiB** each; the compressed payload totals about **551 MiB**. It contains the installers, configuration metadata, and the complete payload split into compressed parts under `payload-archives/`. The archive index is `payload-archives/manifest.json`; keep it together with **every** numbered archive part when uploading or cloning. A normal install checks each part against its SHA-256 checksum and extracts the full payload into a temporary directory before installing desktop packages. After required dependencies are installed, it validates the selected configuration before deploying dotfiles. If an expanded `payload/` directory is already present, the installer uses it instead. `--dry-run` verifies the archive parts and lists the payload without extracting it. You do not need Git LFS, a release download, or another file host.

The original expanded `payload/` remains in the local working bundle and is excluded from Git there. This avoids asking Git to track tens of thousands of template and asset files individually. The compressed parts still contain the complete payload, including all templates; splitting them reduces the file count. Parts are limited to 24 MiB so they fit GitHub's browser upload limit of 25 MiB per file. GitHub's browser uploader accepts up to 100 files per upload, so use Git when the archive index and parts exceed that count. See [GitHub's file upload limits](https://docs.github.com/en/repositories/working-with-files/managing-files/adding-a-file-to-a-repository). The combined archive may still be large.

Upload or push the **entire** compact folder, including the index and all files in `payload-archives/`. GitHub's browser uploader requires each upload batch to stay within its per-file and file-count limits; Git does not have the same 100-file batch limit. From a terminal, for example:

```bash
cd ~/dotfiles-arch-git
git init -b main
git add .
git commit -m "Add Arch desktop dotfiles"
git remote add origin <your-repository-url>
git push -u origin main
```

To rebuild the archive parts after editing configurations in the original expanded bundle, run:

```bash
cd ~/dotfiles-arch-niri
python3 lib/payload.py pack --bundle .
```

For edits made from a compact clone, first extract the payload to a working directory, edit its `payload/` tree, then repack those files into the clone's archive directory:

```bash
cd ~/dotfiles-arch-git
python3 lib/payload.py extract --bundle . --destination "$HOME/dotfiles-edit"
# Edit files under ~/dotfiles-edit/payload/
python3 lib/payload.py pack --bundle "$HOME/dotfiles-edit" --output "$PWD/payload-archives"
```

Commit the updated archive index and all archive parts together. `.gitignore` prevents new raw payload files from being added, but it does not remove raw payload files that Git already tracks; remove any previously tracked `payload/` files from the repository index when preparing the compact upload.

## Installing in a VM

Copy the entire `dotfiles-arch-git` directory; the scripts alone are not enough because the configurations and assets are in `payload-archives/`. You can place the directory anywhere. The target machine must be running Arch Linux, have a regular user with `sudo`, internet access, and access to the repositories. The installers build on a basic Arch installation and do not manage disks or the bootloader.

Choose one session to install:

```bash
cd ~/dotfiles-arch-git
bash ./install-niri.sh --vm --enable-greetd
```

or:

```bash
bash ./install-hyprland.sh --vm --enable-greetd
```

`--enable-greetd` configures a login menu for the next boot that starts the selected session. niri runs through `niri-session`; Hyprland starts as a UWSM-managed session using the official `hyprland-uwsm.desktop`. The installer does not reboot or log you out. From a TTY, start niri with `niri-session` and Hyprland with `uwsm start -e -D Hyprland hyprland.desktop`.

For a smaller VM without the full application set, add `--desktop-only`. The full profile includes additional applications, games, development tools, and virtualization tools; AUR builds can take longer and need more disk space. Enter your `sudo` password when prompted by the installer; do not run it as root. In the VM, use graphics with Wayland support and accelerated rendering.

## What both profiles share

- **Noctalia 5**: panel, wallpaper, notifications, clipboard, locking, and idle behavior based on the actual preferences in `~/.local/state/noctalia/settings.toml`. You can change settings in the GUI. The bundle includes the community Oxocarbon palette and settings for the selected compositor only.
- **Zsh + Oh My Zsh + Powerlevel10k**: the original `.p10k.zsh`, a working snapshot of Oh My Zsh and its plugins, history, aliases, `fzf`, `zoxide`, the editor, and `~/.local/bin` in PATH.
- **Foot and Kitty** configured with Zsh and a Nerd Font, plus Fuzzel, Rofi, and Yazi.
- GTK/Qt appearance, Kvantum, Adwaita fonts, Tela/Papirus icons, cursors, wallpapers, and utilities.
- NetworkManager, PipeWire/WirePlumber, Bluetooth, polkit, keyring, disk management, and portals for file dialogs and screen sharing.
- EasyEffects, Thunar, Dolphin/KDE, Micro, btop, bat, cava, bottom, fastfetch, htop, Zed, and VS Code settings.
- Custom tools for Wi-Fi, MAC addresses, external monitor brightness, wallpapers, OBS/screen-sharing diagnostics, and additional launcher entries, including HyprLTM-Net. HyprLTM-Net uses Rofi/NetworkManager and works in both environments.
- Flathub Protontricks and Sober, plus isolated Python commands and libraries. You will need to sign in to applications again; no accounts or logged-in profiles are copied.

Oh My Zsh, Powerlevel10k, both Zsh plugins, and pfetch are included as snapshots; Powerlevel10k also includes a working x86_64 gitstatus binary. Revisions are recorded in `audit/shell-versions.json`. Automatic Oh My Zsh updates are disabled because the snapshot does not include `.git`.

## Installer differences

| | `install-niri.sh` | `install-hyprland.sh` |
| --- | --- | --- |
| Session and configuration | niri, `niri/`, `nirimod/` | UWSM-managed Hyprland, `hypr/`, Hyprlock-Styles, and Matugen |
| GUI preferences | nirimod is an optional editor | HyprMod and `hyprland-gui.lua`, including curves, animations, scrolling layout, gaps, borders, and blur |
| Portals and session | niri portals, `niri-session` | Hyprland portals in a UWSM session (`uwsm start -e -D Hyprland hyprland.desktop`) |
| Full AUR profile | shared applications + nirimod | shared applications, without nirimod |
| `--desktop-only` | desktop, shell, and niri | desktop, shell, and Hyprland; HyprMod is installed too |

HyprMod is a Hyprland tool and does not run in the niri profile. For Hyprland, it is fetched from its upstream Git repository at a pinned revision and installed into the user environment; the upstream installation shell script is not run. `--skip-extras` skips HyprMod along with the Git, Python, and Flatpak extras; `--skip-packages` skips software installation, including HyprMod. The niri installer does not install Hyprland, and the Hyprland installer does not install niri. Existing files and programs for the other compositor on the target machine are not deleted or uninstalled.

The shared Noctalia state is configured for the selected compositor. If you run both installers on the same target in sequence, the shared preferences and default greetd session will be set by the last installation; each dotfiles change is backed up. Monitor settings default to automatic detection so they work in a VM. `--keep-monitors` uses the saved physical layout from that configuration. `--vm` forces VM mode and disables automatic guest suspend; locking and screen blanking remain as set in the preferences. `--hardware` uses the original idle behavior.

## Package profiles

You can edit the lists before running the installer; each package must be on its own line. Current versions from the Arch repositories are installed.

| File | Contents |
| --- | --- |
| `packages/desktop.txt` | Shared desktop and shell base from the official repositories |
| `packages/niri.txt`, `packages/hyprland.txt` | Packages for the corresponding compositor |
| `packages/niri-aur.txt` | Full niri AUR profile, including nirimod |
| `packages/full.txt`, `packages/full-aur.txt` | Shared applications for the full profile |
| `packages/niri-git-tools.tsv`, `packages/hyprland-git-tools.tsv` | Git sources for the selected variant; HyprMod is only in the Hyprland list |
| `packages/python-tools.txt`, `packages/python-libs.txt` | Isolated Python tools and libraries |
| `packages/flatpak-apps.txt` | User applications from Flathub |
| `packages/omitted.txt`, `audit/installed-all.txt` | Omitted packages with reasons and the original system package list |

The full profile may enable the official multilib repository for Steam/Wine and related dependencies; it backs up `/etc/pacman.conf` first. If neither `paru` nor `yay` is available, it builds yay with `makepkg` as a regular user. Package manager confirmations remain enabled. If an individual AUR application or Git/Python/Flatpak extra fails, the script continues with the others, reports the errors, and exits with status 2. A missing required program or invalid deployment configuration stops the installation.

## Options

Both installers share these options. The original `install.sh` is the common engine and defaults to niri; you can run it directly with `--compositor niri` or `--compositor hyprland`. The named entry-point scripts above are recommended:

| Option | Meaning |
| --- | --- |
| `--full` | Full profile; default |
| `--desktop-only` | Smaller desktop and shell profile |
| `--vm` / `--hardware` | VM mode / original idle behavior |
| `--keep-monitors` | Use saved physical monitor settings |
| `--enable-greetd` | Configure greetd and a session for the selected compositor for the next boot |
| `--skip-aur` | Skip AUR applications |
| `--skip-extras` | Skip Git, Python, and Flatpak extras, including HyprMod |
| `--skip-packages` | Deploy dotfiles without installing software |
| `--no-services` | Do not configure services or files in `/etc` |
| `--no-chsh` | Keep the current login shell |
| `--dry-run` | Print the plan without making changes |
| `--doctor` | Check the installed environment without making changes |
| `--restore PATH` | Restore dotfiles from a specific backup |

You can set XDG paths with the standard `XDG_CONFIG_HOME`, `XDG_DATA_HOME`, and `XDG_STATE_HOME` variables; they must be absolute and inside HOME. Paths are adjusted for the target computer's user account during deployment.

## Services, backups, and restore

The default installation configures NetworkManager, Bluetooth, power-profiles-daemon, time synchronization, fstrim, and user PipeWire/WirePlumber services. The full profile also enables CUPS, Avahi, and libvirtd for the next boot. Docker and the SSH server are not enabled automatically. Zram and `i2c-dev` are configured only if the target machine does not already have its own configuration. GTK dark mode is set, and Zsh is made the login shell unless you use `--no-chsh`. If the system uses systemd-networkd, switching to NetworkManager takes effect on the next boot; saved Wi-Fi passwords are not transferred.

Before deployment, the installer stages files in a temporary directory and validates the selected compositor's configuration, Noctalia, and Zsh. Replaced paths are backed up to:

```text
~/.local/state/dotfiles/backups/<date-time-pid>/
~/.local/state/dotfiles/logs/install-<compositor>-<date-time-pid>.log
```

If file deployment fails, changes already made to dotfiles are rolled back. Restore a specific backup with the same installer that created it:

```bash
./install-niri.sh --restore "$HOME/.local/state/dotfiles/backups/REPLACE_WITH_BACKUP"
# or
./install-hyprland.sh --restore "$HOME/.local/state/dotfiles/backups/REPLACE_WITH_BACKUP"
```

Restore applies to dotfiles. Packages, Git/Python environments, Flatpak applications, services, and the shell change remain. Files newly created during restore are kept in the same backup. History, accounts, and other unmanaged files in `~/.local/state/noctalia` are preserved; the script manages only the listed preferences and related files.

## Controls

`Mod` is the Super/Windows key. In niri, Super+T opens Foot and Super+Space opens Fuzzel; in Hyprland, Super+T opens Kitty and Super+Space opens the Noctalia launcher. Both profiles use Super+S for Kitty/Yazi, Super+E for Thunar, and Super+I for Noctalia settings. The corresponding files in `payload/config/niri/` and `payload/config/hypr/` contain the other keybindings; helper tools are also available in the launcher.

The keyboard layout is `us,cz` with the Czech QWERTY variant, toggled with Alt+Shift. Screenshots are saved to `~/Pictures/Screenshots`.

After installing the selected profile, you can run:

```bash
./install-niri.sh --doctor
niri validate
noctalia config validate
```

For Hyprland, use `./install-hyprland.sh --doctor` and `Hyprland --verify-config -c "$HOME/.config/hypr/hyprland.lua"`. Hyprland starts through UWSM by default with `uwsm start -e -D Hyprland hyprland.desktop`; direct `start-hyprland` is available as an alternative runner, but is not the default login session. You can reconfigure Powerlevel10k later with `p10k configure` and Noctalia with Super+I. OBS uses the **Screen Capture (PipeWire)** source.

## Privacy and bundle contents

The export includes configurations and tools, but not personal documents or projects, cookies, logins, SSH/GPG keys, network passwords, browser/chat history, or application databases. You will need to sign in to personal accounts again on the target computer. The installer leaves the target system's kernel, GPU drivers, bootloader, and hardware-specific DKMS modules alone. The Sway profile is archived in `reference/config/sway` and its packages are listed in `packages/legacy.txt`; neither installer installs or deploys it. Waybar/SwayNC/wlogout are optional shared alternatives and do not start automatically. For niri, the niri modules are selected in the default Waybar configuration. Old saved Waybar templates also refer to Jakoolit scripts that are missing from the source computer; active Noctalia does not use them.

```text
install.sh                 shared installation engine
install-niri.sh            niri entry point
install-hyprland.sh        Hyprland entry point
manifest.json              shared paths and compositor selection
lib/deploy.py              path adjustment, backups, deployment, and restore
packages/                  editable package and tool lists
payload-archives/          checksummed compressed payload parts and index
payload/                   expanded working copy in the original local bundle
payload/home/              shell, utilities, and wallpapers
payload/config/            shared and compositor-specific configurations
payload/state/             Noctalia preferences, templates, and palettes
payload/data/              icons, cursors, fonts, and desktop files
audit/                     original packages, services, configurations, and inventory
reference/                 archive of historical profiles that are not installed
```

Preparation included an audit of HOME, user configurations and tools, packages, services, and related system files. Sensitive data was excluded. The clean installation of each variant still needs to be confirmed in a VM; the installers have not been run on the original computer.
