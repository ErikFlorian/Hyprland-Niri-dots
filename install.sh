#!/usr/bin/env bash
set -Eeuo pipefail
IFS=$'\n\t'

# Print the failing command and line number instead of silently exiting.
trap 'rc=$?; echo "[error] Installer stopped at line $LINENO (exit $rc): $BASH_COMMAND" >&2' ERR

# Full Arch Linux Wayland bootstrap for Niri / Hyprland.
#
# Examples:
#   ./install.sh                              # interactive, full profile by default
#   ./install.sh --both --full --enable-greetd --enable-services
#   ./install.sh --niri --no-zsh
#   ./install.sh --hyprland --minimal
#   ./install.sh --both --skip-aur --no-chsh

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
CONFIG_DIR="${XDG_CONFIG_HOME:-$HOME/.config}"
LOCAL_BIN="$HOME/.local/bin"
export PATH="$LOCAL_BIN:$PATH"
BACKUP_BASE="$CONFIG_DIR/dotfiles-backups"
ZSH_DIR="$HOME/.oh-my-zsh"
ZSH_CUSTOM="$ZSH_DIR/custom"
P10K_DIR="$ZSH_CUSTOM/themes/powerlevel10k"

COMPOSITOR=""
PROFILE="full"
SHELL_SETUP=1
CLI_SETUP=1
DESKTOP_SETUP=1
WAYPAPER_SETUP=1
CHANGE_DEFAULT_SHELL=1
ENABLE_GREETD=0
ENABLE_SERVICES=0
SKIP_AUR=0
INSTALL_AUR_EXTRAS=0

usage() {
    cat <<'USAGE_EOF'
Usage: ./install.sh [compositor] [profile] [options]

Compositor selection:
  --niri             Install Niri config + dependencies.
  --hyprland         Install Hyprland config + dependencies.
  --both             Install both configurations + dependencies.

Profiles:
  --full              Shell + CLI + desktop polish (default).
  --minimal           Only core shared packages + selected compositor.
  --no-zsh            Skip Zsh + Oh My Zsh + Powerlevel10k.
  --no-cli            Skip the terminal/CLI comfort tools.
  --no-desktop        Skip GTK/Qt/theme/desktop extras.
  --no-waypaper       Skip Waypaper.
  --no-chsh           Do not make Zsh the default login shell.

System/session options:
  --enable-services   Enable NetworkManager + bluetooth services.
  --enable-greetd     Configure + enable greetd with tuigreet.
  --aur-extras        Attempt optional AUR extras (e.g. wlogout); failures are non-fatal.
  --skip-aur          Skip AUR packages.
  -h, --help          Show this help.

Examples:
  ./install.sh
  ./install.sh --both --full
  ./install.sh --niri --no-zsh
  ./install.sh --hyprland --minimal
  ./install.sh --both --full --enable-services --enable-greetd
USAGE_EOF
}

for arg in "$@"; do
    case "$arg" in
        --niri)
            [[ -z "$COMPOSITOR" ]] || { echo "[error] Choose only one compositor flag."; exit 1; }
            COMPOSITOR="niri"
            ;;
        --hyprland)
            [[ -z "$COMPOSITOR" ]] || { echo "[error] Choose only one compositor flag."; exit 1; }
            COMPOSITOR="hyprland"
            ;;
        --both)
            [[ -z "$COMPOSITOR" ]] || { echo "[error] Choose only one compositor flag."; exit 1; }
            COMPOSITOR="both"
            ;;
        --full)
            PROFILE="full"
            ;;
        --minimal)
            PROFILE="minimal"
            ;;
        --no-zsh)
            SHELL_SETUP=0
            ;;
        --no-cli)
            CLI_SETUP=0
            ;;
        --no-desktop)
            DESKTOP_SETUP=0
            ;;
        --no-waypaper)
            WAYPAPER_SETUP=0
            ;;
        --no-chsh)
            CHANGE_DEFAULT_SHELL=0
            ;;
        --enable-services)
            ENABLE_SERVICES=1
            ;;
        --enable-greetd)
            ENABLE_GREETD=1
            ;;
        --aur-extras)
            INSTALL_AUR_EXTRAS=1
            SKIP_AUR=0
            ;;
        --skip-aur)
            SKIP_AUR=1
            INSTALL_AUR_EXTRAS=0
            ;;
        -h|--help)
            usage
            exit 0
            ;;
        *)
            echo "[error] Unknown option: $arg"
            usage
            exit 1
            ;;
    esac
