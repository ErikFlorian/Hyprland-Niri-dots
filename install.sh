#!/usr/bin/env bash
set -Eeuo pipefail
IFS=$'\n\t'

# Portable Arch Linux dotfiles installer.
# Choose Niri, Hyprland or both. Shared Wayland tools are installed for all choices.
#
# Examples:
#   ./install.sh                     # interactive chooser
#   ./install.sh --niri
#   ./install.sh --hyprland
#   ./install.sh --both --enable-greetd
#   ./install.sh --niri --skip-aur

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
CONFIG_DIR="${XDG_CONFIG_HOME:-$HOME/.config}"
LOCAL_BIN="$HOME/.local/bin"
BACKUP_BASE="$CONFIG_DIR/dotfiles-backups"
COMPOSITOR=""
ENABLE_GREETD=0
SKIP_AUR=0

if [[ "$(uname -m)" != "x86_64" ]]; then
    echo "[error] This installer currently targets x86_64 Arch Linux."
    exit 1
fi

if [[ $EUID -eq 0 ]]; then
    echo "[error] Run this installer as your normal user, not as root."
    exit 1
fi

usage() {
    cat <<'USAGE_EOF'
Usage: ./install.sh [compositor] [options]

Compositor selection (pick one):
  --niri          Install Niri config + dependencies.
  --hyprland      Install Hyprland config + dependencies.
  --both          Install both configurations + dependencies.

When no compositor is supplied, an interactive menu is shown.

Options:
  --enable-greetd  Configure + enable greetd with tuigreet.
  --skip-aur       Skip AUR packages used by the selected setup.
  -h, --help       Show this help.

Examples:
  ./install.sh
  ./install.sh --niri
  ./install.sh --hyprland --enable-greetd
  ./install.sh --both --enable-greetd
USAGE_EOF
}

for arg in "$@"; do
    case "$arg" in
        --niri)
            [[ -z "$COMPOSITOR" ]] || { echo "[error] Choose only one of --niri/--hyprland/--both."; exit 1; }
            COMPOSITOR="niri"
            ;;
        --hyprland)
            [[ -z "$COMPOSITOR" ]] || { echo "[error] Choose only one of --niri/--hyprland/--both."; exit 1; }
            COMPOSITOR="hyprland"
            ;;
        --both)
            [[ -z "$COMPOSITOR" ]] || { echo "[error] Choose only one of --niri/--hyprland/--both."; exit 1; }
            COMPOSITOR="both"
            ;;
        --enable-greetd) ENABLE_GREETD=1 ;;
        --skip-aur) SKIP_AUR=1 ;;
        -h|--help) usage; exit 0 ;;
        *)
            echo "[error] Unknown option: $arg"
            usage
            exit 1
            ;;
    esac
done

if ! command -v pacman >/dev/null 2>&1; then
    echo "[error] pacman not found. This installer is for Arch Linux."
    exit 1
fi
if ! command -v sudo >/dev/null 2>&1; then
    echo "[error] sudo is required."
    exit 1
fi

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
fi

say() { printf '\n==> %s\n' "$*"; }

case "$COMPOSITOR" in
    niri)     SELECTED_LABEL="Niri" ;;
    hyprland) SELECTED_LABEL="Hyprland" ;;
    both)     SELECTED_LABEL="Niri + Hyprland" ;;
    *) echo "[error] Invalid compositor selection: $COMPOSITOR"; exit 1 ;;
esac

decide() {
    local enabled="$1"
    case "$COMPOSITOR:$enabled" in
        niri:niri|hyprland:hyprland|both:*) return 0 ;;
        *) return 1 ;;
    esac
}

SHARED_PKGS=(
    waybar swaync fuzzel rofi
    kitty thunar yazi
    greetd greetd-tuigreet
    networkmanager network-manager-applet blueman bluez bluez-utils
    pipewire pipewire-audio pipewire-pulse wireplumber easyeffects pavucontrol
    brightnessctl ddcutil playerctl
    wl-clipboard cliphist grim slurp libnotify jq
    udiskie cava
    matugen awww
    xdg-desktop-portal-gnome xdg-desktop-portal-gtk
    ttf-jetbrains-mono-nerd otf-font-awesome
    git base-devel
)

NIRI_PKGS=(
    niri
    swaybg swayidle swaylock
    xwayland-satellite
)

HYPRLAND_PKGS=(
    hyprland hyprlock hypridle hyprpm
    noctalia
    xdg-desktop-portal-hyprland
)

AUR_PKGS=()
OPTIONAL_AUR_PKGS=()

if [[ "$COMPOSITOR" == "niri" || "$COMPOSITOR" == "both" ]]; then
    AUR_PKGS+=(wlogout waypaper)
    OPTIONAL_AUR_PKGS+=(fluxcast-git)
fi

say "Selected setup: $SELECTED_LABEL"

PACKAGE_LIST=("${SHARED_PKGS[@]}")
if decide niri; then
    PACKAGE_LIST+=("${NIRI_PKGS[@]}")
fi
if decide hyprland; then
    PACKAGE_LIST+=("${HYPRLAND_PKGS[@]}")
fi

say "Installing Arch packages"
sudo pacman -Syu --needed "${PACKAGE_LIST[@]}"

