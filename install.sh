#!/usr/bin/env bash
# Shared Arch Linux installer for niri or Hyprland + Noctalia.
set -Eeuo pipefail
IFS=$'\n\t'
umask 077

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
BUNDLE_DIR="$SCRIPT_DIR"
[[ -f "$BUNDLE_DIR/manifest.json" ]] || BUNDLE_DIR="$SCRIPT_DIR/dotfiles-arch-niri"
DEPLOY_BUNDLE="$BUNDLE_DIR"
CONFIG_ROOT="${XDG_CONFIG_HOME:-$HOME/.config}"
STATE_ROOT="${XDG_STATE_HOME:-$HOME/.local/state}"
DATA_ROOT="${XDG_DATA_HOME:-$HOME/.local/share}"
CACHE_ROOT="${XDG_CACHE_HOME:-$HOME/.cache}"
PROFILE=full
COMPOSITOR="${DOTFILES_COMPOSITOR:-niri}"
DRY_RUN=0
SKIP_PACKAGES=0
SKIP_AUR=0
SKIP_EXTRAS=0
SERVICES=1
CHANGE_SHELL=1
ENABLE_GREETD=0
KEEP_MONITORS=0
VM=auto
DOCTOR=0
RESTORE=""
WORK_DIR=""
BACKUP_DIR=""
WARNINGS=()
FAILED_AUR=()
FAILED_EXTRAS=()

usage() {
    cat <<'EOF'
Usage: ./install.sh [options]

Default: full desktop + applications from this computer's package snapshot.

  --compositor NAME  niri (default) or hyprland; prefer the named entrypoints.
  --full             Full installation (default).
  --desktop-only     Selected compositor, Noctalia, shell and desktop tools.
  --vm               VM mode: automatic monitors, no automatic guest suspend.
  --hardware         Keep Noctalia's original idle/suspend behavior.
  --keep-monitors    Restore the original niri and HyprMod monitor layout.
  --enable-greetd    Install/configure/enable tuigreet for the next boot.
  --skip-aur         Skip AUR applications; desktop and bundled shell still work.
  --skip-extras      Skip Git/Python tools and Flatpak applications.
  --skip-packages    Deploy configs only; require existing desktop dependencies.
  --no-services      Do not enable system/user services or write system config.
  --no-chsh          Do not change the account's login shell.
  --dry-run          Print packages and file destinations; change nothing.
  --doctor           Check an installed setup; change nothing.
  --restore PATH     Restore dotfiles from an installer backup.
  -h, --help         Show help.

Examples:
  ./install-niri.sh --vm --enable-greetd
  ./install-hyprland.sh --vm --enable-greetd
  ./install-hyprland.sh --vm --desktop-only --enable-greetd
  ./install.sh --dry-run
  ./install.sh --doctor
EOF
}

while (($#)); do
    case "$1" in
        --compositor)
            (($# >= 2)) || { printf '%s\n' 'Missing compositor name.' >&2; exit 2; }
            COMPOSITOR="$2"; shift ;;
        --full) PROFILE=full ;;
        --desktop-only) PROFILE=desktop ;;
        --vm) VM=1 ;;
        --hardware) VM=0 ;;
        --keep-monitors) KEEP_MONITORS=1 ;;
        --enable-greetd) ENABLE_GREETD=1 ;;
        --skip-aur) SKIP_AUR=1 ;;
        --skip-extras) SKIP_EXTRAS=1 ;;
        --skip-packages) SKIP_PACKAGES=1 ;;
        --no-services) SERVICES=0 ;;
        --no-chsh) CHANGE_SHELL=0 ;;
        --dry-run) DRY_RUN=1 ;;
        --doctor) DOCTOR=1 ;;
        --restore)
            (($# >= 2)) || { printf '%s\n' 'Missing backup path.' >&2; exit 2; }
            RESTORE="$2"; shift ;;
        -h|--help) usage; exit 0 ;;
        *) printf 'Unknown option: %s\n' "$1" >&2; usage; exit 2 ;;
    esac
    shift
done