done

if [[ "$(uname -m)" != "x86_64" ]]; then
    echo "[error] This installer currently targets x86_64 Arch Linux."
    exit 1
fi

if [[ $EUID -eq 0 ]]; then
    echo "[error] Run this installer as your normal user, not as root."
    exit 1
fi

if [[ "$PROFILE" == "minimal" ]]; then
    SHELL_SETUP=0
    CLI_SETUP=0
    DESKTOP_SETUP=0
    CHANGE_DEFAULT_SHELL=0
    WAYPAPER_SETUP=0
    INSTALL_AUR_EXTRAS=0
fi

if ! command -v pacman >/dev/null 2>&1; then
    echo "[error] pacman not found. This installer is for Arch Linux."
    exit 1
fi
if ! command -v sudo >/dev/null 2>&1; then
    echo "[error] sudo is required."
    exit 1
fi

say() { printf '\n==> %s\n' "$*"; }
warn() { printf '[warning] %s\n' "$*" >&2; }

if [[ -z "$COMPOSITOR" ]]; then
    if [[ ! -t 0 ]]; then
        echo "[error] No compositor was selected and stdin is not interactive. Use --niri, --hyprland or --both."
        exit 1
    fi

    cat <<'MENU_EOF'

Choose your compositor setup:
  1) Niri
  2) Hyprland
  3) Both
MENU_EOF
    while :; do
        read -r -p "Selection [1-3]: " choice
        case "$choice" in
            1|n|N|niri|Niri) COMPOSITOR="niri"; break ;;
            2|h|H|hypr|Hyprland|hyprland) COMPOSITOR="hyprland"; break ;;
            3|b|B|both|Both) COMPOSITOR="both"; break ;;
            *) echo "Please choose 1, 2 or 3." ;;
        esac
    done

    if [[ "$PROFILE" == "full" ]]; then
        read -r -p "Install full shell + CLI + desktop polish? [Y/n]: " choice
        case "${choice:-Y}" in
            n|N|no|NO) SHELL_SETUP=0; CLI_SETUP=0; DESKTOP_SETUP=0; CHANGE_DEFAULT_SHELL=0 ;;
        esac

        if (( SHELL_SETUP )); then
            read -r -p "Make Zsh your default login shell? [Y/n]: " choice
            case "${choice:-Y}" in
                n|N|no|NO) CHANGE_DEFAULT_SHELL=0 ;;
            esac
        fi

        read -r -p "Enable NetworkManager + bluetooth services now? [y/N]: " choice
        case "${choice:-N}" in
            y|Y|yes|YES) ENABLE_SERVICES=1 ;;
        esac

        read -r -p "Enable greetd + tuigreet now? [y/N]: " choice
        case "${choice:-N}" in
            y|Y|yes|YES) ENABLE_GREETD=1 ;;
        esac

        if (( WAYPAPER_SETUP )) && decide niri; then
            read -r -p "Install Waypaper? [Y/n]: " choice
            case "${choice:-Y}" in
                n|N|no|NO) WAYPAPER_SETUP=0 ;;
            esac
        fi

        read -r -p "Attempt optional AUR extras (wlogout)? [y/N]: " choice
        case "${choice:-N}" in
            y|Y|yes|YES) INSTALL_AUR_EXTRAS=1 ;;
        esac
    fi
fi

case "$COMPOSITOR" in
    niri) SELECTED_LABEL="Niri" ;;
    hyprland) SELECTED_LABEL="Hyprland" ;;
    both) SELECTED_LABEL="Niri + Hyprland" ;;
    *) echo "[error] Invalid compositor selection: $COMPOSITOR"; exit 1 ;;
esac

decide() {
    local target="$1"
    case "$COMPOSITOR:$target" in
        niri:niri|hyprland:hyprland|both:*) return 0 ;;
        *) return 1 ;;
    esac
}