if (( ! SKIP_AUR )) && (( ${#AUR_PKGS[@]} + ${#OPTIONAL_AUR_PKGS[@]} > 0 )); then
    say "Installing AUR extras for $SELECTED_LABEL"
    AUR_HELPER=""
    if command -v paru >/dev/null 2>&1; then
        AUR_HELPER="paru"
    elif command -v yay >/dev/null 2>&1; then
        AUR_HELPER="yay"
    fi

    install_aur_pkg() {
        local pkg="$1"
        if [[ -n "$AUR_HELPER" ]]; then
            "$AUR_HELPER" -S --needed "$pkg"
            return
        fi

        local tmp_pkg
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

    for pkg in "${AUR_PKGS[@]}"; do
        install_aur_pkg "$pkg"
    done

    for pkg in "${OPTIONAL_AUR_PKGS[@]}"; do
        if ! install_aur_pkg "$pkg"; then
            echo "[warning] Optional AUR package '$pkg' could not be installed; related helper will be unavailable."
        fi
    done
elif (( SKIP_AUR )) && (( ${#AUR_PKGS[@]} > 0 )); then
    echo "[info] AUR packages skipped. Some selected features (such as wlogout/waypaper) will be unavailable."
fi

say "Backing up existing dotfiles"
STAMP="$(date +%Y%m%d-%H%M%S)"
BACKUP_DIR="$BACKUP_BASE/$STAMP"
mkdir -p "$BACKUP_DIR"

backup_and_copy_dir() {
    local src="$1" dest="$2"
    mkdir -p "$(dirname -- "$dest")"
    if [[ -e "$dest" || -L "$dest" ]]; then
        cp -a -- "$dest" "$BACKUP_DIR/$(basename -- "$dest")"
    fi
    rm -rf -- "$dest"
    mkdir -p "$dest"
    cp -a -- "$src/." "$dest/"
}

# Shared configs.
for name in waybar rofi fuzzel swaync kitty matugen networkmanager-dmenu; do
    backup_and_copy_dir "$SCRIPT_DIR/$name" "$CONFIG_DIR/$name"
done

# Install only the selected compositor configs.
if decide niri; then
    backup_and_copy_dir "$SCRIPT_DIR/niri" "$CONFIG_DIR/niri"
fi

if decide hyprland; then
    backup_and_copy_dir "$SCRIPT_DIR/hypr" "$CONFIG_DIR/hypr"
    backup_and_copy_dir "$SCRIPT_DIR/Hyprlock-Styles" "$HOME/Hyprlock-Styles"
fi

say "Installing local helper scripts"
mkdir -p "$LOCAL_BIN"
cp -a -- "$SCRIPT_DIR/bin/." "$LOCAL_BIN/"
chmod +x "$LOCAL_BIN"/*.sh "$LOCAL_BIN"/dotfiles-lock "$LOCAL_BIN"/dotfiles-session-exit "$LOCAL_BIN"/dotfiles-airplane

# Niri and Hyprland can use the same bundled default wallpaper, but keep the
# path inside the selected compositor's own config tree so either setup works alone.
if decide niri && [[ ! -e "$CONFIG_DIR/niri/current_wallpaper" ]]; then
    cp -a -- "$SCRIPT_DIR/hypr/default-wallpaper.png" "$CONFIG_DIR/niri/default-wallpaper.png"
    ln -s "default-wallpaper.png" "$CONFIG_DIR/niri/current_wallpaper"
fi

if decide hyprland && [[ ! -e "$CONFIG_DIR/hypr/current_wallpaper" ]]; then
    ln -s "default-wallpaper.png" "$CONFIG_DIR/hypr/current_wallpaper"
fi

# Preserve any local Eduroam credentials; otherwise create a private starter file.
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

# Keep launcher/theme paths portable in the installed configs.
ROFI_CFG="$CONFIG_DIR/rofi/config.rasi"
FUZZEL_CFG="$CONFIG_DIR/fuzzel/fuzzel.ini"
if [[ -f "$ROFI_CFG" ]]; then
    sed -i "s|^@theme .*|@theme \"$CONFIG_DIR/rofi/themes/theme.rasi\"|" "$ROFI_CFG"
fi
if [[ -f "$FUZZEL_CFG" ]]; then
    sed -i "s|^include=.*|include=$CONFIG_DIR/fuzzel/themes/noctalia|" "$FUZZEL_CFG"
fi

# Ensure user-local binaries are available for shells launched from this install.
for rc in "$HOME/.bashrc" "$HOME/.zshrc"; do
    if [[ -f "$rc" ]] && ! grep -Fq '$HOME/.local/bin' "$rc"; then
        printf '\n# Added by dotfiles installer\nexport PATH="$HOME/.local/bin:$PATH"\n' >> "$rc"
    fi
done

# Greetd is opt-in because enabling it changes the login path.
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

    if [[ "$COMPOSITOR" == "both" ]]; then
        echo "greetd is enabled; tuigreet will offer both installed Wayland sessions."
    else
        echo "greetd is enabled and will start $SELECTED_LABEL."
    fi
fi

say "Done"
echo "Setup:              $SELECTED_LABEL"
echo "Configs installed:  $CONFIG_DIR"
echo "Helper scripts:     $LOCAL_BIN"
echo "Backup:             $BACKUP_DIR"
echo
echo "Next steps:"
if decide niri; then
    echo "  Niri:      run 'niri validate' before starting it."
fi
if decide hyprland; then
    echo "  Hyprland:  start 'Hyprland' from the session chooser."
fi
echo "  Eduroam:   edit ~/.config/waybar/eduroam.conf only if you use it."
if (( ! ENABLE_GREETD )); then
    echo "  Greetd:    not enabled; use --enable-greetd when you are ready."
fi
