# Niri / Hyprland full Arch dotfiles

A portable Arch Linux Wayland setup for **Niri**, **Hyprland**, or **both**.

The repository bundles the original desktop configuration plus a full bootstrap layer: Waybar, SwayNC, Fuzzel/Rofi, Kitty, PipeWire tooling, Matugen, Yazi, wallpapers, Zsh, Oh My Zsh, Powerlevel10k, modern CLI tools, GTK/Qt theming, fonts, and optional greetd/tuigreet.

## Install

```bash
git clone https://github.com/ErikFlorian/Hyprland-Niri-dots
cd Hyprland-Niri-dots
chmod +x install.sh
./install.sh
```

The interactive installer asks for the compositor:

```text
Choose your compositor setup:
  1) Niri
  2) Hyprland
  3) Both
```

By default the **full profile** is used. It installs the shell/CLI/desktop-polish layer as well.

For scripted installs:

```bash
./install.sh --niri --full
./install.sh --hyprland --full
./install.sh --both --full
```

Minimal setup:

```bash
./install.sh --niri --minimal
./install.sh --hyprland --minimal
```

Useful switches:

```text
--no-zsh            skip Zsh + Oh My Zsh + Powerlevel10k
--no-cli            skip fastfetch/btop/eza/bat/fzf/zoxide/etc.
--no-desktop        skip GTK/Qt/theme extras
--no-chsh            do not make Zsh the login shell
--enable-services   enable NetworkManager + bluetooth
--enable-greetd     configure and enable greetd + tuigreet
--skip-aur          skip AUR packages
```

A one-shot full install can look like:

```bash
./install.sh --both --full --enable-services --enable-greetd
```

## What the full profile adds

### Zsh

The installer installs Zsh plus the Arch-packaged completion/highlighting/autosuggestion plugins, then installs **Oh My Zsh** and **Powerlevel10k** into the user account. Powerlevel10k is cloned from its upstream repository, so a separate AUR package is not required.

It also installs a practical shell toolkit:

- `eza` for directory listings
- `bat` for file viewing
- `fd` + `ripgrep` for searching
- `fzf` for fuzzy finding
- `zoxide` for directory jumping
- `fastfetch` for terminal system info
- `btop` for system monitoring
- `lazygit` for Git TUI
- `tmux`
- `neovim`
- `tealdeer` (`tldr`)

The default `.zshrc` uses the Arch-provided Zsh plugin paths and loads syntax highlighting after autosuggestions, as recommended by Arch documentation.

The first run shows `fastfetch`. Run `p10k configure` later to open the Powerlevel10k interactive prompt wizard.

### Desktop polish

The full profile also adds:

- Papirus icons
- `nwg-look` for GTK styling
- `qt6ct` + Kvantum for Qt styling
- `polkit-kde-agent`
- video/image preview support for file managers (`ffmpegthumbnailer`, ImageMagick, Chafa, FFmpeg, 7zip)
- JetBrains Mono Nerd Font + Meslo Nerd Font

### Wayland desktop

Shared components include Waybar, SwayNC, Fuzzel/Rofi, Kitty, audio/network helpers, screenshots, clipboard tools, Matugen, `awww`, Yazi, and the bundled helper scripts.

Only the selected compositor configuration is copied.

**Niri** adds Niri + Sway-compatible idle/lock tools and the selected Niri AUR extras.

**Hyprland** adds Hyprland + Hyprlock/Hypridle/Hyprpm/Hyprpicker/Hyprshot + Noctalia and the Hyprland XDG portal.

## Backups

Before replacing existing files, the installer saves them under:

```text
~/.config/dotfiles-backups/<timestamp>/
```

The same backup mechanism is used for `.zshrc`, `.p10k.zsh`, and other user config files managed by the installer.

## greetd + tuigreet

`greetd` and `tuigreet` are installed as part of the base stack, but the service is **not enabled unless requested**.

```bash
./install.sh --niri --enable-greetd
./install.sh --hyprland --enable-greetd
./install.sh --both --enable-greetd
```

When both compositors are installed, tuigreet keeps the Wayland session chooser. With only one compositor selected, the installer can start that session directly.

## Services

The optional service switch enables NetworkManager and Bluetooth:

```bash
./install.sh --both --enable-services
```

PipeWire/WirePlumber are installed but left to normal user-session activation.

## Eduroam

The public repository contains only a template. After installation:

```bash
cp ~/.config/waybar/scripts/eduroam.conf.example ~/.config/waybar/eduroam.conf
chmod 600 ~/.config/waybar/eduroam.conf
$EDITOR ~/.config/waybar/eduroam.conf
```

Never commit the credential file.

## Wallpapers / Matugen

The compositor configs use the portable bundled wallpaper path. Replace `current_wallpaper` with your own image or symlink when desired.

- Niri: `~/.config/niri/current_wallpaper`
- Hyprland: `~/.config/hypr/current_wallpaper`

The Matugen hook uses `awww`.

## Hyprlock styles

`Hyprlock-Styles` is installed only with Hyprland. User-specific files and original credential material are intentionally not included in the public tree.

## Notes for maintainers

The installer is intentionally split into core, shell, CLI, desktop-polish, compositor, and service layers. This makes it possible to publish the repository publicly without forcing every user to install every optional component.

Test the generated install on a clean Arch VM before publishing the repository as the default one-command bootstrap.