SHARED_PKGS=(
    waybar swaync fuzzel rofi
    kitty thunar yazi
    networkmanager network-manager-applet blueman bluez bluez-utils
    pipewire pipewire-audio pipewire-pulse wireplumber easyeffects pavucontrol
    brightnessctl ddcutil playerctl
    wl-clipboard wl-clip-persist cliphist grim slurp libnotify jq
    udiskie cava matugen awww
    xdg-desktop-portal-gnome xdg-desktop-portal-gtk
    ttf-jetbrains-mono-nerd ttf-meslo-nerd otf-font-awesome
    git base-devel
)

NIRI_PKGS=(
    niri swaybg swayidle swaylock
    xwayland-satellite
)

HYPRLAND_PKGS=(
    hyprland hyprlock hypridle hyprpm hyprpicker hyprshot
    noctalia xdg-desktop-portal-hyprland
)

SHELL_PKGS=(
    zsh zsh-autosuggestions zsh-syntax-highlighting zsh-completions
)

CLI_PKGS=(
    fzf zoxide eza bat fd ripgrep fastfetch btop lazygit
    tmux neovim tealdeer
)

DESKTOP_PKGS=(
    papirus-icon-theme nwg-look qt6ct kvantum
    polkit-kde-agent ffmpegthumbnailer
    imagemagick chafa ffmpeg 7zip
    xdg-user-dirs xdg-utils
)

AUR_PKGS=()
OPTIONAL_AUR_PKGS=()
LOGIN_PKGS=(greetd greetd-tuigreet)

if decide niri; then
    if (( WAYPAPER_SETUP )); then
        NIRI_PKGS+=(python-pipx python-gobject python-imageio python-pillow python-platformdirs)
    fi
    # Optional AUR cosmetics. They must NEVER make the core install fail.
    OPTIONAL_AUR_PKGS+=(wlogout)
fi

say "Selected setup: $SELECTED_LABEL"
[[ "$PROFILE" == "minimal" ]] && echo "Profile:             minimal"
[[ "$PROFILE" == "full" ]] && echo "Profile:             full"
(( SHELL_SETUP )) && echo "Zsh stack:            enabled (Oh My Zsh + Powerlevel10k)"
(( CLI_SETUP )) && echo "CLI toolkit:           enabled"
(( DESKTOP_SETUP )) && echo "Desktop polish:        enabled"
(( WAYPAPER_SETUP )) && decide niri && echo "Waypaper:             enabled (pipx)"
(( INSTALL_AUR_EXTRAS )) && ! (( SKIP_AUR )) && echo "AUR extras:            enabled (optional, non-fatal)"
(( ENABLE_SERVICES )) && echo "Services:              NetworkManager + bluetooth will be enabled"
(( ENABLE_GREETD )) && echo "Login manager:         greetd + tuigreet will be enabled"

PACKAGE_LIST=("${SHARED_PKGS[@]}")
if decide niri; then PACKAGE_LIST+=("${NIRI_PKGS[@]}"); fi
if decide hyprland; then PACKAGE_LIST+=("${HYPRLAND_PKGS[@]}"); fi
(( SHELL_SETUP )) && PACKAGE_LIST+=("${SHELL_PKGS[@]}")
(( CLI_SETUP )) && PACKAGE_LIST+=("${CLI_PKGS[@]}")
(( DESKTOP_SETUP )) && PACKAGE_LIST+=("${DESKTOP_PKGS[@]}")
if (( ENABLE_GREETD )); then
    PACKAGE_LIST+=("${LOGIN_PKGS[@]}")
fi

# Remove duplicate package names while keeping order.
mapfile -t PACKAGE_LIST < <(printf '%s\n' "${PACKAGE_LIST[@]}" | awk '!seen[$0]++')

say "Installing Arch packages"
sudo pacman -Syu --needed "${PACKAGE_LIST[@]}"