case "$COMPOSITOR" in
    niri)
        SESSION_COMMAND=niri-session
        COMPOSITOR_COMMANDS=(niri niri-session)
        COMPOSITOR_CONFIG="$CONFIG_ROOT/niri/config.kdl"
        ;;
    hyprland)
        SESSION_COMMAND='uwsm start -e -D Hyprland hyprland.desktop'
        COMPOSITOR_COMMANDS=(Hyprland start-hyprland uwsm)
        COMPOSITOR_CONFIG="$CONFIG_ROOT/hypr/hyprland.lua"
        ;;
    *) printf 'Unsupported compositor: %s\n' "$COMPOSITOR" >&2; exit 2 ;;
esac
COMMON_COMMANDS=(noctalia zsh kitty foot fuzzel rofi yazi nmcli wpctl wl-copy)
GIT_TOOLS_FILE="$BUNDLE_DIR/packages/$COMPOSITOR-git-tools.tsv"

say() { printf '\n==> %s\n' "$*"; }
warn() { WARNINGS+=("$*"); printf '[warning] %s\n' "$*" >&2; }
die() { printf '[error] %s\n' "$*" >&2; exit 1; }
have() { command -v "$1" >/dev/null 2>&1; }
cleanup() { [[ -z "$WORK_DIR" ]] || rm -rf -- "$WORK_DIR"; }
trap cleanup EXIT
trap 'printf "[error] Installation stopped at line %s. Read the log above.\n" "$LINENO" >&2' ERR