install_aur_pkg() {
    local pkg="$1" aur_helper="" tmp_pkg

    if (( SKIP_AUR )); then
        return 0
    fi

    if command -v paru >/dev/null 2>&1; then
        aur_helper="paru"
    elif command -v yay >/dev/null 2>&1; then
        aur_helper="yay"
    fi

    if [[ -n "$aur_helper" ]]; then
        "$aur_helper" -S --needed "$pkg"
        return
    fi

    tmp_pkg="$(mktemp -d)"
    if ! git clone --depth=1 "https://aur.archlinux.org/$pkg.git" "$tmp_pkg/$pkg"; then
        rm -rf -- "$tmp_pkg"
        return 1
    fi
    if ! ( cd "$tmp_pkg/$pkg" && makepkg -si --noconfirm ); then
        rm -rf -- "$tmp_pkg"
        return 1
    fi
    rm -rf -- "$tmp_pkg"
}

if (( INSTALL_AUR_EXTRAS && ! SKIP_AUR )) && (( ${#AUR_PKGS[@]} + ${#OPTIONAL_AUR_PKGS[@]} > 0 )); then
    say "Installing optional AUR extras (failures are non-fatal)"
    for pkg in "${AUR_PKGS[@]}" "${OPTIONAL_AUR_PKGS[@]}"; do
        [[ -z "$pkg" ]] && continue
        if ! install_aur_pkg "$pkg"; then
            warn "Optional AUR package '$pkg' could not be installed. Continuing without it."
        fi
    done
else
    echo "==> AUR extras not selected; skipping AUR builds."
fi

STAMP="$(date +%Y%m%d-%H%M%S)"
BACKUP_DIR="$BACKUP_BASE/$STAMP"
mkdir -p "$BACKUP_DIR"

say "Backing up and installing dotfiles"

# Fail early with a useful message if the repo checkout is incomplete.
REQUIRED_SHARED_CONFIGS=(waybar rofi fuzzel swaync kitty matugen networkmanager-dmenu bin)
for name in "${REQUIRED_SHARED_CONFIGS[@]}"; do
    if [[ ! -d "$SCRIPT_DIR/$name" ]]; then
        echo "[error] Missing repo directory: $SCRIPT_DIR/$name" >&2
        echo "        Re-clone/re-extract the dotfiles repo and run the installer again." >&2
        exit 1
    fi
done
if decide niri && [[ ! -d "$SCRIPT_DIR/niri" ]]; then
    echo "[error] Niri config directory is missing: $SCRIPT_DIR/niri" >&2
    exit 1
fi
if decide hyprland && [[ ! -d "$SCRIPT_DIR/hypr" ]]; then
    echo "[error] Hyprland config directory is missing: $SCRIPT_DIR/hypr" >&2
    exit 1
fi
if decide hyprland && [[ ! -d "$SCRIPT_DIR/Hyprlock-Styles" ]]; then
    echo "[error] Hyprlock-Styles directory is missing: $SCRIPT_DIR/Hyprlock-Styles" >&2
    exit 1
fi

backup_path() {
    local path="$1"
    [[ -e "$path" || -L "$path" ]] || return 0
    local rel
    rel="${path#"$HOME/"}"
    mkdir -p "$BACKUP_DIR/$(dirname -- "$rel")"
    cp -a -- "$path" "$BACKUP_DIR/$rel"
}

replace_path() {
    local src="$1" dest="$2"
    backup_path "$dest"
    rm -rf -- "$dest"
    mkdir -p "$(dirname -- "$dest")"
    if [[ -d "$src" ]]; then
        mkdir -p "$dest"
        cp -a -- "$src/." "$dest/"
    else
        cp -a -- "$src" "$dest"
    fi
}

# Shared configs.
for name in waybar rofi fuzzel swaync kitty matugen networkmanager-dmenu; do
    replace_path "$SCRIPT_DIR/$name" "$CONFIG_DIR/$name"
done

if decide niri; then
    replace_path "$SCRIPT_DIR/niri" "$CONFIG_DIR/niri"
fi

if decide hyprland; then
    replace_path "$SCRIPT_DIR/hypr" "$CONFIG_DIR/hypr"
    replace_path "$SCRIPT_DIR/Hyprlock-Styles" "$HOME/Hyprlock-Styles"
fi

if (( DESKTOP_SETUP )); then
    if [[ -d "$SCRIPT_DIR/gtk-3.0" ]]; then replace_path "$SCRIPT_DIR/gtk-3.0" "$CONFIG_DIR/gtk-3.0"; fi
    if [[ -d "$SCRIPT_DIR/gtk-4.0" ]]; then replace_path "$SCRIPT_DIR/gtk-4.0" "$CONFIG_DIR/gtk-4.0"; fi
fi

if (( CLI_SETUP )); then
    [[ -d "$SCRIPT_DIR/fastfetch" ]] && replace_path "$SCRIPT_DIR/fastfetch" "$CONFIG_DIR/fastfetch"
    [[ -d "$SCRIPT_DIR/tmux" ]] && replace_path "$SCRIPT_DIR/tmux" "$CONFIG_DIR/tmux"
fi

mkdir -p "$LOCAL_BIN"
cp -a -- "$SCRIPT_DIR/bin/." "$LOCAL_BIN/"
find "$LOCAL_BIN" -maxdepth 1 -type f -exec chmod +x {} +

# Portable wallpaper symlinks.
if decide niri && [[ ! -e "$CONFIG_DIR/niri/current_wallpaper" ]]; then
    ln -s "$CONFIG_DIR/niri/default-wallpaper.png" "$CONFIG_DIR/niri/current_wallpaper"
fi
if decide hyprland && [[ ! -e "$CONFIG_DIR/hypr/current_wallpaper" ]]; then
    ln -s "default-wallpaper.png" "$CONFIG_DIR/hypr/current_wallpaper"
fi

# Private Eduroam credentials.
EDU_LOCAL="$CONFIG_DIR/waybar/eduroam.conf"
if [[ ! -e "$EDU_LOCAL" ]]; then
    cat > "$EDU_LOCAL" <<'EDU_EOF'
# Local Eduroam credentials. Never commit this file.
IDENTITY=""
PASSWORD=""
ANON_IDENTITY=""
EAP="peap"
PHASE2="mschapv2"
DOMAIN_SUFFIX_MATCH=""
CA_CERT=""
ALLOW_UNVERIFIED=0
EDU_EOF
fi
chmod 600 "$EDU_LOCAL"

install_waypaper() {
    (( WAYPAPER_SETUP )) || return 0
    decide niri || return 0

    if command -v waypaper >/dev/null 2>&1; then
        say "Waypaper already installed"
        return 0
    fi

    if ! command -v pipx >/dev/null 2>&1; then
        warn "pipx is not available; skipping Waypaper."
        return 0
    fi

    say "Installing Waypaper via pipx (isolated Python environment)"
    # Upstream documents pipx as a supported install path.
    # --system-site-packages lets Waypaper use Arch's python-gobject/GTK stack,
    # while pipx keeps Python-only dependencies isolated from the system Python.
    if pipx install --system-site-packages waypaper; then
        return 0
    fi

    # A previous partial install can leave a broken pipx environment behind.
    warn "Initial Waypaper install failed; retrying with a clean pipx environment."
    pipx uninstall waypaper >/dev/null 2>&1 || true
    if ! pipx install --system-site-packages waypaper; then
        warn "Waypaper could not be installed. The rest of the desktop setup will continue."
    fi
}

install_waypaper

# Keep launcher/theme paths portable.
ROFI_CFG="$CONFIG_DIR/rofi/config.rasi"
FUZZEL_CFG="$CONFIG_DIR/fuzzel/fuzzel.ini"
if [[ -f "$ROFI_CFG" ]]; then
    sed -i "s|^@theme .*|@theme \"$CONFIG_DIR/rofi/themes/theme.rasi\"|" "$ROFI_CFG"
fi
if [[ -f "$FUZZEL_CFG" ]]; then
    sed -i "s|^include=.*|include=$CONFIG_DIR/fuzzel/themes/noctalia|" "$FUZZEL_CFG"
fi

if (( SHELL_SETUP )); then
    say "Installing Oh My Zsh + Powerlevel10k"
    if [[ ! -d "$ZSH_DIR" ]]; then
        git clone --depth=1 https://github.com/ohmyzsh/ohmyzsh.git "$ZSH_DIR"
    fi

    mkdir -p "$ZSH_CUSTOM/themes"
    if [[ ! -d "$P10K_DIR" ]]; then
        git clone --depth=1 https://github.com/romkatv/powerlevel10k.git "$P10K_DIR"
    fi

    replace_path "$SCRIPT_DIR/zsh/.zshrc" "$HOME/.zshrc"
    replace_path "$SCRIPT_DIR/zsh/.p10k.zsh" "$HOME/.p10k.zsh"

    if (( CHANGE_DEFAULT_SHELL )); then
        if command -v chsh >/dev/null 2>&1; then
            current_shell="$(getent passwd "$USER" | cut -d: -f7 || true)"
            if [[ "$current_shell" != "/usr/bin/zsh" ]]; then
                say "Making Zsh the default login shell"
                chsh -s /usr/bin/zsh
            fi
        else
            warn "chsh was not found; Zsh was installed but not selected as the login shell."
        fi
    fi
fi

# Ensure ~/.local/bin is available even for users who do not install our zsh config.
for rc in "$HOME/.bashrc" "$HOME/.zshrc"; do
    if [[ -f "$rc" ]] && ! grep -Fq 'export PATH="$HOME/.local/bin:$PATH"' "$rc"; then
        printf '\n# Added by dotfiles installer\nexport PATH="$HOME/.local/bin:$PATH"\n' >> "$rc"
    fi
done

# Keep XDG folders sane on fresh installs.
if (( DESKTOP_SETUP )) && command -v xdg-user-dirs-update >/dev/null 2>&1; then
    xdg-user-dirs-update >/dev/null 2>&1 || true
fi

if (( ENABLE_SERVICES )); then
    say "Enabling desktop services"
    sudo systemctl enable --now NetworkManager.service
    sudo systemctl enable --now bluetooth.service
fi

if (( ENABLE_GREETD )); then
    say "Configuring greetd + tuigreet"
    sudo install -d -m 0755 /etc/greetd
    if [[ -f /etc/greetd/config.toml ]]; then
        sudo cp -a /etc/greetd/config.toml "/etc/greetd/config.toml.bak.$STAMP"
    fi

    case "$COMPOSITOR" in
        niri)
            TUI_CMD='tuigreet --cmd niri-session --time --remember --remember-session --asterisks --greet-align center'
            ;;
        hyprland)
            TUI_CMD='tuigreet --cmd Hyprland --time --remember --remember-session --asterisks --greet-align center'
            ;;
        both)
            TUI_CMD='tuigreet --time --remember --remember-session --asterisks --greet-align center'
            ;;
    esac

    sudo tee /etc/greetd/config.toml >/dev/null <<GREETD_EOF
[terminal]
vt = 1

[default_session]
command = "$TUI_CMD"
user = "greeter"
GREETD_EOF
    sudo systemctl enable greetd.service
fi

say "Done"
echo "Setup:              $SELECTED_LABEL"
echo "Profile:            $PROFILE"
echo "Configs:             $CONFIG_DIR"
echo "Helpers:             $LOCAL_BIN"
echo "Backup:              $BACKUP_DIR"
echo
if (( SHELL_SETUP )); then
    echo "Zsh:                 $(command -v zsh)"
    echo "Oh My Zsh:           $ZSH_DIR"
    echo "Powerlevel10k:       $P10K_DIR"
fi
if decide niri; then echo "Niri:                run 'niri validate' before starting it."; fi
if decide niri && (( WAYPAPER_SETUP )); then echo "Waypaper:             installed via pipx when available."; fi
if decide hyprland; then echo "Hyprland:             start 'Hyprland' from the session chooser."; fi
if (( CLI_SETUP )); then echo "CLI:                 fastfetch / btop / eza / bat / fd / rg / fzf / zoxide / lazygit / tmux / nvim / tldr"; fi
if (( DESKTOP_SETUP )); then echo "Theme tools:          nwg-look / qt6ct / Kvantum / Papirus"; fi
if (( ! ENABLE_GREETD )); then echo "Greetd:              not enabled; use --enable-greetd when ready."; fi
if (( ! ENABLE_SERVICES )); then echo "Services:             not enabled; use --enable-services when ready."; fi
echo "Eduroam:             edit ~/.config/waybar/eduroam.conf only if you use it."