read_packages() {
    local file line
    for file in "$@"; do
        [[ -f "$file" ]] || die "Missing package manifest: $file"
        while IFS= read -r line || [[ -n "$line" ]]; do
            [[ -z "$line" || "$line" == \#* ]] && continue
            [[ "$line" =~ ^[a-z0-9@._+-]+$ ]] || die "Invalid package name in $file: $line"
            printf '%s\n' "$line"
        done < "$file"
    done
}

doctor() {
    local failures=0 cmd
    for cmd in "${COMPOSITOR_COMMANDS[@]}" "${COMMON_COMMANDS[@]}" ddcutil; do
        if have "$cmd"; then printf '[OK] %s\n' "$cmd";
        else printf '[MISSING] %s\n' "$cmd"; failures=$((failures + 1)); fi
    done
    if [[ "$COMPOSITOR" == niri ]] && have niri; then
        niri validate --config "$COMPOSITOR_CONFIG" || failures=$((failures + 1))
    elif [[ "$COMPOSITOR" == hyprland ]] && have Hyprland; then
        Hyprland --verify-config -c "$COMPOSITOR_CONFIG" || failures=$((failures + 1))
    fi
    if have noctalia; then noctalia config validate || failures=$((failures + 1)); fi
    if have zsh; then
        zsh -n "$HOME/.zshrc" || failures=$((failures + 1))
        zsh -n "$HOME/.p10k.zsh" || failures=$((failures + 1))
    fi
    for cmd in "$HOME/.oh-my-zsh/oh-my-zsh.sh" \
        "$HOME/.oh-my-zsh/custom/themes/powerlevel10k/powerlevel10k.zsh-theme" \
        "$HOME/.oh-my-zsh/custom/plugins/zsh-autosuggestions/zsh-autosuggestions.plugin.zsh" \
        "$HOME/.oh-my-zsh/custom/plugins/zsh-syntax-highlighting/zsh-syntax-highlighting.zsh" \
        "$STATE_ROOT/noctalia/settings.toml" "$COMPOSITOR_CONFIG"; do
        if [[ -f "$cmd" ]]; then printf '[OK] %s\n' "$cmd";
        else printf '[MISSING] %s\n' "$cmd"; failures=$((failures + 1)); fi
    done
    if [[ "$COMPOSITOR" == hyprland ]]; then
        if [[ -x "$DATA_ROOT/dotfiles/tools/hyprmod/bin/python" ]]; then
            "$DATA_ROOT/dotfiles/tools/hyprmod/bin/python" -c 'import gi, cairo, hyprmod' || failures=$((failures + 1))
        else
            printf '[MISSING] HyprMod isolated environment\n'
            failures=$((failures + 1))
        fi
    fi
    if have systemctl; then
        systemctl --user --no-pager --failed || true
        systemctl --no-pager --failed || true
    fi
    printf '\nMissing or invalid required components: %s\n' "$failures"
    ((failures == 0))
}

(( ! DOCTOR )) || { doctor; exit $?; }
[[ -f "$BUNDLE_DIR/manifest.json" && -f "$BUNDLE_DIR/lib/deploy.py" ]] || die 'Copy the complete dotfiles bundle, including lib/ and payload-archives/, not install.sh alone.'
if ((! DRY_RUN)); then
    [[ $EUID -ne 0 ]] || die 'Run as your normal user, not through sudo.'
    [[ "$(uname -m)" == x86_64 ]] || die 'This snapshot targets x86_64 Arch Linux.'
    [[ -r /etc/os-release ]] || die 'Cannot identify the operating system.'
    OS_ID="$(sed -n 's/^ID=//p' /etc/os-release | tr -d '\"')"
    [[ "$OS_ID" == arch ]] || die 'This installer targets Arch Linux.'
fi
have python3 || {
    if ((DRY_RUN)); then die 'python3 is needed to validate/print the deployment plan.'; fi
    [[ $EUID -ne 0 ]] || die 'Run as a normal user, not root.'
    have sudo && have pacman || die 'Install python and sudo on Arch Linux first.'
    # Refresh and upgrade together: never perform an Arch partial upgrade.
    sudo pacman -Syu --needed python
}

if [[ -n "$RESTORE" ]]; then
    (( ! DRY_RUN )) || die '--restore and --dry-run cannot be combined.'
    [[ $EUID -ne 0 ]] || die 'Restore as the user who installed these dotfiles.'
    python3 "$BUNDLE_DIR/lib/deploy.py" restore --backup "$RESTORE"
    printf '%s\n' 'Packages, services, /etc changes and login shell are retained. See README.md.'
    exit 0
fi

CATALOG_ARGS=()
if [[ ! -d "$BUNDLE_DIR/payload" ]]; then
    [[ -f "$BUNDLE_DIR/lib/payload.py" && -f "$BUNDLE_DIR/payload-archives/manifest.json" ]] || die 'Missing payload. Copy every payload-archives/ part and its manifest.json.'
    if ((DRY_RUN)); then
        # Verify uploaded parts without extracting anything or changing files.
        python3 "$BUNDLE_DIR/lib/payload.py" check --bundle "$BUNDLE_DIR"
        CATALOG_ARGS=(--catalog-only)
    else
        say 'Verifying and extracting the archived payload before installation'
        WORK_DIR="$(mktemp -d "${TMPDIR:-/tmp}/dotfiles-install.XXXXXXXX")"
        DEPLOY_BUNDLE="$WORK_DIR/archive-bundle"
        python3 "$BUNDLE_DIR/lib/payload.py" extract --bundle "$BUNDLE_DIR" --destination "$DEPLOY_BUNDLE"
        cp -- "$BUNDLE_DIR/manifest.json" "$DEPLOY_BUNDLE/manifest.json"
    fi
fi
python3 "$BUNDLE_DIR/lib/deploy.py" check --bundle "$DEPLOY_BUNDLE" --compositor "$COMPOSITOR" "${CATALOG_ARGS[@]}"
if [[ "$VM" == auto ]]; then
    VM=0
    if have systemd-detect-virt && systemd-detect-virt --quiet; then VM=1; fi
fi
(( ! ENABLE_GREETD || SERVICES )) || die '--enable-greetd cannot be combined with --no-services.'
(( ! ENABLE_GREETD || ! SKIP_PACKAGES )) || die '--enable-greetd requires package installation.'

OFFICIAL_FILES=("$BUNDLE_DIR/packages/desktop.txt" "$BUNDLE_DIR/packages/$COMPOSITOR.txt")
AUR_FILES=("$BUNDLE_DIR/packages/desktop-aur.txt")
if [[ "$PROFILE" == full ]]; then
    OFFICIAL_FILES+=("$BUNDLE_DIR/packages/full.txt")
    AUR_FILES+=("$BUNDLE_DIR/packages/full-aur.txt")
    AUR_FILES+=("$BUNDLE_DIR/packages/$COMPOSITOR-aur.txt")
fi
OFFICIAL_OUTPUT="$(read_packages "${OFFICIAL_FILES[@]}" | sort -u)"
AUR_OUTPUT="$(read_packages "${AUR_FILES[@]}" | sort -u)"
mapfile -t OFFICIAL_PACKAGES <<< "$OFFICIAL_OUTPUT"
AUR_PACKAGES=()
[[ -z "$AUR_OUTPUT" ]] || mapfile -t AUR_PACKAGES <<< "$AUR_OUTPUT"
if ((ENABLE_GREETD)); then OFFICIAL_PACKAGES+=(greetd greetd-tuigreet); fi

say "Compositor: $COMPOSITOR; profile: $PROFILE; virtual machine: $VM"
if ((DRY_RUN)); then
    if ((! SKIP_PACKAGES)); then
        printf '\nOfficial packages:\n'; printf '  %s\n' "${OFFICIAL_PACKAGES[@]}"
        if ((! SKIP_AUR)) && ((${#AUR_PACKAGES[@]})); then
            printf '\nAUR packages:\n'; printf '  %s\n' "${AUR_PACKAGES[@]}"
        fi
        if ((! SKIP_EXTRAS)); then
            printf '\nGit tools for %s:\n' "$COMPOSITOR"; cat "$GIT_TOOLS_FILE"
        fi
        if [[ "$PROFILE" == full ]] && ((! SKIP_EXTRAS)); then
            printf '\nPython tools:\n'; cat "$BUNDLE_DIR/packages/python-tools.txt"
            printf '\nPython libraries (isolated environment):\n'; cat "$BUNDLE_DIR/packages/python-libs.txt"
            printf '\nFlatpak applications:\n'; cat "$BUNDLE_DIR/packages/flatpak-apps.txt"
        fi
    fi
    printf '\nDeployment destinations (existing paths will be backed up):\n'
    python3 "$BUNDLE_DIR/lib/deploy.py" show --bundle "$DEPLOY_BUNDLE" --compositor "$COMPOSITOR" "${CATALOG_ARGS[@]}"
    printf '\nServices: %s; change shell: %s; configure greetd: %s\n' "$SERVICES" "$CHANGE_SHELL" "$ENABLE_GREETD"
    printf 'Default session: %s\n' "$SESSION_COMMAND"
    exit 0
fi

[[ $EUID -ne 0 ]] || die 'Run as your normal user, not through sudo.'
[[ "$(uname -m)" == x86_64 ]] || die 'This snapshot targets x86_64 Arch Linux.'
[[ -r /etc/os-release ]] || die 'Cannot identify the operating system.'
OS_ID="$(sed -n 's/^ID=//p' /etc/os-release | tr -d '\"')"
[[ "$OS_ID" == arch ]] || die 'This installer targets Arch Linux.'
have pacman && have sudo && have systemctl || die 'pacman, sudo and systemd are required.'
[[ "$HOME" != / && "$HOME" == /* ]] || die 'Invalid HOME.'
sudo -v

mkdir -p -- "$STATE_ROOT/dotfiles/logs"
STAMP="$(date +%Y%m%d-%H%M%S)-$$"
LOG_FILE="$STATE_ROOT/dotfiles/logs/install-$COMPOSITOR-$STAMP.log"
exec > >(tee -a "$LOG_FILE") 2>&1
[[ -n "$WORK_DIR" ]] || WORK_DIR="$(mktemp -d "${TMPDIR:-/tmp}/dotfiles-install.XXXXXXXX")"
BACKUP_DIR="$STATE_ROOT/dotfiles/backups/$STAMP"

if ((! SKIP_PACKAGES)); then
    # Steam/Wine from the full snapshot need the official multilib repository.
    if [[ "$PROFILE" == full ]] && ! pacman-conf --repo-list | grep -qx multilib; then
        say 'Enabling the official multilib repository'
        sudo cp -a -- /etc/pacman.conf "/etc/pacman.conf.dotfiles-$STAMP.bak"
        printf '\n[multilib]\nInclude = /etc/pacman.d/mirrorlist\n' | sudo tee -a /etc/pacman.conf >/dev/null
    fi
    say 'Updating Arch and installing desktop prerequisites'
    sudo pacman -Syu --needed bash coreutils base-devel git python zsh ripgrep
    # Check against refreshed databases; an unavailable core package is fatal.
    for pkg in "${OFFICIAL_PACKAGES[@]}"; do
        pacman -Si "$pkg" >/dev/null 2>&1 || die "Official package unavailable: $pkg (see packages/*.txt)."
    done
    say 'Installing official packages'
    sudo pacman -S --needed "${OFFICIAL_PACKAGES[@]}"
    if ((! SKIP_AUR)) && ((${#AUR_PACKAGES[@]})); then
        AUR_HELPER=""
        if have paru; then AUR_HELPER=paru;
        elif have yay; then AUR_HELPER=yay;
        else
            say 'Building yay as the normal user'
            git clone --depth=1 https://aur.archlinux.org/yay.git "$WORK_DIR/yay"
            (cd "$WORK_DIR/yay" && makepkg -si)
            AUR_HELPER=yay
        fi
        say 'Installing AUR applications (package manager confirmations remain enabled)'
        # A retired AUR application must not prevent the rest of the desktop.
        # Still return a failure status at the end if the full profile is incomplete.
        for pkg in "${AUR_PACKAGES[@]}"; do
            if ! "$AUR_HELPER" -S --needed "$pkg"; then
                FAILED_AUR+=("$pkg")
                warn "AUR application failed: $pkg. Continuing with the remaining setup."
            fi
        done
    elif ((SKIP_AUR)); then
        warn 'AUR applications were skipped. The desktop and bundled shell do not need AUR.'
    fi
fi

install_git_tools() {
    local name source tool_dir current_python tool_python
    current_python="$(python3 -c 'import sys; print(f"{sys.version_info.major}.{sys.version_info.minor}")')"
    while IFS=$'\t' read -r name source || [[ -n "$name" ]]; do
        [[ -z "$name" || "$name" == \#* ]] && continue
        [[ "$name" =~ ^[a-z0-9_-]+$ && "$source" =~ ^git\+https://github\.com/[A-Za-z0-9._-]+/[A-Za-z0-9._-]+\.git@[a-f0-9]{40}$ ]] || die 'Invalid Git tool manifest entry.'
        tool_dir="$DATA_ROOT/dotfiles/tools/$name"
        if [[ -d "$tool_dir" ]]; then
            tool_python="$("$tool_dir/bin/python" -c 'import sys; print(f"{sys.version_info.major}.{sys.version_info.minor}")' 2>/dev/null || true)"
            if [[ "$tool_python" != "$current_python" ]]; then
                mkdir -p -- "$STATE_ROOT/dotfiles/tool-backups/$STAMP" || return 1
                mv -- "$tool_dir" "$STATE_ROOT/dotfiles/tool-backups/$STAMP/$name" || return 1
            fi
        fi
        if [[ ! -d "$tool_dir" ]]; then
            mkdir -p -- "$(dirname -- "$tool_dir")" || return 1
            uv venv --python /usr/bin/python --system-site-packages "$tool_dir" || return 1
        fi
        uv pip install --python "$tool_dir/bin/python" "$source" || return 1
        "$tool_dir/bin/python" -c 'import gi, cairo, hyprmod' || return 1
    done < "$GIT_TOOLS_FILE"
}

install_python_libraries() {
    local env_path="$DATA_ROOT/dotfiles/python" current_python env_python requirement
    current_python="$(python3 -c 'import sys; print(f"{sys.version_info.major}.{sys.version_info.minor}")')"
    if [[ -d "$env_path" ]]; then
        env_python="$("$env_path/bin/python" -c 'import sys; print(f"{sys.version_info.major}.{sys.version_info.minor}")' 2>/dev/null || true)"
        if [[ "$env_python" != "$current_python" ]]; then
            mkdir -p -- "$STATE_ROOT/dotfiles/tool-backups/$STAMP" || return 1
            mv -- "$env_path" "$STATE_ROOT/dotfiles/tool-backups/$STAMP/python" || return 1
        fi
    fi
    while IFS= read -r requirement || [[ -n "$requirement" ]]; do
        [[ -z "$requirement" || "$requirement" == \#* ]] && continue
        [[ "$requirement" =~ ^[A-Za-z0-9._+-]+(\[[A-Za-z0-9,._-]+\])?$ ]] || die 'Invalid Python library requirement.'
    done < "$BUNDLE_DIR/packages/python-libs.txt"
    if [[ ! -d "$env_path" ]]; then
        mkdir -p -- "$(dirname -- "$env_path")" || return 1
        # Tk is supplied by Arch's Python/tk; user packages stay inside this venv.
        uv venv --python /usr/bin/python "$env_path" || return 1
    fi
    uv pip install --python "$env_path/bin/python" -r "$BUNDLE_DIR/packages/python-libs.txt" || return 1
    "$env_path/bin/python" -c 'import tkinter, yt_dlp' || return 1
}

if ((! SKIP_PACKAGES && ! SKIP_EXTRAS)); then
    say "Installing pinned Git tools for $COMPOSITOR"
    if ! install_git_tools; then
        FAILED_EXTRAS+=(git-tools)
        warn "A Git tool could not be installed; see the log and $GIT_TOOLS_FILE."
    fi
fi

if [[ "$PROFILE" == full ]] && ((! SKIP_PACKAGES && ! SKIP_EXTRAS)); then
    say 'Installing additional Python command-line tools'
    while IFS= read -r requirement || [[ -n "$requirement" ]]; do
        [[ -z "$requirement" || "$requirement" == \#* ]] && continue
        [[ "$requirement" =~ ^[A-Za-z0-9._+-]+(\[[A-Za-z0-9,._-]+\])?$ ]] || die 'Invalid Python tool requirement.'
        if ! uv tool install --python /usr/bin/python "$requirement"; then
            FAILED_EXTRAS+=("python:$requirement")
            warn "Could not install Python tool: $requirement. Existing unrelated commands are retained."
        fi
    done < "$BUNDLE_DIR/packages/python-tools.txt"
    say 'Restoring user Python libraries in an isolated environment'
    if ! install_python_libraries; then
        FAILED_EXTRAS+=(python-libraries)
        warn 'Could not prepare the dotfiles-python/Kecheenok environment.'
    fi
    say 'Restoring Flatpak applications from Flathub'
    if flatpak remote-add --user --if-not-exists flathub https://dl.flathub.org/repo/flathub.flatpakrepo; then
        while IFS= read -r app || [[ -n "$app" ]]; do
            [[ -z "$app" || "$app" == \#* ]] && continue
            [[ "$app" =~ ^[A-Za-z0-9_-]+(\.[A-Za-z0-9_-]+)+$ ]] || die 'Invalid Flatpak application ID.'
            if ! flatpak install --user flathub "$app"; then
                FAILED_EXTRAS+=("flatpak:$app")
                warn "Could not install Flatpak application: $app."
            fi
        done < "$BUNDLE_DIR/packages/flatpak-apps.txt"
    else
        FAILED_EXTRAS+=(flathub)
        warn 'Could not configure the user Flathub remote.'
    fi
fi

for cmd in "${COMPOSITOR_COMMANDS[@]}" "${COMMON_COMMANDS[@]}"; do
    have "$cmd" || die "Required program missing: $cmd"
done
say 'Preparing portable configuration and validating it before deployment'
PREPARE_ARGS=(prepare --bundle "$DEPLOY_BUNDLE" --stage "$WORK_DIR/stage" --compositor "$COMPOSITOR")
(( ! KEEP_MONITORS )) || PREPARE_ARGS+=(--keep-monitors)
(( ! VM )) || PREPARE_ARGS+=(--vm)
python3 "$BUNDLE_DIR/lib/deploy.py" "${PREPARE_ARGS[@]}"
if [[ "$COMPOSITOR" == niri ]]; then
    niri validate --config "$WORK_DIR/stage/config/niri/config.kdl"
else
    Hyprland --verify-config -c "$WORK_DIR/stage/config/hypr/hyprland.lua"
fi
noctalia config validate "$WORK_DIR/stage/state/noctalia/settings.toml"
zsh -n "$WORK_DIR/stage/home/.zshrc"
zsh -n "$WORK_DIR/stage/home/.zprofile"
zsh -n "$WORK_DIR/stage/home/.p10k.zsh"
say 'Backing up and deploying dotfiles'
python3 "$BUNDLE_DIR/lib/deploy.py" deploy --bundle "$DEPLOY_BUNDLE" --stage "$WORK_DIR/stage" --backup "$BACKUP_DIR" --compositor "$COMPOSITOR"
mkdir -p -- "$HOME/Pictures/Screenshots" "$CACHE_ROOT/zsh" "$DATA_ROOT/zsh"
xdg-user-dirs-update
if have update-desktop-database; then update-desktop-database "$DATA_ROOT/applications"; fi
chmod 600 -- "$STATE_ROOT/noctalia/settings.toml"
fc-cache -f
if have bat; then bat cache --build; fi

backup_system_file() {
    local path="$1"
    if sudo test -e "$path"; then
        sudo mkdir -p -- "$BACKUP_DIR/system$(dirname -- "$path")"
        sudo cp -a -- "$path" "$BACKUP_DIR/system$path"
    fi
}

if ((SERVICES)); then
    say 'Configuring desktop services'
    systemctl list-unit-files --state=enabled --no-pager > "$BACKUP_DIR/system-services-before.txt"
    systemctl --user list-unit-files --state=enabled --no-pager > "$BACKUP_DIR/user-services-before.txt" || true
    # Do not disconnect the installer: switch a networkd-managed guest at reboot.
    if systemctl is-active --quiet systemd-networkd.service || systemctl is-enabled --quiet systemd-networkd.service; then
        sudo systemctl disable systemd-networkd.service systemd-networkd.socket systemd-networkd-wait-online.service
        sudo systemctl enable NetworkManager.service
        warn 'systemd-networkd is still running; NetworkManager will take over after reboot.'
    else
        sudo systemctl enable --now NetworkManager.service
    fi
    for service in bluetooth.service power-profiles-daemon.service systemd-timesyncd.service; do
        if ! sudo systemctl enable --now "$service"; then warn "Could not activate $service; check VM/hardware support."; fi
    done
    # A target already using the resolved stub needs its resolver running.
    case "$(readlink -f /etc/resolv.conf || true)" in
        /run/systemd/resolve/stub-resolv.conf|/run/systemd/resolve/resolv.conf)
            sudo systemctl enable --now systemd-resolved.service ;;
    esac
    sudo systemctl enable --now fstrim.timer
    # PipeWire's sockets start audio when an application first uses it.
    if ! systemctl --user enable --now pipewire.socket pipewire-pulse.socket wireplumber.service; then
        warn 'User audio services need a new login; check with --doctor after reboot.'
    fi
    if [[ "$PROFILE" == full ]] && ((! SKIP_PACKAGES)); then
        # These were enabled on the source computer. Start them at next boot.
        sudo systemctl enable cups.service avahi-daemon.service libvirtd.service
        if ! sudo test -e /etc/systemd/zram-generator.conf && ! sudo test -d /etc/systemd/zram-generator.conf.d; then
            printf '[zram0]\ncompression-algorithm = zstd\n' | sudo tee /etc/systemd/zram-generator.conf >/dev/null
            sudo systemctl daemon-reload
        fi
    fi
    sudo install -d -m 0755 /etc/modules-load.d
    backup_system_file /etc/modules-load.d/dotfiles-ddc.conf
    printf 'i2c-dev\n' | sudo tee /etc/modules-load.d/dotfiles-ddc.conf >/dev/null
    if ! sudo modprobe i2c-dev; then warn 'i2c-dev unavailable; external-monitor DDC/CI may require hardware support.'; fi
    if have gsettings; then
        gsettings set org.gnome.desktop.interface color-scheme prefer-dark || warn 'GNOME dark preference will need a graphical user session.'
        gsettings set org.gnome.desktop.interface gtk-theme adw-gtk3-dark || true
        gsettings set org.gnome.desktop.interface icon-theme Tela-black-dark || true
        gsettings set org.gnome.desktop.interface cursor-theme volantes_cursors || true
    fi
    # ddcutil's packaged uaccess rules apply to the newly loaded i2c module.
    sudo udevadm trigger --subsystem-match=i2c-dev || warn 'DDC device permissions need a reboot.'
fi

if ((CHANGE_SHELL)); then
    ZSH_BIN="$(command -v zsh)"
    grep -Fxq -- "$ZSH_BIN" /etc/shells || die "Zsh is not listed in /etc/shells: $ZSH_BIN"
    CURRENT_SHELL="$(getent passwd "$(id -un)" | cut -d: -f7)"
    printf '%s\n' "$CURRENT_SHELL" > "$BACKUP_DIR/login-shell-before.txt"
    if [[ "$CURRENT_SHELL" != "$ZSH_BIN" ]]; then
        sudo chsh -s "$ZSH_BIN" "$(id -un)"
    fi
fi

if ((ENABLE_GREETD)); then
    say 'Configuring greetd + tuigreet for the next boot'
    backup_system_file /etc/greetd/config.toml
    sudo install -d -m 0755 /etc/greetd
    sudo tee /etc/greetd/config.toml >/dev/null <<EOF
[terminal]
vt = 1

[default_session]
command = "tuigreet --time --remember --remember-session --sessions /usr/share/wayland-sessions --cmd '$SESSION_COMMAND'"
user = "greeter"
EOF
    if [[ -L /etc/systemd/system/display-manager.service ]]; then
        PREVIOUS_DM="$(basename -- "$(readlink /etc/systemd/system/display-manager.service)")"
        printf '%s\n' "$PREVIOUS_DM" > "$BACKUP_DIR/display-manager-before.txt"
        if [[ "$PREVIOUS_DM" != greetd.service ]]; then sudo systemctl disable "$PREVIOUS_DM"; fi
    fi
    # Leave the active desktop running. No reboot/logout/DM restart here.
    sudo systemctl enable --force greetd.service
fi

say 'Checking the installed configuration'
if [[ "$COMPOSITOR" == niri ]]; then
    niri validate --config "$COMPOSITOR_CONFIG"
else
    Hyprland --verify-config -c "$COMPOSITOR_CONFIG"
fi
noctalia config validate
zsh -n "$HOME/.zshrc"
if ((${#FAILED_AUR[@]} + ${#FAILED_EXTRAS[@]})); then
    say 'Desktop installed; application profile is incomplete'
else
    say 'Installation complete'
fi
printf 'Compositor: %s\nProfile: %s\nBackup: %s\nLog: %s\n' "$COMPOSITOR" "$PROFILE" "$BACKUP_DIR" "$LOG_FILE"
printf 'Log out/reboot and select %s, or run from a TTY: %s\n' "$COMPOSITOR" "$SESSION_COMMAND"
if [[ "$COMPOSITOR" == niri ]]; then
    printf '%s\n' 'Super+T: Foot/Zsh | Super+S: Kitty/Yazi | Super+Space: Fuzzel | Super+I: Noctalia settings'
else
    printf '%s\n' 'Super+T: Kitty/Zsh | Super+S: Kitty/Yazi | Super+Space: Noctalia launcher | Super+I: Noctalia settings'
fi
if ((${#WARNINGS[@]})); then printf '\nItems to check:\n'; printf '  - %s\n' "${WARNINGS[@]}"; fi
if ((${#FAILED_AUR[@]})); then
    printf '\nFailed AUR applications:\n'; printf '  %s\n' "${FAILED_AUR[@]}"
    printf '%s\n' 'Fix/remove the affected entries in packages/full-aur.txt and run again.'
fi
if ((${#FAILED_EXTRAS[@]})); then
    printf '\nFailed Git/Python/Flatpak components:\n'; printf '  %s\n' "${FAILED_EXTRAS[@]}"
fi
if ((${#FAILED_AUR[@]} + ${#FAILED_EXTRAS[@]})); then exit 2; fi
