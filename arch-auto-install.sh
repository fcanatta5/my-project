#!/usr/bin/env bash
set -Eeuo pipefail

# Arch Auto Install v3.4.5-h1
# Hardening pass: defaults mais conservadores, validações mais rígidas
# e redução de riscos em cenários de dual boot.

VERSION="3.4.5-h1"
WORKDIR="/tmp/arch-auto-install-v3.4.5-h1"
LOG_DIR="$WORKDIR/logs"
RUNTIME_LOG="$LOG_DIR/runtime.log"
TARGET_ROOT="/mnt"
CONFIG_EXPORT="$WORKDIR/final-config.env"
SCAN_REPORT="$WORKDIR/storage-scan.txt"
CHECKPOINT_FILE="$WORKDIR/checkpoints.log"
ROLLBACK_PLAN="$WORKDIR/rollback-plan.sh"
PARTITION_TABLE_BACKUP="$WORKDIR/partition-table.sgdisk"
COMMAND_TRACE="$LOG_DIR/commands.log"

mkdir -p "$LOG_DIR"
touch "$RUNTIME_LOG" "$CHECKPOINT_FILE" "$ROLLBACK_PLAN" "$COMMAND_TRACE"
chmod 600 "$RUNTIME_LOG" "$CHECKPOINT_FILE" "$ROLLBACK_PLAN" "$COMMAND_TRACE"
exec > >(tee -a "$RUNTIME_LOG") 2>&1
PS4='+ [${BASH_SOURCE##*/}:${LINENO}] '
exec 19>>"$COMMAND_TRACE"
BASH_XTRACEFD=19

UI_BACKEND="plain"

HOSTNAME=""
USERNAME=""
FULLNAME=""
ROOT_PASSWORD=""
USER_PASSWORD=""

TIMEZONE="America/Sao_Paulo"
LOCALE="pt_BR.UTF-8"
KEYMAP="br-abnt2"

INSTALL_MODE=""
PROFILE=""
DESKTOP_VARIANT=""
DESKTOP_TIER=""
WINDOW_MANAGER=""
BOOTLOADER=""
DISPLAY_MANAGER_CHOICE=""

TARGET_DISK=""
EFI_PART=""
ROOT_PART=""
HOME_PART=""
SWAP_PART=""

USE_SWAP="yes"
SWAP_SIZE_GB="8"
AUTO_REBOOT="no"
ENABLE_BLUETOOTH="no"
ENABLE_PRINTING="no"
ENABLE_FIREWALL="yes"
ENABLE_SSH="no"
ENABLE_ZRAM="yes"
ENABLE_FLATPAK="no"
ENABLE_REFLECTOR="no"
ENABLE_FSTRIM="yes"
ENABLE_PACCACHE="yes"
INSTALL_PIKAUR="no"
INSTALL_MULTIMEDIA="no"
INSTALL_COMMON_APPS="no"
INSTALL_DEV_TOOLS="no"
INSTALL_GAMER_TOOLS="no"
INSTALL_FONTS="no"
INSTALL_BTRFS_ASSISTANT="no"

GPU_VENDOR="auto"
CPU_VENDOR="auto"
ROOT_FS_TYPE="ext4"
HOME_FS_TYPE=""
SEPARATE_HOME="no"
REFORMAT_ROOT="yes"
REFORMAT_HOME="no"
REFORMAT_EFI="no"

FONT_TIER=""
BROWSER_CHOICE="firefox"
EDITOR_CHOICE="vim"
TERMINAL_CHOICE=""
MULTILIB_REQUIRED="no"
USE_BTRFS_LAYOUT="no"

DUAL_BOOT_MODE="no"
PRESERVE_EXISTING_ESP="yes"

DETECTED_EXISTING_OSES=()
DETECTED_WINDOWS_PARTS=()
DETECTED_LINUX_PARTS=()
DETECTED_ESP_PARTS=()
SUGGESTED_DUALBOOT_ESP=""
SUGGESTED_TARGET_DISK=""
LIVE_MEDIA_DEVICE=""
WIFI_IFACE=""
WIFI_SSID_SELECTED=""
WIFI_CONNECTED="no"
WIFI_BACKEND_USED=""
WIFI_HIDDEN_NETWORK="no"
WIFI_PROFILE_NAME=""

VALIDATION_WARNINGS=()
ROLLBACK_ACTIONS=()
CURRENT_STAGE="startup"
DESTRUCTIVE_ACTIONS_STARTED="no"

PKGS_BASE=""
PKGS_KERNELS=""
PKGS_DESKTOP=""
PKGS_GAMER=""
PKGS_FONTS=""
PKGS_APPS=""
PKGS_SERVICES=""
PKGS_BOOT=""
PKGS_MULTIMEDIA=""
PKGS_DEV=""
PKGS_GPU=""
PKGS_EXTRA=""
DM_SERVICE=""
DM_PACKAGE=""

log() { printf "\n[%s] %s\n" "$(date +'%F %T')" "$*"; }
warn() { printf "\n[AVISO] %s\n" "$*" >&2; }
die() { printf "\n[ERRO] %s\n" "$*" >&2; exit 1; }

record_checkpoint() {
  local message="$1"
  printf '%s | %s | %s
' "$(date +'%F %T')" "$CURRENT_STAGE" "$message" | tee -a "$CHECKPOINT_FILE" >/dev/null
}

begin_stage() {
  CURRENT_STAGE="$1"
  log "==> Etapa: $CURRENT_STAGE"
  record_checkpoint "START"
}

register_rollback() {
  local action="$1"
  [[ -n "$action" ]] || return 0
  ROLLBACK_ACTIONS+=("$action")
  printf '%s
' "$action" >> "$ROLLBACK_PLAN"
}

run_rollbacks() {
  local i action
  (( ${#ROLLBACK_ACTIONS[@]} > 0 )) || return 0
  warn "Executando rollback de melhor esforço (${#ROLLBACK_ACTIONS[@]} ação(ões))..."
  for ((i=${#ROLLBACK_ACTIONS[@]}-1; i>=0; i--)); do
    action="${ROLLBACK_ACTIONS[$i]}"
    [[ -n "$action" ]] || continue
    warn "Rollback: $action"
    bash -lc "$action" >> "$RUNTIME_LOG" 2>&1 || warn "Rollback falhou: $action"
  done
}

on_error() {
  local line="$1" cmd="$2"
  warn "Falha na etapa '$CURRENT_STAGE', linha $line: $cmd"
  record_checkpoint "ERROR line=$line cmd=$cmd"
  if [[ "$DESTRUCTIVE_ACTIONS_STARTED" == "yes" ]]; then
    run_rollbacks
  fi
  warn "Revise os logs: $RUNTIME_LOG | $COMMAND_TRACE | $CHECKPOINT_FILE"
  exit 1
}

on_exit() {
  local rc=$?
  if (( rc == 0 )); then
    record_checkpoint "FINISH_OK"
    log "Finalizando instalador."
  else
    warn "Saindo com erro."
  fi
}
trap 'on_error "$LINENO" "$BASH_COMMAND"' ERR
trap 'on_exit' EXIT

detect_ui_backend() {
  if command -v gum >/dev/null 2>&1; then
    UI_BACKEND="gum"
  elif command -v dialog >/dev/null 2>&1; then
    UI_BACKEND="dialog"
  elif command -v whiptail >/dev/null 2>&1; then
    UI_BACKEND="whiptail"
  else
    UI_BACKEND="plain"
  fi
}

ensure_tui() {
  detect_ui_backend
  if [[ "$UI_BACKEND" == "plain" ]] && ping -c 1 -W 2 archlinux.org >/dev/null 2>&1; then
    log "Tentando instalar gum..."
    pacman -Sy --noconfirm gum >/dev/null 2>&1 || true
    detect_ui_backend
  fi
  log "Backend TUI: $UI_BACKEND"
}

ui_header() {
  local title="$1"
  case "$UI_BACKEND" in
    gum)
      gum style --border double --border-foreground 111 --foreground 230 --background 57 --padding "1 3" --margin "1 0" "$title"
      ;;
    *)
      echo
      echo "================================================================"
      echo "$title"
      echo "================================================================"
      ;;
  esac
}

ui_text() {
  local msg="$1"
  case "$UI_BACKEND" in
    gum) gum style --foreground 252 "$msg" ;;
    *) echo "$msg" ;;
  esac
}

ui_note() {
  local msg="$1"
  case "$UI_BACKEND" in
    gum) gum style --foreground 214 "$msg" ;;
    *) echo "$msg" ;;
  esac
}

ui_abort() {
  die "Operação cancelada pelo usuário."
}

ui_confirm() {
  local msg="$1"
  case "$UI_BACKEND" in
    gum) gum confirm "$msg" ;;
    dialog) dialog --stdout --yesno "$msg" 10 90 ;;
    whiptail) whiptail --yesno "$msg" 10 90 ;;
    *)
      local ans
      read -r -p "$msg [s/N]: " ans
      [[ "${ans,,}" =~ ^(s|sim|y|yes)$ ]]
      ;;
  esac
}

ui_input() {
  local prompt="$1" default="${2:-}" ans
  case "$UI_BACKEND" in
    gum)
      ans="$(gum input --prompt "$prompt: " --value "$default")" || ui_abort
      ;;
    dialog)
      ans="$(dialog --stdout --inputbox "$prompt" 10 90 "$default")" || ui_abort
      ;;
    whiptail)
      ans="$(whiptail --inputbox "$prompt" 10 90 "$default" 3>&1 1>&2 2>&3)" || ui_abort
      ;;
    *)
      read -r -p "$prompt [$default]: " ans || ui_abort
      ;;
  esac
  printf '%s' "${ans:-$default}"
}

ui_password() {
  local prompt="$1" a b
  while true; do
    case "$UI_BACKEND" in
      gum)
        a="$(gum input --password --prompt "$prompt: ")" || ui_abort
        b="$(gum input --password --prompt "Confirmar $prompt: ")" || ui_abort
        ;;
      dialog)
        a="$(dialog --stdout --insecure --passwordbox "$prompt" 10 90)" || ui_abort
        b="$(dialog --stdout --insecure --passwordbox "Confirmar $prompt" 10 90)" || ui_abort
        ;;
      whiptail)
        a="$(whiptail --passwordbox "$prompt" 10 90 3>&1 1>&2 2>&3)" || ui_abort
        b="$(whiptail --passwordbox "Confirmar $prompt" 10 90 3>&1 1>&2 2>&3)" || ui_abort
        ;;
      *)
        read -r -s -p "$prompt: " a || ui_abort; echo
        read -r -s -p "Confirmar $prompt: " b || ui_abort; echo
        ;;
    esac
    [[ -n "$a" && "$a" == "$b" ]] && { printf '%s' "$a"; return; }
    ui_note "As senhas não coincidem."
  done
}

ui_select_one() {
  local prompt="$1"; shift
  local options=("$@")
  local ch opt choice
  case "$UI_BACKEND" in
    gum)
      ch="$(printf '%s\n' "${options[@]}" | gum choose --header "$prompt")" || ui_abort
      printf '%s' "$ch"
      ;;
    dialog)
      local items=(); local i=1
      for opt in "${options[@]}"; do items+=("$i" "$opt"); ((i++)); done
      ch="$(dialog --stdout --menu "$prompt" 24 96 16 "${items[@]}")" || ui_abort
      [[ "$ch" =~ ^[0-9]+$ ]] || ui_abort
      printf '%s' "${options[$((ch-1))]}"
      ;;
    whiptail)
      local items=(); local i=1
      for opt in "${options[@]}"; do items+=("$i" "$opt"); ((i++)); done
      ch="$(whiptail --menu "$prompt" 24 96 16 "${items[@]}" 3>&1 1>&2 2>&3)" || ui_abort
      [[ "$ch" =~ ^[0-9]+$ ]] || ui_abort
      printf '%s' "${options[$((ch-1))]}"
      ;;
    *)
      echo "$prompt"
      local i=1
      for opt in "${options[@]}"; do echo "  $i) $opt"; ((i++)); done
      while true; do
        read -r -p "Escolha um número: " choice || ui_abort
        if [[ "$choice" =~ ^[0-9]+$ ]] && (( choice>=1 && choice<=${#options[@]} )); then
          printf '%s' "${options[$((choice-1))]}"
          return
        fi
      done
      ;;
  esac
}

need_cmd() { command -v "$1" >/dev/null 2>&1 || die "Falta o comando obrigatório: $1"; }
is_uefi() { [[ -d /sys/firmware/efi/efivars ]]; }
append_warning() { VALIDATION_WARNINGS+=("$1"); }
has_warning() { (( ${#VALIDATION_WARNINGS[@]} > 0 )); }
safe_umount_all() { swapoff -a >/dev/null 2>&1 || true; umount -R "$TARGET_ROOT" >/dev/null 2>&1 || true; }

is_yes() { [[ "${1:-}" == "yes" ]]; }
is_no() { [[ "${1:-}" == "no" ]]; }

prompt_default_yes() {
  local msg="$1"
  ui_confirm "$msg"
}

ui_confirm_typed() {
  local prompt="$1" expected="${2:-CONFIRMAR}" answer
  ui_header "Confirmação obrigatória"
  ui_note "$prompt"
  answer="$(ui_input "Digite $expected para continuar" "")"
  [[ "$answer" == "$expected" ]]
}

device_is_nvme_rotational() {
  local dev="$1" pkname="" rota=""
  pkname="$(lsblk -no PKNAME "$dev" 2>/dev/null || true)"
  [[ -n "$pkname" ]] || pkname="$(basename "$dev")"
  rota="$(cat "/sys/block/$pkname/queue/rotational" 2>/dev/null || echo 1)"
  [[ "$rota" == "0" ]]
}

btrfs_mount_opts_for() {
  local dev="$1"
  local opts="noatime,compress=zstd:3,space_cache=v2"
  if device_is_nvme_rotational "$dev"; then
    opts+=",ssd"
  fi
  printf '%s' "$opts"
}

is_known_windows_partition() {
  local part="$1" fstype partlabel parttype
  [[ -b "$part" ]] || return 1
  fstype="$(blkid -o value -s TYPE "$part" 2>/dev/null || true)"
  partlabel="$(blkid -o value -s PARTLABEL "$part" 2>/dev/null || true)"
  parttype="$(blkid -o value -s PART_ENTRY_TYPE "$part" 2>/dev/null || true)"
  [[ "$fstype" == "ntfs" || "$fstype" == "BitLocker" ]] && return 0
  [[ "$partlabel" =~ [Ww]indows|[Rr]ecovery|[Rr]eserved|[Mm]icrosoft ]] && return 0
  [[ "${parttype,,}" == "e3c9e316-0b5c-4db8-817d-f92df00215ae" ]] && return 0
  [[ "${parttype,,}" == "de94bba4-06d1-4d40-a16a-bfd50179d6ac" ]] && return 0
  return 1
}

is_known_linux_partition() {
  local part="$1" fstype
  [[ -b "$part" ]] || return 1
  fstype="$(blkid -o value -s TYPE "$part" 2>/dev/null || true)"
  [[ "$fstype" =~ ^(ext4|xfs|btrfs|f2fs)$ ]]
}

same_disk() {
  local a="$1" b="$2"
  [[ -n "$a" && -n "$b" ]] || return 1
  [[ "$(disk_from_part "$a")" == "$(disk_from_part "$b")" ]]
}

normalize_config() {
  case "$INSTALL_MODE" in
    auto-disco-inteiro|usar-particoes-existentes|dual-boot-assistido) ;;
    *) INSTALL_MODE="usar-particoes-existentes"; append_warning "Modo de instalação inválido foi ajustado para usar-particoes-existentes." ;;
  esac

  case "$PROFILE" in
    desktop|gamer|window-manager|minimal) ;;
    *) PROFILE="minimal"; append_warning "Perfil inválido foi ajustado para minimal." ;;
  esac

  case "$BOOTLOADER" in
    grub|systemd-boot) ;;
    *) BOOTLOADER="grub"; append_warning "Bootloader inválido foi ajustado para grub." ;;
  esac

  case "$GPU_VENDOR" in
    auto|nvidia|amd|intel|unknown) ;;
    *) GPU_VENDOR="auto"; append_warning "GPU vendor inválido foi ajustado para auto." ;;
  esac

  case "$CPU_VENDOR" in
    auto|amd|intel) ;;
    *) CPU_VENDOR="auto"; append_warning "CPU vendor inválido foi ajustado para auto." ;;
  esac

  case "$ROOT_FS_TYPE" in
    btrfs|ext4|xfs|'') ;;
    *) ROOT_FS_TYPE="ext4"; append_warning "Filesystem raiz inválido foi ajustado para ext4." ;;
  esac

  case "$BROWSER_CHOICE" in
    firefox|chromium|brave-via-aur|none) ;;
    *) BROWSER_CHOICE="firefox"; append_warning "Navegador inválido foi ajustado para firefox." ;;
  esac

  case "$EDITOR_CHOICE" in
    vim|nano) ;;
    *) EDITOR_CHOICE="vim"; append_warning "Editor inválido foi ajustado para vim." ;;
  esac

  case "$FONT_TIER" in
    full|balanced|developer|none|'') ;;
    *) FONT_TIER="balanced"; append_warning "Tier de fontes inválido foi ajustado para balanced." ;;
  esac

  for yn_var in USE_SWAP AUTO_REBOOT ENABLE_BLUETOOTH ENABLE_PRINTING ENABLE_FIREWALL ENABLE_SSH ENABLE_ZRAM ENABLE_FLATPAK ENABLE_REFLECTOR ENABLE_FSTRIM ENABLE_PACCACHE INSTALL_PIKAUR INSTALL_MULTIMEDIA INSTALL_COMMON_APPS INSTALL_DEV_TOOLS INSTALL_GAMER_TOOLS INSTALL_FONTS INSTALL_BTRFS_ASSISTANT SEPARATE_HOME REFORMAT_ROOT REFORMAT_HOME REFORMAT_EFI USE_BTRFS_LAYOUT DUAL_BOOT_MODE PRESERVE_EXISTING_ESP; do
    case "${!yn_var:-}" in
      yes|no) ;;
      *) printf -v "$yn_var" '%s' 'no'; append_warning "Opção $yn_var inválida foi ajustada para no." ;;
    esac
  done

  case "$PROFILE" in
    desktop|gamer)
      case "$DESKTOP_VARIANT" in kde|gnome|xfce) ;; *) DESKTOP_VARIANT="kde"; append_warning "Desktop inválido foi ajustado para kde." ;; esac
      case "$DESKTOP_TIER" in full|balanced) ;; *) DESKTOP_TIER="balanced"; append_warning "Tier desktop inválido foi ajustado para balanced." ;; esac
      WINDOW_MANAGER=""
      ;;
    window-manager)
      DESKTOP_VARIANT=""
      case "$WINDOW_MANAGER" in i3|sway|hyprland) ;; *) WINDOW_MANAGER="i3"; append_warning "WM inválido foi ajustado para i3." ;; esac
      DESKTOP_TIER="balanced"
      ;;
    minimal)
      DESKTOP_VARIANT=""
      WINDOW_MANAGER=""
      DESKTOP_TIER="balanced"
      DISPLAY_MANAGER_CHOICE="none"
      ;;
  esac

  case "$DESKTOP_VARIANT" in
    kde)
      case "$DISPLAY_MANAGER_CHOICE" in sddm|plasma-login-manager-se-disponivel) ;; *) DISPLAY_MANAGER_CHOICE="sddm"; append_warning "Display manager inválido para KDE; usando sddm." ;; esac
      ;;
    gnome) DISPLAY_MANAGER_CHOICE="gdm" ;;
    xfce)
      case "$DISPLAY_MANAGER_CHOICE" in lightdm|sddm) ;; *) DISPLAY_MANAGER_CHOICE="lightdm"; append_warning "Display manager inválido para XFCE; usando lightdm." ;; esac
      ;;
    *) DISPLAY_MANAGER_CHOICE="none" ;;
  esac

  if is_yes "$DUAL_BOOT_MODE"; then
    REFORMAT_EFI="no"
    PRESERVE_EXISTING_ESP="yes"
    [[ "$BOOTLOADER" == "grub" || "$BOOTLOADER" == "systemd-boot" ]] || BOOTLOADER="grub"
    [[ "$BROWSER_CHOICE" == "brave-via-aur" && "$INSTALL_PIKAUR" != "yes" ]] && BROWSER_CHOICE="firefox"
  fi

  if [[ "$BROWSER_CHOICE" == "brave-via-aur" ]] && [[ "$INSTALL_PIKAUR" != "yes" ]]; then
    append_warning "Brave via AUR requer pikaur; ajustando navegador para firefox."
    BROWSER_CHOICE="firefox"
  fi

  if [[ "$ROOT_FS_TYPE" == "btrfs" ]]; then
    USE_BTRFS_LAYOUT="yes"
  elif [[ -n "$ROOT_FS_TYPE" ]]; then
    USE_BTRFS_LAYOUT="no"
  fi

  [[ "$SWAP_SIZE_GB" =~ ^[1-9][0-9]*$ ]] || SWAP_SIZE_GB="8"
}

unmount_device_everywhere() {
  local dev="$1" target
  [[ -b "$dev" ]] || return 0
  while IFS= read -r target; do
    [[ -z "$target" ]] && continue
    umount "$target" >/dev/null 2>&1 || umount -l "$target" >/dev/null 2>&1 || true
  done < <(findmnt -rn -S "$dev" -o TARGET | awk '{print length, $0}' | sort -rn | cut -d" " -f2-)
}

release_selected_block_devices() {
  local dev
  safe_umount_all
  for dev in "$EFI_PART" "$ROOT_PART" "$HOME_PART" "$SWAP_PART"; do
    [[ -z "$dev" ]] && continue
    unmount_device_everywhere "$dev"
  done
  [[ -n "$TARGET_DISK" ]] && udevadm settle >/dev/null 2>&1 || true
}

assert_mount_source() {
  local target="$1" expected_source="$2" expected_fstype="${3:-}" actual_source actual_fstype
  actual_source="$(findmnt -no SOURCE "$target" 2>/dev/null || true)"
  [[ "$actual_source" == "$expected_source" ]] || die "Mount inconsistente em $target: esperado $expected_source, obtido ${actual_source:-nada}"
  if [[ -n "$expected_fstype" ]]; then
    actual_fstype="$(findmnt -no FSTYPE "$target" 2>/dev/null || true)"
    [[ "$actual_fstype" == "$expected_fstype" ]] || die "Filesystem inconsistente em $target: esperado $expected_fstype, obtido ${actual_fstype:-nada}"
  fi
}

save_partition_table_backup() {
  [[ -n "$TARGET_DISK" ]] || return 0
  [[ -b "$TARGET_DISK" ]] || return 0
  mkdir -p "$WORKDIR"
  if sgdisk --backup="$PARTITION_TABLE_BACKUP" "$TARGET_DISK" >/dev/null 2>&1; then
    log "Backup da tabela de partição salvo em $PARTITION_TABLE_BACKUP"
  else
    warn "Não foi possível salvar backup da tabela de partição de $TARGET_DISK"
  fi
}

partition_suffix() {
  if [[ "$1" =~ nvme|mmcblk ]]; then
    printf 'p'
  else
    printf ''
  fi
}

root_source_live_media() { findmnt -no SOURCE /run/archiso/bootmnt 2>/dev/null || true; }

disk_from_part() {
  lsblk -no PKNAME "$1" 2>/dev/null | sed 's#^#/dev/#'
}

is_removable_disk() {
  local disk="$1"
  local base
  base="$(basename "$disk")"
  [[ "$(cat "/sys/block/$base/removable" 2>/dev/null || echo 0)" == "1" ]]
}

cpu_microcode_pkg() {
  if [[ "$CPU_VENDOR" == "intel" ]]; then
    printf 'intel-ucode'
  elif [[ "$CPU_VENDOR" == "amd" ]]; then
    printf 'amd-ucode'
  elif grep -qi intel /proc/cpuinfo; then
    printf 'intel-ucode'
  elif grep -qi amd /proc/cpuinfo; then
    printf 'amd-ucode'
  fi
}

detect_gpu_vendor_auto() {
  if lspci | grep -Eqi 'NVIDIA|GeForce'; then
    printf 'nvidia'
  elif lspci | grep -Eqi 'AMD/ATI|Radeon'; then
    printf 'amd'
  elif lspci | grep -Eqi 'Intel Corporation UHD|Intel Corporation Iris|Intel Corporation Arc|VGA compatible controller: Intel'; then
    printf 'intel'
  else
    printf 'unknown'
  fi
}

package_available_live() {
  local pkg="$1"
  pacman -Si "$pkg" >/dev/null 2>&1
}

current_root_subvol_option() {
  local subvol_opt
  subvol_opt="$(findmnt -no OPTIONS / 2>/dev/null | tr ',' '
' | grep '^subvol=' | head -n1 || true)"
  printf '%s' "$subvol_opt"
}

is_btrfs_root_enabled() {
  [[ "$ROOT_FS_TYPE" == "btrfs" || "$USE_BTRFS_LAYOUT" == "yes" ]]
}

existing_user_groups_csv() {
  local groups=()
  local g
  for g in wheel audio video storage network lp; do
    getent group "$g" >/dev/null 2>&1 && groups+=("$g")
  done
  local IFS=,
  printf '%s' "${groups[*]}"
}

sanitize_pkg_list() {
  printf '%s\n' "$*" | tr ' ' '\n' | sed '/^$/d' | awk '!seen[$0]++' | xargs
}

wait_for_block_device() {
  local dev="$1" timeout="${2:-20}"
  local i
  for ((i=0; i<timeout; i++)); do
    [[ -b "$dev" ]] && return 0
    udevadm settle >/dev/null 2>&1 || true
    sleep 1
  done
  return 1
}

ensure_dir_mountpoint() {
  mkdir -p "$1"
}

mount_efi_partition() {
  ensure_dir_mountpoint "$TARGET_ROOT/boot"
  mountpoint -q "$TARGET_ROOT/boot" && return 0
  [[ -b "$EFI_PART" ]] || die "Partição EFI inválida para montagem: ${EFI_PART:-vazia}"
  mount "$EFI_PART" "$TARGET_ROOT/boot"
}


network_is_up() {
  ping -c 1 -W 2 archlinux.org >/dev/null 2>&1 || ping -c 1 -W 2 1.1.1.1 >/dev/null 2>&1
}

ensure_iwd_main_conf() {
  mkdir -p /etc/iwd
  if [[ ! -f /etc/iwd/main.conf ]] || ! grep -q '^EnableNetworkConfiguration=true' /etc/iwd/main.conf 2>/dev/null; then
    cat > /etc/iwd/main.conf <<IWDMAIN
[General]
EnableNetworkConfiguration=true
IWDMAIN
  fi
}

iwd_available() {
  command -v iwctl >/dev/null 2>&1 && systemctl list-unit-files | grep -q '^iwd\.service'
}

nm_available() {
  command -v nmcli >/dev/null 2>&1 && systemctl list-unit-files | grep -q '^NetworkManager\.service'
}

get_wifi_ifaces_iwd() {
  iwctl device list 2>/dev/null | awk 'NR>4 && NF>0 {print $1}' | sed '/^$/d'
}

get_wifi_ifaces_nm() {
  nmcli -t -f DEVICE,TYPE device 2>/dev/null | awk -F: '$2=="wifi"{print $1}'
}

wifi_scan_and_list_networks_iwd() {
  local iface="$1"
  iwctl station "$iface" scan >/dev/null 2>&1 || true
  sleep 3
  iwctl station "$iface" get-networks 2>/dev/null | sed '1,4d' | sed '/^\s*$/d'
}

parse_ssids_from_iwctl() {
  sed 's/\x1b\[[0-9;]*m//g' | awk '
    NF {
      line=$0
      gsub(/^[[:space:]>*]+/, "", line)
      sub(/[[:space:]]+(psk|open|8021x|wep|sae|eap|802\.1x).*/, "", line)
      sub(/[[:space:]]+[0-9]+[[:space:]]*[[:punct:][:graph:]]*$/, "", line)
      if (length(line) > 0) print line
    }' | awk '!seen[$0]++'
}

wifi_scan_and_list_networks_nm() {
  local iface="$1"
  nmcli device set "$iface" managed yes >/dev/null 2>&1 || true
  nmcli device wifi rescan ifname "$iface" >/dev/null 2>&1 || true
  sleep 3
  nmcli -t -f SSID,SIGNAL,SECURITY device wifi list ifname "$iface" 2>/dev/null | sed '/^:/d'
}

parse_ssids_from_nmcli() {
  awk -F: 'length($1)>0 {print $1}' | awk '!seen[$0]++'
}

connect_wifi_iwd() {
  local iface="$1" ssid="$2" pass="${3:-}"
  if [[ -n "$pass" ]]; then
    iwctl --passphrase "$pass" station "$iface" connect "$ssid"
  else
    iwctl station "$iface" connect "$ssid"
  fi
}

connect_wifi_nm() {
  local iface="$1" ssid="$2" pass="${3:-}" hidden="${4:-no}"
  if [[ "$hidden" == "yes" ]]; then
    if [[ -n "$pass" ]]; then
      nmcli device wifi connect "$ssid" password "$pass" hidden yes ifname "$iface"
    else
      nmcli device wifi connect "$ssid" hidden yes ifname "$iface"
    fi
  else
    if [[ -n "$pass" ]]; then
      nmcli device wifi connect "$ssid" password "$pass" ifname "$iface"
    else
      nmcli device wifi connect "$ssid" ifname "$iface"
    fi
  fi
}

choose_wifi_network_interactive_from_list() {
  local iface="$1" backend="$2" selected=""
  local raw
  local -a ssids_arr=()
  if [[ "$backend" == "iwd" ]]; then
    raw="$(wifi_scan_and_list_networks_iwd "$iface")"
    mapfile -t ssids_arr < <(printf '%s\n' "$raw" | parse_ssids_from_iwctl | sed '/^$/d')
  else
    raw="$(wifi_scan_and_list_networks_nm "$iface")"
    mapfile -t ssids_arr < <(printf '%s\n' "$raw" | parse_ssids_from_nmcli | sed '/^$/d')
  fi
  (( ${#ssids_arr[@]} > 0 )) || return 1
  selected="$(ui_select_one "Escolha a rede Wi‑Fi para conectar ($iface / $backend)" "${ssids_arr[@]}")"
  printf '%s' "$selected"
}

connect_with_retries() {
  local backend="$1" iface="$2" ssid="$3" pass="$4" hidden="$5"
  local tries=3 i
  for ((i=1; i<=tries; i++)); do
    ui_note "Tentativa de conexão $i/$tries em \"$ssid\" usando $backend..."
    if [[ "$backend" == "iwd" ]]; then
      connect_wifi_iwd "$iface" "$ssid" "$pass" >/dev/null 2>&1 || true
    else
      connect_wifi_nm "$iface" "$ssid" "$pass" "$hidden" >/dev/null 2>&1 || true
    fi
    sleep 4
    if network_is_up; then
      return 0
    fi
  done
  return 1
}

save_network_profile_hint() {
  local backend="$1" ssid="$2"
  WIFI_PROFILE_NAME="$ssid"
  WIFI_BACKEND_USED="$backend"
}

setup_wifi_via_iwd() {
  ui_note "Tentando configurar Wi‑Fi via iwd..."
  rfkill list || true
  rfkill unblock wlan || true
  rfkill unblock wifi || true
  ensure_iwd_main_conf
  systemctl restart iwd >/dev/null 2>&1 || true
  sleep 2

  local ifaces iface selected_ssid wifi_pass hidden_ssid
  mapfile -t ifaces < <(get_wifi_ifaces_iwd)
  (( ${#ifaces[@]} > 0 )) || return 1

  if (( ${#ifaces[@]} == 1 )); then
    iface="${ifaces[0]}"
  else
    iface="$(ui_select_one "Escolha a interface Wi‑Fi (iwd)" "${ifaces[@]}")"
  fi
  WIFI_IFACE="$iface"

  if ui_confirm "A rede Wi‑Fi é oculta?"; then
    WIFI_HIDDEN_NETWORK="yes"
    hidden_ssid="$(ui_input "Digite o SSID oculto")"
    selected_ssid="$hidden_ssid"
  else
    WIFI_HIDDEN_NETWORK="no"
    selected_ssid="$(choose_wifi_network_interactive_from_list "$iface" "iwd" || true)"
  fi

  [[ -n "$selected_ssid" ]] || return 1
  WIFI_SSID_SELECTED="$selected_ssid"

  if ui_confirm "A rede \"$selected_ssid\" exige senha?"; then
    wifi_pass="$(ui_password "Senha da rede Wi‑Fi")"
  else
    wifi_pass=""
  fi

  connect_with_retries "iwd" "$iface" "$selected_ssid" "$wifi_pass" "$WIFI_HIDDEN_NETWORK" || return 1
  WIFI_CONNECTED="yes"
  save_network_profile_hint "iwd" "$selected_ssid"
  return 0
}

setup_wifi_via_nm() {
  ui_note "Tentando configurar Wi‑Fi via NetworkManager..."
  rfkill list || true
  rfkill unblock wlan || true
  rfkill unblock wifi || true
  systemctl restart NetworkManager >/dev/null 2>&1 || true
  sleep 3

  local ifaces iface selected_ssid wifi_pass hidden_ssid
  mapfile -t ifaces < <(get_wifi_ifaces_nm)
  (( ${#ifaces[@]} > 0 )) || return 1

  if (( ${#ifaces[@]} == 1 )); then
    iface="${ifaces[0]}"
  else
    iface="$(ui_select_one "Escolha a interface Wi‑Fi (NetworkManager)" "${ifaces[@]}")"
  fi
  WIFI_IFACE="$iface"

  if ui_confirm "A rede Wi‑Fi é oculta?"; then
    WIFI_HIDDEN_NETWORK="yes"
    hidden_ssid="$(ui_input "Digite o SSID oculto")"
    selected_ssid="$hidden_ssid"
  else
    WIFI_HIDDEN_NETWORK="no"
    selected_ssid="$(choose_wifi_network_interactive_from_list "$iface" "nm" || true)"
  fi

  [[ -n "$selected_ssid" ]] || return 1
  WIFI_SSID_SELECTED="$selected_ssid"

  if ui_confirm "A rede \"$selected_ssid\" exige senha?"; then
    wifi_pass="$(ui_password "Senha da rede Wi‑Fi")"
  else
    wifi_pass=""
  fi

  connect_with_retries "nm" "$iface" "$selected_ssid" "$wifi_pass" "$WIFI_HIDDEN_NETWORK" || return 1
  WIFI_CONNECTED="yes"
  save_network_profile_hint "NetworkManager" "$selected_ssid"
  return 0
}

ensure_network_ready() {
  ui_header "Conectividade de rede"

  if network_is_up; then
    ui_text "Rede já está funcional. Vou seguir com a instalação."
    return 0
  fi

  ui_note "Sem conectividade confirmada. Vou tentar Wi‑Fi automaticamente."
  if iwd_available && setup_wifi_via_iwd; then
    ui_text "Conexão Wi‑Fi estabelecida via iwd."
    return 0
  fi

  if network_is_up; then
    return 0
  fi

  if nm_available && setup_wifi_via_nm; then
    ui_text "Conexão Wi‑Fi estabelecida via NetworkManager."
    return 0
  fi

  if network_is_up; then
    return 0
  fi

  append_warning "Não foi possível confirmar conectividade. A instalação pode falhar ao baixar pacotes."
  return 1
}

save_config() {
  cat > "$CONFIG_EXPORT" <<EOF
VERSION="$VERSION"
HOSTNAME="$HOSTNAME"
USERNAME="$USERNAME"
FULLNAME="$FULLNAME"
TIMEZONE="$TIMEZONE"
LOCALE="$LOCALE"
KEYMAP="$KEYMAP"
INSTALL_MODE="$INSTALL_MODE"
PROFILE="$PROFILE"
DESKTOP_VARIANT="$DESKTOP_VARIANT"
DESKTOP_TIER="$DESKTOP_TIER"
WINDOW_MANAGER="$WINDOW_MANAGER"
BOOTLOADER="$BOOTLOADER"
DISPLAY_MANAGER_CHOICE="$DISPLAY_MANAGER_CHOICE"
TARGET_DISK="$TARGET_DISK"
EFI_PART="$EFI_PART"
ROOT_PART="$ROOT_PART"
HOME_PART="$HOME_PART"
SWAP_PART="$SWAP_PART"
USE_SWAP="$USE_SWAP"
SWAP_SIZE_GB="$SWAP_SIZE_GB"
AUTO_REBOOT="$AUTO_REBOOT"
ENABLE_BLUETOOTH="$ENABLE_BLUETOOTH"
ENABLE_PRINTING="$ENABLE_PRINTING"
ENABLE_FIREWALL="$ENABLE_FIREWALL"
ENABLE_SSH="$ENABLE_SSH"
ENABLE_ZRAM="$ENABLE_ZRAM"
ENABLE_FLATPAK="$ENABLE_FLATPAK"
ENABLE_REFLECTOR="$ENABLE_REFLECTOR"
ENABLE_FSTRIM="$ENABLE_FSTRIM"
ENABLE_PACCACHE="$ENABLE_PACCACHE"
INSTALL_PIKAUR="$INSTALL_PIKAUR"
INSTALL_MULTIMEDIA="$INSTALL_MULTIMEDIA"
INSTALL_COMMON_APPS="$INSTALL_COMMON_APPS"
INSTALL_DEV_TOOLS="$INSTALL_DEV_TOOLS"
INSTALL_GAMER_TOOLS="$INSTALL_GAMER_TOOLS"
INSTALL_FONTS="$INSTALL_FONTS"
INSTALL_BTRFS_ASSISTANT="$INSTALL_BTRFS_ASSISTANT"
GPU_VENDOR="$GPU_VENDOR"
CPU_VENDOR="$CPU_VENDOR"
ROOT_FS_TYPE="$ROOT_FS_TYPE"
HOME_FS_TYPE="$HOME_FS_TYPE"
SEPARATE_HOME="$SEPARATE_HOME"
REFORMAT_ROOT="$REFORMAT_ROOT"
REFORMAT_HOME="$REFORMAT_HOME"
REFORMAT_EFI="$REFORMAT_EFI"
FONT_TIER="$FONT_TIER"
BROWSER_CHOICE="$BROWSER_CHOICE"
EDITOR_CHOICE="$EDITOR_CHOICE"
TERMINAL_CHOICE="$TERMINAL_CHOICE"
MULTILIB_REQUIRED="$MULTILIB_REQUIRED"
USE_BTRFS_LAYOUT="$USE_BTRFS_LAYOUT"
DUAL_BOOT_MODE="$DUAL_BOOT_MODE"
PRESERVE_EXISTING_ESP="$PRESERVE_EXISTING_ESP"
PKGS_BASE="$PKGS_BASE"
PKGS_KERNELS="$PKGS_KERNELS"
PKGS_DESKTOP="$PKGS_DESKTOP"
PKGS_GAMER="$PKGS_GAMER"
PKGS_FONTS="$PKGS_FONTS"
PKGS_APPS="$PKGS_APPS"
PKGS_SERVICES="$PKGS_SERVICES"
PKGS_BOOT="$PKGS_BOOT"
PKGS_MULTIMEDIA="$PKGS_MULTIMEDIA"
PKGS_DEV="$PKGS_DEV"
PKGS_GPU="$PKGS_GPU"
PKGS_EXTRA="$PKGS_EXTRA"
DM_SERVICE="$DM_SERVICE"
DM_PACKAGE="$DM_PACKAGE"
WIFI_IFACE="$WIFI_IFACE"
WIFI_SSID_SELECTED="$WIFI_SSID_SELECTED"
WIFI_CONNECTED="$WIFI_CONNECTED"
WIFI_BACKEND_USED="$WIFI_BACKEND_USED"
WIFI_HIDDEN_NETWORK="$WIFI_HIDDEN_NETWORK"
WIFI_PROFILE_NAME="$WIFI_PROFILE_NAME"
EOF
  chmod 600 "$CONFIG_EXPORT"
}

preflight() {
  [[ $EUID -eq 0 ]] || die "Execute como root."
  is_uefi || die "Este instalador exige boot em modo UEFI."

  local required_cmds=(
    lsblk findmnt sgdisk parted partprobe wipefs mkfs.fat mkfs.btrfs mkfs.ext4 mkfs.xfs
    mkswap swapon pacstrap arch-chroot genfstab btrfs blkid bootctl timedatectl sed awk
    grep lspci pacman mount umount mountpoint efibootmgr rfkill blockdev
  )
  local cmd

  for cmd in "${required_cmds[@]}"; do
    need_cmd "$cmd"
  done

  if ! command -v iwctl >/dev/null 2>&1 && ! command -v nmcli >/dev/null 2>&1; then
    append_warning "Nem iwctl nem nmcli estão disponíveis no live ISO. A configuração automática de Wi‑Fi ficará indisponível."
  fi

  timedatectl set-ntp true || warn "Falha ao habilitar NTP."
  ensure_tui
}

scan_storage_layout() {
  : > "$SCAN_REPORT"
  DETECTED_EXISTING_OSES=()
  DETECTED_WINDOWS_PARTS=()
  DETECTED_LINUX_PARTS=()
  DETECTED_ESP_PARTS=()
  SUGGESTED_DUALBOOT_ESP=""
  SUGGESTED_TARGET_DISK=""
  LIVE_MEDIA_DEVICE="$(root_source_live_media)"

  echo "=== BLOCK DEVICES ===" >> "$SCAN_REPORT"
  lsblk -e7 -o NAME,SIZE,TYPE,FSTYPE,MODEL,TRAN,MOUNTPOINT >> "$SCAN_REPORT" || true
  echo >> "$SCAN_REPORT"
  echo "=== EFI BOOT ENTRIES ===" >> "$SCAN_REPORT"
  efibootmgr -v >> "$SCAN_REPORT" 2>/dev/null || true
  echo >> "$SCAN_REPORT"

  local esp_probe_dir
  esp_probe_dir="$(mktemp -d /tmp/arch-v32-esp.XXXXXX)"

  while IFS= read -r part; do
    local fstype partlabel parttype partflags disk found_any is_esp_candidate
    fstype="$(blkid -o value -s TYPE "$part" 2>/dev/null || true)"
    partlabel="$(blkid -o value -s PARTLABEL "$part" 2>/dev/null || true)"
    parttype="$(blkid -o value -s PART_ENTRY_TYPE "$part" 2>/dev/null || true)"
    partflags="$(lsblk -no PARTFLAGS "$part" 2>/dev/null || true)"
    disk="$(disk_from_part "$part")"
    is_esp_candidate="no"

    if [[ "$fstype" == "vfat" || "$fstype" == "fat32" ]]; then
      if [[ "${parttype,,}" == "c12a7328-f81f-11d2-ba4b-00a0c93ec93b" || "$partflags" == *esp* || "$partlabel" =~ [Ee][Ff][Ii] ]]; then
        is_esp_candidate="yes"
      fi
    fi

    if [[ "$is_esp_candidate" == "yes" ]]; then
      DETECTED_ESP_PARTS+=("$part")
      if mount "$part" "$esp_probe_dir" >/dev/null 2>&1; then
        found_any="no"
        if [[ -d "$esp_probe_dir/EFI/Microsoft" ]]; then
          DETECTED_EXISTING_OSES+=("Windows @ $part")
          DETECTED_WINDOWS_PARTS+=("$part")
          found_any="yes"
          [[ -z "$SUGGESTED_DUALBOOT_ESP" ]] && SUGGESTED_DUALBOOT_ESP="$part"
        fi
        if [[ -d "$esp_probe_dir/EFI/ubuntu" || -d "$esp_probe_dir/EFI/fedora" || -d "$esp_probe_dir/EFI/opensuse" || -d "$esp_probe_dir/EFI/arch" || -d "$esp_probe_dir/loader/entries" ]]; then
          DETECTED_EXISTING_OSES+=("Linux/UEFI loader @ $part")
          DETECTED_LINUX_PARTS+=("$part")
          found_any="yes"
        fi
        if [[ "$found_any" == "yes" && -z "$SUGGESTED_TARGET_DISK" ]]; then
          SUGGESTED_TARGET_DISK="$disk"
        fi
        umount "$esp_probe_dir" >/dev/null 2>&1 || true
      fi
    fi

    if [[ "$partlabel" =~ [Ww]indows|[Rr]ecovery|[Ee]FI ]]; then
      echo "PARTLABEL hint: $part => $partlabel" >> "$SCAN_REPORT"
    fi

    if [[ "$fstype" == "ntfs" ]]; then
      DETECTED_EXISTING_OSES+=("Possible Windows/NTFS @ $part")
      [[ -z "$SUGGESTED_TARGET_DISK" ]] && SUGGESTED_TARGET_DISK="$disk"
    fi

    if [[ "$fstype" == "ext4" || "$fstype" == "xfs" || "$fstype" == "btrfs" ]]; then
      DETECTED_EXISTING_OSES+=("Possible Linux FS @ $part ($fstype)")
    fi
  done < <(lsblk -rpno NAME,TYPE | awk '$2=="part"{print $1}')

  {
    echo "=== DETECTED EXISTING OSES ==="
    printf '%s\n' "${DETECTED_EXISTING_OSES[@]:-none}"
    echo
    echo "Suggested ESP: ${SUGGESTED_DUALBOOT_ESP:-none}"
    echo "Suggested disk: ${SUGGESTED_TARGET_DISK:-none}"
    echo "Live media source: ${LIVE_MEDIA_DEVICE:-unknown}"
  } >> "$SCAN_REPORT"
}

show_storage_scan_summary() {
  ui_header "Scanner de armazenamento"
  ui_text "Relatório salvo em: $SCAN_REPORT"
  if (( ${#DETECTED_EXISTING_OSES[@]} > 0 )); then
    printf '%s\n' "${DETECTED_EXISTING_OSES[@]}"
  else
    ui_text "Nenhum outro sistema foi identificado com alta confiança."
  fi
  [[ -n "$SUGGESTED_DUALBOOT_ESP" ]] && ui_note "ESP sugerida para dual boot: $SUGGESTED_DUALBOOT_ESP"
  [[ -n "$SUGGESTED_TARGET_DISK" ]] && ui_note "Disco sugerido: $SUGGESTED_TARGET_DISK"
}

show_banner() {
  ui_header "Arch Auto Install v3.4.5-h1"
  ui_text "Dual boot mais inteligente, detecção melhor de Windows/Linux, detecção de discos mais robusta e correção automática de Wi‑Fi via rfkill + iwd."
}

ask_install_mode() {
  ui_header "Modo de instalação"
  INSTALL_MODE="$(ui_select_one "Escolha o modo" "auto-disco-inteiro" "usar-particoes-existentes" "dual-boot-assistido")"
  if [[ "$INSTALL_MODE" == "dual-boot-assistido" ]]; then
    DUAL_BOOT_MODE="yes"
    PRESERVE_EXISTING_ESP="yes"
  fi
}

ask_profile() {
  ui_header "Perfil"
  PROFILE="$(ui_select_one "Escolha o perfil principal" "desktop" "gamer" "window-manager" "minimal")"
  case "$PROFILE" in
    desktop|gamer)
      DESKTOP_VARIANT="$(ui_select_one "Escolha o ambiente" "kde" "gnome" "xfce")"
      DESKTOP_TIER="$(ui_select_one "Escolha o nível" "full" "balanced")"
      ;;
    window-manager)
      WINDOW_MANAGER="$(ui_select_one "Escolha o WM" "i3" "sway" "hyprland")"
      DESKTOP_TIER="balanced"
      ;;
    minimal)
      DESKTOP_VARIANT=""
      WINDOW_MANAGER=""
      DESKTOP_TIER="balanced"
      ;;
  esac
  [[ "$PROFILE" == "gamer" ]] && INSTALL_GAMER_TOOLS="yes"
}

ask_hardware() {
  ui_header "Hardware"
  local detected_gpu
  detected_gpu="$(detect_gpu_vendor_auto)"
  GPU_VENDOR="$(ui_select_one "GPU detectada: $detected_gpu. Confirme ou ajuste" "$detected_gpu" "nvidia" "amd" "intel" "unknown")"
  CPU_VENDOR="$(ui_select_one "CPU vendor" "auto" "amd" "intel")"
}

ask_display_manager() {
  ui_header "Gerenciador de login"
  case "$DESKTOP_VARIANT" in
    kde) DISPLAY_MANAGER_CHOICE="$(ui_select_one "Escolha o display manager do KDE" "sddm" "plasma-login-manager-se-disponivel")" ;;
    gnome) DISPLAY_MANAGER_CHOICE="gdm" ;;
    xfce) DISPLAY_MANAGER_CHOICE="$(ui_select_one "Escolha o display manager do XFCE" "lightdm" "sddm")" ;;
    *) DISPLAY_MANAGER_CHOICE="none" ;;
  esac
}

ask_fonts() {
  ui_header "Fontes"
  if ui_confirm "Instalar fontes?"; then
    INSTALL_FONTS="yes"
    FONT_TIER="$(ui_select_one "Escolha o conjunto de fontes" "full" "balanced" "developer")"
  else
    INSTALL_FONTS="no"
    FONT_TIER="none"
  fi
}

ask_apps_and_services() {
  ui_header "Aplicativos e serviços"
  if ui_confirm "Instalar aplicativos comuns?"; then INSTALL_COMMON_APPS="yes"; else INSTALL_COMMON_APPS="no"; fi
  if ui_confirm "Instalar ferramentas de desenvolvimento?"; then INSTALL_DEV_TOOLS="yes"; else INSTALL_DEV_TOOLS="no"; fi
  if ui_confirm "Instalar multimídia e codecs?"; then INSTALL_MULTIMEDIA="yes"; else INSTALL_MULTIMEDIA="no"; fi
  if ui_confirm "Habilitar Bluetooth?"; then ENABLE_BLUETOOTH="yes"; else ENABLE_BLUETOOTH="no"; fi
  if ui_confirm "Habilitar impressão (CUPS)?"; then ENABLE_PRINTING="yes"; else ENABLE_PRINTING="no"; fi
  if prompt_default_yes "Habilitar firewall (ufw)?"; then ENABLE_FIREWALL="yes"; else ENABLE_FIREWALL="no"; fi
  if ui_confirm "Habilitar OpenSSH?"; then ENABLE_SSH="yes"; else ENABLE_SSH="no"; fi
  if prompt_default_yes "Habilitar zram-generator?"; then ENABLE_ZRAM="yes"; else ENABLE_ZRAM="no"; fi
  if ui_confirm "Habilitar Flatpak?"; then ENABLE_FLATPAK="yes"; else ENABLE_FLATPAK="no"; fi
  if ui_confirm "Habilitar reflector.timer?"; then ENABLE_REFLECTOR="yes"; else ENABLE_REFLECTOR="no"; fi
  if prompt_default_yes "Habilitar fstrim.timer?"; then ENABLE_FSTRIM="yes"; else ENABLE_FSTRIM="no"; fi
  if prompt_default_yes "Habilitar paccache.timer?"; then ENABLE_PACCACHE="yes"; else ENABLE_PACCACHE="no"; fi
  if ui_confirm "Instalar pikaur ao final?"; then INSTALL_PIKAUR="yes"; else INSTALL_PIKAUR="no"; fi
  if ui_confirm "Instalar btrfs-assistant quando a raiz for Btrfs?"; then INSTALL_BTRFS_ASSISTANT="yes"; else INSTALL_BTRFS_ASSISTANT="no"; fi

  BROWSER_CHOICE="$(ui_select_one "Escolha o navegador principal" "firefox" "chromium" "brave-via-aur" "none")"
  EDITOR_CHOICE="$(ui_select_one "Escolha o editor principal" "vim" "nano")"

  case "$DESKTOP_VARIANT" in
    kde) TERMINAL_CHOICE="konsole" ;;
    gnome) TERMINAL_CHOICE="gnome-terminal" ;;
    xfce) TERMINAL_CHOICE="xfce4-terminal" ;;
    *) TERMINAL_CHOICE="alacritty" ;;
  esac

  if ui_confirm "Reiniciar automaticamente ao final?"; then AUTO_REBOOT="yes"; else AUTO_REBOOT="no"; fi
}

ask_storage_options() {
  ui_header "Armazenamento"
  if ui_confirm "Usar swap?"; then USE_SWAP="yes"; else USE_SWAP="no"; fi
  if [[ "$INSTALL_MODE" == "auto-disco-inteiro" && "$USE_SWAP" == "yes" ]]; then
    SWAP_SIZE_GB="$(ui_input "Tamanho da swap em GiB" "$SWAP_SIZE_GB")"
  fi
}

collect_identity() {
  ui_header "Identidade do sistema"
  HOSTNAME="$(ui_input "Hostname" "${HOSTNAME:-archlinux}")"
  USERNAME="$(ui_input "Usuário principal" "${USERNAME:-user}")"
  FULLNAME="$(ui_input "Nome completo" "${FULLNAME:-Usuário Arch}")"
  ROOT_PASSWORD="$(ui_password "Senha do root")"
  USER_PASSWORD="$(ui_password "Senha do usuário $USERNAME")"
}

list_disks_smart() {
  local live_disk=""
  [[ -n "$LIVE_MEDIA_DEVICE" ]] && live_disk="$(disk_from_part "$LIVE_MEDIA_DEVICE")"
  while IFS= read -r disk; do
    [[ -n "$live_disk" && "$disk" == "$live_disk" ]] && continue
    local size model tran removable mark
    size="$(lsblk -dnro SIZE "$disk" 2>/dev/null || true)"
    model="$(lsblk -dnro MODEL "$disk" 2>/dev/null || true)"
    tran="$(lsblk -dnro TRAN "$disk" 2>/dev/null || true)"
    removable="fixed"
    is_removable_disk "$disk" && removable="removable"
    mark=""
    [[ -n "$SUGGESTED_TARGET_DISK" && "$disk" == "$SUGGESTED_TARGET_DISK" ]] && mark=" [suggested]"
    [[ -n "$LIVE_MEDIA_DEVICE" && "$LIVE_MEDIA_DEVICE" == "$disk"* ]] && mark="$mark [live-media?]"
    printf "%s | %s | %s | %s | %s%s\n" "$disk" "$size" "${model:-unknown}" "${tran:-n/a}" "$removable" "$mark"
  done < <(lsblk -dnp -e7 -o NAME | grep -E '^/dev/(sd|vd|nvme|mmcblk)')
}

select_disk_smart() {
  ui_header "Seleção inteligente do disco"
  list_disks_smart
  local live_disk=""
  [[ -n "$LIVE_MEDIA_DEVICE" ]] && live_disk="$(disk_from_part "$LIVE_MEDIA_DEVICE")"
  mapfile -t disks < <(lsblk -dnp -e7 -o NAME | grep -E '^/dev/(sd|vd|nvme|mmcblk)' | { if [[ -n "$live_disk" ]]; then grep -vx "$live_disk"; else cat; fi; })
  (( ${#disks[@]} > 0 )) || die "Nenhum disco elegível encontrado."

  if [[ -n "$SUGGESTED_TARGET_DISK" ]] && ui_confirm "Usar o disco sugerido pelo scanner? ($SUGGESTED_TARGET_DISK)"; then
    TARGET_DISK="$SUGGESTED_TARGET_DISK"
    return
  fi

  TARGET_DISK="$(ui_select_one "Selecione o disco" "${disks[@]}")"
}

select_existing_partitions() {
  ui_header "Partições existentes"
  lsblk -rpno NAME,SIZE,FSTYPE,PARTLABEL,MOUNTPOINT,TYPE | grep ' part$' || true

  mapfile -t efi_candidates < <(lsblk -rpno NAME,FSTYPE,TYPE | awk '$3=="part" && ($2=="vfat" || $2=="fat32") {print $1}')
  (( ${#efi_candidates[@]} > 0 )) || die "Nenhuma partição EFI FAT32 encontrada."
  EFI_PART="$(ui_select_one "Selecione a partição EFI" "${efi_candidates[@]}")"

  mapfile -t root_candidates < <(lsblk -rpno NAME,FSTYPE,TYPE | awk '$3=="part" && ($2=="btrfs" || $2=="ext4" || $2=="xfs" || $2=="") {print $1}' | grep -vx "$EFI_PART")
  (( ${#root_candidates[@]} > 0 )) || die "Nenhuma partição candidata para raiz encontrada."
  ROOT_PART="$(ui_select_one "Selecione a partição raiz" "${root_candidates[@]}")"

  if ui_confirm "Usar /home separado?"; then
    SEPARATE_HOME="yes"
    mapfile -t home_candidates < <(lsblk -rpno NAME,FSTYPE,TYPE | awk '$3=="part" && ($2=="btrfs" || $2=="ext4" || $2=="xfs" || $2=="") {print $1}' | grep -vx "$EFI_PART" | grep -vx "$ROOT_PART")
    (( ${#home_candidates[@]} > 0 )) || die "Nenhuma partição candidata para /home."
    HOME_PART="$(ui_select_one "Selecione a partição /home" "${home_candidates[@]}")"
    HOME_FS_TYPE="$(blkid -o value -s TYPE "$HOME_PART" 2>/dev/null || true)"
    HOME_FS_TYPE="${HOME_FS_TYPE:-ext4}"
    if ui_confirm "Reformatar /home?"; then REFORMAT_HOME="yes"; else REFORMAT_HOME="no"; fi
  fi

  if [[ "$USE_SWAP" == "yes" ]] && ui_confirm "Usar partição swap existente?"; then
    mapfile -t swap_candidates < <(lsblk -rpno NAME,FSTYPE,TYPE | awk '$3=="part" && $2=="swap" {print $1}')
    if (( ${#swap_candidates[@]} > 0 )); then
      SWAP_PART="$(ui_select_one "Selecione a partição swap" "${swap_candidates[@]}")"
    else
      append_warning "Você pediu swap existente, mas nenhuma partição swap foi detectada."
    fi
  fi

  if ui_confirm "Reformatar a partição raiz?"; then
    REFORMAT_ROOT="yes"
    choose_root_filesystem_if_reformatting
  else
    REFORMAT_ROOT="no"
    ROOT_FS_TYPE="$(blkid -o value -s TYPE "$ROOT_PART" 2>/dev/null || echo btrfs)"
    [[ "$ROOT_FS_TYPE" == "btrfs" ]] && USE_BTRFS_LAYOUT="yes" || USE_BTRFS_LAYOUT="no"
  fi
  if ui_confirm "Reformatar a partição EFI?"; then REFORMAT_EFI="yes"; else REFORMAT_EFI="no"; fi
}

select_dualboot_partitions_smart() {
  ui_header "Dual boot assistido"
  ui_note "Esse modo preserva a ESP existente e tenta coexistir com Windows e outros Linux em UEFI."

  lsblk -rpno NAME,SIZE,FSTYPE,PARTLABEL,MOUNTPOINT,TYPE | grep ' part$' || true

  mapfile -t efi_candidates < <(printf '%s\n' "${DETECTED_ESP_PARTS[@]}" | sed '/^$/d' | awk '!seen[$0]++')
  if (( ${#efi_candidates[@]} == 0 )); then
    mapfile -t efi_candidates < <(lsblk -rpno NAME,FSTYPE,TYPE | awk '$3=="part" && ($2=="vfat" || $2=="fat32") {print $1}')
  fi
  (( ${#efi_candidates[@]} > 0 )) || die "Nenhuma ESP encontrada para dual boot."

  if [[ -n "$SUGGESTED_DUALBOOT_ESP" && $(printf '%s\n' "${efi_candidates[@]}" | grep -Fx "$SUGGESTED_DUALBOOT_ESP" || true) ]]; then
    if ui_confirm "Usar a ESP sugerida pelo scanner? ($SUGGESTED_DUALBOOT_ESP)"; then
      EFI_PART="$SUGGESTED_DUALBOOT_ESP"
    else
      EFI_PART="$(ui_select_one "Selecione a ESP existente" "${efi_candidates[@]}")"
    fi
  else
    EFI_PART="$(ui_select_one "Selecione a ESP existente" "${efi_candidates[@]}")"
  fi

  mapfile -t root_candidates < <(lsblk -rpno NAME,FSTYPE,TYPE | awk '$3=="part" && ($2=="btrfs" || $2=="ext4" || $2=="xfs" || $2=="") {print $1}' | grep -vx "$EFI_PART")
  (( ${#root_candidates[@]} > 0 )) || die "Nenhuma partição candidata para raiz encontrada."
  ROOT_PART="$(ui_select_one "Selecione a partição destinada ao Arch" "${root_candidates[@]}")"
  is_known_windows_partition "$ROOT_PART" && die "A partição raiz escolhida parece pertencer ao Windows ou recuperação: $ROOT_PART"

  if ui_confirm "Usar /home separado no dual boot?"; then
    SEPARATE_HOME="yes"
    mapfile -t home_candidates < <(lsblk -rpno NAME,FSTYPE,TYPE | awk '$3=="part" && ($2=="btrfs" || $2=="ext4" || $2=="xfs" || $2=="") {print $1}' | grep -vx "$EFI_PART" | grep -vx "$ROOT_PART")
    (( ${#home_candidates[@]} > 0 )) || die "Nenhuma partição candidata para /home."
    HOME_PART="$(ui_select_one "Selecione a partição /home" "${home_candidates[@]}")"
    HOME_FS_TYPE="$(blkid -o value -s TYPE "$HOME_PART" 2>/dev/null || true)"
    HOME_FS_TYPE="${HOME_FS_TYPE:-ext4}"
    if ui_confirm "Reformatar /home?"; then REFORMAT_HOME="yes"; else REFORMAT_HOME="no"; fi
  fi

  if [[ "$USE_SWAP" == "yes" ]] && ui_confirm "Usar partição swap existente?"; then
    mapfile -t swap_candidates < <(lsblk -rpno NAME,FSTYPE,TYPE | awk '$3=="part" && $2=="swap" {print $1}')
    if (( ${#swap_candidates[@]} > 0 )); then
      SWAP_PART="$(ui_select_one "Selecione a partição swap" "${swap_candidates[@]}")"
    fi
  fi

  REFORMAT_EFI="no"
  if ui_confirm "Reformatar a partição raiz do Arch?"; then
    REFORMAT_ROOT="yes"
    choose_root_filesystem_if_reformatting
  else
    REFORMAT_ROOT="no"
    ROOT_FS_TYPE="$(blkid -o value -s TYPE "$ROOT_PART" 2>/dev/null || echo btrfs)"
    [[ "$ROOT_FS_TYPE" == "btrfs" ]] && USE_BTRFS_LAYOUT="yes" || USE_BTRFS_LAYOUT="no"
  fi
}

validate_target_not_live_media() {
  local live_src
  live_src="$(root_source_live_media)"
  if [[ -n "$live_src" ]]; then
    if [[ -n "$TARGET_DISK" && "$live_src" == "$TARGET_DISK"* ]]; then
      die "O disco selecionado parece ser a própria mídia do live ISO: $TARGET_DISK"
    fi
    for p in "$EFI_PART" "$ROOT_PART" "$HOME_PART" "$SWAP_PART"; do
      [[ -z "$p" ]] && continue
      [[ "$live_src" == "$p"* ]] && die "A partição selecionada parece pertencer à mídia do live ISO: $p"
    done
  fi
}

validate_inputs() {
  [[ -n "$HOSTNAME" ]] || die "Hostname vazio."
  [[ "$HOSTNAME" =~ ^[a-zA-Z0-9][a-zA-Z0-9.-]{0,62}$ ]] || die "Hostname inválido: $HOSTNAME"
  [[ -n "$USERNAME" ]] || die "Usuário principal vazio."
  [[ "$USERNAME" =~ ^[a-z_][a-z0-9_-]*$ ]] || die "Nome de usuário inválido: $USERNAME"
  [[ -n "$FULLNAME" ]] || append_warning "Nome completo vazio."
  [[ -n "$ROOT_PASSWORD" ]] || die "Senha root vazia."
  [[ -n "$USER_PASSWORD" ]] || die "Senha do usuário vazia."
  [[ ${#ROOT_PASSWORD} -ge 12 ]] || append_warning "Senha root com menos de 12 caracteres."
  [[ ${#USER_PASSWORD} -ge 12 ]] || append_warning "Senha do usuário com menos de 12 caracteres."
  [[ "$USERNAME" != "root" ]] || die "O usuário principal não pode se chamar root."
  [[ "$USERNAME" != "$HOSTNAME" ]] || append_warning "Usuário e hostname idênticos aumentam chance de erro operacional."
  if [[ "$INSTALL_MODE" == "auto-disco-inteiro" && "$USE_SWAP" == "yes" ]]; then
    [[ "$SWAP_SIZE_GB" =~ ^[1-9][0-9]*$ ]] || die "Tamanho de swap inválido: $SWAP_SIZE_GB"
  fi
}

validate_partition_uniqueness() {
  local selected=()
  if [[ "$INSTALL_MODE" != "auto-disco-inteiro" ]]; then
    [[ -n "$EFI_PART" ]] || die "Partição EFI não definida."
    [[ -n "$ROOT_PART" ]] || die "Partição raiz não definida."
  fi
  local p q
  for p in "$EFI_PART" "$ROOT_PART" "$HOME_PART" "$SWAP_PART"; do
    [[ -z "$p" ]] && continue
    for q in "${selected[@]}"; do
      [[ "$p" == "$q" ]] && die "A mesma partição foi selecionada mais de uma vez: $p"
    done
    selected+=("$p")
  done

  [[ -n "$EFI_PART" && -n "$ROOT_PART" && "$EFI_PART" == "$ROOT_PART" ]] && die "EFI e raiz não podem ser a mesma partição."
  [[ "$SEPARATE_HOME" == "yes" && -n "$HOME_PART" && "$HOME_PART" == "$ROOT_PART" ]] && die "/home separado não pode apontar para a mesma partição da raiz."
  [[ -n "$SWAP_PART" && "$SWAP_PART" == "$EFI_PART" ]] && die "Swap não pode usar a partição EFI."
}

validate_bootloader_dependencies() {
  if [[ "$BOOTLOADER" == "grub" ]] && ! command -v grub-install >/dev/null 2>&1; then
    append_warning "grub-install não está disponível no live ISO; a etapa de bootloader dependerá do sistema instalado."
  fi
}

choose_root_filesystem_if_reformatting() {
  case "$INSTALL_MODE" in
    usar-particoes-existentes|dual-boot-assistido)
      if ui_confirm "Ao reformatar a raiz, usar Btrfs? (não = ext4)"; then
        ROOT_FS_TYPE="btrfs"
        USE_BTRFS_LAYOUT="yes"
      elif ui_confirm "Usar XFS em vez de ext4?"; then
        ROOT_FS_TYPE="xfs"
        USE_BTRFS_LAYOUT="no"
      else
        ROOT_FS_TYPE="ext4"
        USE_BTRFS_LAYOUT="no"
      fi
      ;;
  esac
}

validate_storage() {
  [[ "$TARGET_ROOT" == "/mnt" ]] || die "TARGET_ROOT inesperado: $TARGET_ROOT"
  mountpoint -q "$TARGET_ROOT" && append_warning "$TARGET_ROOT já está montado; será desmontado antes de prosseguir."
  if [[ "$INSTALL_MODE" == "auto-disco-inteiro" ]]; then
    [[ -b "$TARGET_DISK" ]] || die "Disco alvo inválido."
    if [[ -n "$TARGET_DISK" ]]; then
      local bytes gib
      bytes="$(blockdev --getsize64 "$TARGET_DISK")"
      gib=$(( bytes / 1024 / 1024 / 1024 ))
      (( gib >= 50 )) || append_warning "Disco com menos de 50 GiB; a instalação pode ficar apertada."
      is_removable_disk "$TARGET_DISK" && append_warning "O disco selecionado parece removível. Confirme que não é a mídia errada."
    fi
  else
    [[ -b "$EFI_PART" ]] || die "EFI inválida."
    [[ -b "$ROOT_PART" ]] || die "Raiz inválida."

    local efi_fstype efi_size_mib root_fstype
    efi_fstype="$(blkid -o value -s TYPE "$EFI_PART" 2>/dev/null || true)"
    efi_size_mib="$(lsblk -bno SIZE "$EFI_PART" 2>/dev/null | awk '{printf "%d", $1/1024/1024}')"
    root_fstype="$(blkid -o value -s TYPE "$ROOT_PART" 2>/dev/null || true)"

    if [[ "$REFORMAT_EFI" != "yes" && "$efi_fstype" != "vfat" && "$efi_fstype" != "fat32" ]]; then
      die "A partição EFI selecionada não parece FAT32/vfat: $EFI_PART ($efi_fstype)"
    fi
    if [[ -n "$efi_size_mib" ]] && (( efi_size_mib < 260 )); then
      append_warning "A partição EFI tem menos de 260 MiB; isso é pequeno para alguns cenários de dual boot."
    fi
    if [[ "$REFORMAT_ROOT" != "yes" && -z "$root_fstype" ]]; then
      die "Não foi possível detectar o filesystem atual da raiz sem reformatar: $ROOT_PART"
    fi
    if [[ "$SEPARATE_HOME" == "yes" && -n "$HOME_PART" && "$REFORMAT_HOME" != "yes" ]]; then
      local home_fstype
      home_fstype="$(blkid -o value -s TYPE "$HOME_PART" 2>/dev/null || true)"
      [[ -n "$home_fstype" ]] || die "Não foi possível detectar o filesystem atual de /home sem reformatar: $HOME_PART"
    fi
    if [[ -n "$SWAP_PART" ]]; then
      local swap_fstype
      swap_fstype="$(blkid -o value -s TYPE "$SWAP_PART" 2>/dev/null || true)"
      [[ "$swap_fstype" == "swap" ]] || append_warning "A partição swap selecionada não está marcada como swap: $SWAP_PART ($swap_fstype)"
    fi

    if is_known_windows_partition "$ROOT_PART"; then
      die "A partição raiz selecionada parece ser do Windows/Recovery: $ROOT_PART"
    fi
    if [[ -n "$HOME_PART" ]] && is_known_windows_partition "$HOME_PART"; then
      die "A partição /home selecionada parece ser do Windows/Recovery: $HOME_PART"
    fi
    if is_yes "$DUAL_BOOT_MODE" && is_no "$REFORMAT_ROOT" && ! is_known_linux_partition "$ROOT_PART"; then
      die "No dual boot sem reformatar, a raiz precisa já conter filesystem Linux reconhecido: $ROOT_PART"
    fi
    if is_yes "$DUAL_BOOT_MODE" && same_disk "$EFI_PART" "$ROOT_PART"; then
      append_warning "ESP e raiz do Arch estão no mesmo disco do outro SO. Confirme que a partição escolhida é realmente a destinada ao Arch."
    fi
  fi
}

validate_mount_state() {
  local p mnt
  for p in "$EFI_PART" "$ROOT_PART" "$HOME_PART" "$SWAP_PART"; do
    [[ -z "$p" ]] && continue
    if findmnt -rn -S "$p" >/dev/null 2>&1; then
      mnt="$(findmnt -rn -S "$p" -o TARGET 2>/dev/null | head -n1 || true)"
      if [[ "$mnt" == "/" || "$mnt" == "/boot" || "$mnt" == "/home" ]]; then
        die "A partição $p está montada em $mnt no ambiente live. Desmonte-a antes de continuar."
      fi
      append_warning "A partição $p está montada em ${mnt:-desconhecido}; o instalador vai tentar desmontá-la."
    fi
  done
}

validate_destructive_targets() {
  if [[ "$INSTALL_MODE" == "auto-disco-inteiro" ]]; then
    [[ -n "$TARGET_DISK" ]] || die "Disco alvo não definido."
    [[ "$TARGET_DISK" =~ ^/dev/ ]] || die "Disco alvo inválido: $TARGET_DISK"
  else
    if [[ "$REFORMAT_ROOT" == "yes" ]] && findmnt -rn -S "$ROOT_PART" | grep -vq "^$TARGET_ROOT"; then
      append_warning "A raiz selecionada está montada fora de $TARGET_ROOT e será forçada a desmontar antes da formatação."
    fi
    if [[ "$REFORMAT_EFI" == "yes" ]] && findmnt -rn -S "$EFI_PART" | grep -vq "^$TARGET_ROOT"; then
      append_warning "A EFI selecionada está montada fora de $TARGET_ROOT e será forçada a desmontar antes da formatação."
    fi
    if [[ "$SEPARATE_HOME" == "yes" && "$REFORMAT_HOME" == "yes" && -n "$HOME_PART" ]] && findmnt -rn -S "$HOME_PART" | grep -vq "^$TARGET_ROOT"; then
      append_warning "O /home selecionado está montado fora de $TARGET_ROOT e será forçado a desmontar antes da formatação."
    fi
  fi
}

validate_dualboot_mode() {
  if [[ "$DUAL_BOOT_MODE" == "yes" ]]; then
    [[ "$REFORMAT_EFI" == "no" ]] || die "No dual boot, a ESP não pode ser reformatada."
    [[ -n "$EFI_PART" && -n "$ROOT_PART" ]] || die "Dual boot requer ESP e raiz definidas."
    is_known_windows_partition "$EFI_PART" && true
    (( ${#DETECTED_EXISTING_OSES[@]} == 0 )) && append_warning "Dual boot assistido foi selecionado, mas o scanner não encontrou outro sistema com alta confiança."
    [[ "$BOOTLOADER" == "systemd-boot" ]] && append_warning "systemd-boot em dual boot exige mais disciplina manual para entradas; grub tende a ser mais tolerante."
  fi
}

run_validations() {
  VALIDATION_WARNINGS=()
  ROLLBACK_ACTIONS=()
  DESTRUCTIVE_ACTIONS_STARTED="no"
  normalize_config
  validate_target_not_live_media
  validate_inputs
  validate_partition_uniqueness
  validate_storage
  validate_mount_state
  validate_destructive_targets
  validate_dualboot_mode
  validate_bootloader_dependencies
}

show_validation_summary() {
  ui_header "Validações"
  if has_warning; then
    printf '%s\n' "${VALIDATION_WARNINGS[@]}"
    echo
    ui_confirm "Há alertas. Continuar mesmo assim?" || die "Cancelado pelo usuário."
  else
    ui_text "Nenhum alerta relevante encontrado."
  fi
}

enable_multilib_live_if_needed() {
  if [[ "$MULTILIB_REQUIRED" != "yes" ]]; then
    return
  fi

  if grep -q '^\[multilib\]' /etc/pacman.conf && ! grep -q '^\#\[multilib\]' /etc/pacman.conf; then
    log "multilib já está habilitado no live ambiente."
    return
  fi

  log "Habilitando multilib no live ambiente..."
  sed -i '/^\#\[multilib\]$/,/^#Include/ s/^#//' /etc/pacman.conf
  pacman -Sy --noconfirm
}

create_auto_partitions() {
  begin_stage "storage.partitioning.auto"
  DESTRUCTIVE_ACTIONS_STARTED="yes"
  save_partition_table_backup
  local suffix swap_end
  suffix="$(partition_suffix "$TARGET_DISK")"
  EFI_PART="${TARGET_DISK}${suffix}1"
  [[ "$USE_SWAP" == "yes" ]] && SWAP_PART="${TARGET_DISK}${suffix}2" || SWAP_PART=""
  ROOT_PART="${TARGET_DISK}${suffix}$([[ "$USE_SWAP" == "yes" ]] && echo 3 || echo 2)"

  release_selected_block_devices
  register_rollback "safe_umount_all"
  [[ -s "$PARTITION_TABLE_BACKUP" ]] && register_rollback "sgdisk --load-backup=\"$PARTITION_TABLE_BACKUP\" \"$TARGET_DISK\" && partprobe \"$TARGET_DISK\""
  sgdisk --zap-all "$TARGET_DISK"
  wipefs -a "$TARGET_DISK"
  partprobe "$TARGET_DISK"

  parted -s "$TARGET_DISK" mklabel gpt
  parted -s "$TARGET_DISK" mkpart ESP fat32 1MiB 1025MiB
  parted -s "$TARGET_DISK" set 1 esp on

  if [[ "$USE_SWAP" == "yes" ]]; then
    swap_end=$((1025 + SWAP_SIZE_GB * 1024))
    parted -s "$TARGET_DISK" mkpart primary linux-swap 1025MiB "${swap_end}MiB"
    parted -s "$TARGET_DISK" mkpart primary btrfs "${swap_end}MiB" 100%
  else
    parted -s "$TARGET_DISK" mkpart primary btrfs 1025MiB 100%
  fi

  partprobe "$TARGET_DISK"
  udevadm settle >/dev/null 2>&1 || true
  wait_for_block_device "$EFI_PART" 20 || die "ESP não apareceu após particionamento: $EFI_PART"
  wait_for_block_device "$ROOT_PART" 20 || die "Partição raiz não apareceu após particionamento: $ROOT_PART"
  if [[ "$USE_SWAP" == "yes" && -n "$SWAP_PART" ]]; then
    wait_for_block_device "$SWAP_PART" 20 || die "Partição swap não apareceu após particionamento: $SWAP_PART"
  fi
  ROOT_FS_TYPE="btrfs"
  USE_BTRFS_LAYOUT="yes"
}

format_auto_partitions() {
  begin_stage "storage.format.auto"
  mkfs.fat -F32 -n ARCHESP "$EFI_PART"
  if [[ "$USE_SWAP" == "yes" && -n "$SWAP_PART" ]]; then
    mkswap "$SWAP_PART"
    swapon "$SWAP_PART"
  fi
  mkfs.btrfs -f -L ArchRoot "$ROOT_PART"
}

format_existing_partitions() {
  begin_stage "storage.format.existing"
  DESTRUCTIVE_ACTIONS_STARTED="yes"
  release_selected_block_devices
  register_rollback "safe_umount_all"

  [[ "$REFORMAT_EFI" == "yes" ]] && mkfs.fat -F32 -n ARCHESP "$EFI_PART"

  if [[ "$REFORMAT_ROOT" == "yes" ]]; then
    case "$ROOT_FS_TYPE" in
      btrfs)
        mkfs.btrfs -f -L ArchRoot "$ROOT_PART"
        USE_BTRFS_LAYOUT="yes"
        ;;
      xfs)
        mkfs.xfs -f "$ROOT_PART"
        USE_BTRFS_LAYOUT="no"
        ;;
      *)
        ROOT_FS_TYPE="ext4"
        mkfs.ext4 -F -L ArchRoot "$ROOT_PART"
        USE_BTRFS_LAYOUT="no"
        ;;
    esac
  else
    ROOT_FS_TYPE="$(blkid -o value -s TYPE "$ROOT_PART" 2>/dev/null || echo btrfs)"
    [[ "$ROOT_FS_TYPE" == "btrfs" ]] && USE_BTRFS_LAYOUT="yes" || USE_BTRFS_LAYOUT="no"
  fi

  if [[ "$SEPARATE_HOME" == "yes" && -n "$HOME_PART" && "$REFORMAT_HOME" == "yes" ]]; then
    case "$HOME_FS_TYPE" in
      btrfs) mkfs.btrfs -f -L ArchHome "$HOME_PART" ;;
      xfs) mkfs.xfs -f "$HOME_PART" ;;
      *) mkfs.ext4 -F "$HOME_PART" ;;
    esac
  fi

  if [[ "$USE_SWAP" == "yes" && -n "$SWAP_PART" ]]; then
    if [[ "$(blkid -o value -s TYPE "$SWAP_PART" 2>/dev/null || true)" != "swap" ]]; then
      mkswap "$SWAP_PART"
    fi
    swapon "$SWAP_PART" || true
  fi
}

mount_btrfs_new_layout() {
  begin_stage "storage.mount.btrfs-new"
  mount "$ROOT_PART" "$TARGET_ROOT"
  btrfs subvolume create "$TARGET_ROOT/@"
  btrfs subvolume create "$TARGET_ROOT/@home"
  btrfs subvolume create "$TARGET_ROOT/@var_log"
  btrfs subvolume create "$TARGET_ROOT/@var_cache"
  btrfs subvolume create "$TARGET_ROOT/@snapshots"
  btrfs subvolume create "$TARGET_ROOT/@srv"
  btrfs subvolume create "$TARGET_ROOT/@tmp"
  umount "$TARGET_ROOT"

  mount -o "$(btrfs_mount_opts_for "$ROOT_PART"),subvol=@" "$ROOT_PART" "$TARGET_ROOT"
  mkdir -p "$TARGET_ROOT"/{boot,home,.snapshots,var,tmp,srv}
  mkdir -p "$TARGET_ROOT"/var/{log,cache}
  mount -o "$(btrfs_mount_opts_for "$ROOT_PART"),subvol=@home" "$ROOT_PART" "$TARGET_ROOT/home"
  mount -o "$(btrfs_mount_opts_for "$ROOT_PART"),subvol=@snapshots" "$ROOT_PART" "$TARGET_ROOT/.snapshots"
  mount -o "$(btrfs_mount_opts_for "$ROOT_PART"),subvol=@var_log" "$ROOT_PART" "$TARGET_ROOT/var/log"
  mount -o "$(btrfs_mount_opts_for "$ROOT_PART"),subvol=@var_cache" "$ROOT_PART" "$TARGET_ROOT/var/cache"
  mount -o "$(btrfs_mount_opts_for "$ROOT_PART"),subvol=@srv" "$ROOT_PART" "$TARGET_ROOT/srv"
  mount -o "$(btrfs_mount_opts_for "$ROOT_PART"),subvol=@tmp" "$ROOT_PART" "$TARGET_ROOT/tmp"
  mount_efi_partition
}

mount_existing_layout() {
  begin_stage "storage.mount.existing"
  if [[ "$USE_BTRFS_LAYOUT" == "yes" ]]; then
    if mount "$ROOT_PART" "$TARGET_ROOT" 2>/dev/null; then
      if btrfs subvolume list "$TARGET_ROOT" | grep -q ' path @'; then
        umount "$TARGET_ROOT"
        mount -o "$(btrfs_mount_opts_for "$ROOT_PART"),subvol=@" "$ROOT_PART" "$TARGET_ROOT"
        mkdir -p "$TARGET_ROOT"/{boot,home,.snapshots,var,tmp,srv}
  mkdir -p "$TARGET_ROOT"/var/{log,cache}
        if [[ "$SEPARATE_HOME" != "yes" ]]; then mount -o "$(btrfs_mount_opts_for "$ROOT_PART"),subvol=@home" "$ROOT_PART" "$TARGET_ROOT/home" 2>/dev/null || true; fi
        mount -o "$(btrfs_mount_opts_for "$ROOT_PART"),subvol=@snapshots" "$ROOT_PART" "$TARGET_ROOT/.snapshots" 2>/dev/null || true
        mount -o "$(btrfs_mount_opts_for "$ROOT_PART"),subvol=@var_log" "$ROOT_PART" "$TARGET_ROOT/var/log" 2>/dev/null || true
        mount -o "$(btrfs_mount_opts_for "$ROOT_PART"),subvol=@var_cache" "$ROOT_PART" "$TARGET_ROOT/var/cache" 2>/dev/null || true
        mount -o "$(btrfs_mount_opts_for "$ROOT_PART"),subvol=@srv" "$ROOT_PART" "$TARGET_ROOT/srv" 2>/dev/null || true
        mount -o "$(btrfs_mount_opts_for "$ROOT_PART"),subvol=@tmp" "$ROOT_PART" "$TARGET_ROOT/tmp" 2>/dev/null || true
      else
        umount "$TARGET_ROOT"
        if [[ "$REFORMAT_ROOT" == "yes" ]]; then
          mount_btrfs_new_layout
          return
        else
          mount "$ROOT_PART" "$TARGET_ROOT"
          mkdir -p "$TARGET_ROOT"/{boot,home}
        fi
      fi
    else
      die "Falha ao montar a raiz Btrfs existente em $TARGET_ROOT: $ROOT_PART"
    fi
  else
    mount "$ROOT_PART" "$TARGET_ROOT"
    mkdir -p "$TARGET_ROOT"/{boot,home}
  fi

  mount_efi_partition

  if [[ "$SEPARATE_HOME" == "yes" && -n "$HOME_PART" ]]; then
    mkdir -p "$TARGET_ROOT/home"
    mount "$HOME_PART" "$TARGET_ROOT/home"
  fi
}

verify_storage_mount_layout() {
  begin_stage "storage.verify.mounts"
  mountpoint -q "$TARGET_ROOT" || die "A raiz alvo não está montada em $TARGET_ROOT"
  assert_mount_source "$TARGET_ROOT" "$ROOT_PART"
  mountpoint -q "$TARGET_ROOT/boot" || die "A ESP não está montada em $TARGET_ROOT/boot"
  assert_mount_source "$TARGET_ROOT/boot" "$EFI_PART"
  if [[ "$SEPARATE_HOME" == "yes" && -n "$HOME_PART" ]]; then
    mountpoint -q "$TARGET_ROOT/home" || die "/home separado não está montado."
    assert_mount_source "$TARGET_ROOT/home" "$HOME_PART"
  fi
  if [[ "$USE_BTRFS_LAYOUT" == "yes" ]]; then
    local root_opts
    root_opts="$(findmnt -no OPTIONS "$TARGET_ROOT" 2>/dev/null || true)"
    if [[ "$REFORMAT_ROOT" == "yes" || "$INSTALL_MODE" == "auto-disco-inteiro" ]]; then
      printf '%s' "$root_opts" | grep -q 'subvol=@' || die "A raiz Btrfs esperada não está montada com subvol=@"
    fi
  fi
  record_checkpoint "MOUNT_VERIFY_OK"
}

verify_generated_fstab() {
  begin_stage "storage.verify.fstab"
  [[ -f "$TARGET_ROOT/etc/fstab" ]] || die "fstab não foi gerado."
  grep -qE '[[:space:]]/[[:space:]]' "$TARGET_ROOT/etc/fstab" || die "fstab sem entrada para /."
  grep -qE '[[:space:]]/boot[[:space:]]' "$TARGET_ROOT/etc/fstab" || die "fstab sem entrada para /boot."
  if [[ "$SEPARATE_HOME" == "yes" && -n "$HOME_PART" ]]; then
    grep -qE '[[:space:]]/home[[:space:]]' "$TARGET_ROOT/etc/fstab" || die "fstab sem entrada para /home separado."
  fi
  record_checkpoint "FSTAB_VERIFY_OK"
}

prepare_storage() {
  case "$INSTALL_MODE" in
    auto-disco-inteiro)
      create_auto_partitions
      format_auto_partitions
      mount_btrfs_new_layout
      ;;
    usar-particoes-existentes|dual-boot-assistido)
      format_existing_partitions
      mount_existing_layout
      ;;
  esac
  verify_storage_mount_layout
}

resolve_display_manager() {
  DM_SERVICE=""

  case "$DESKTOP_VARIANT" in
    kde)
      if [[ "$DISPLAY_MANAGER_CHOICE" == "plasma-login-manager-se-disponivel" ]]; then
        if package_available_live plasma-login-manager; then
          DM_PACKAGE="plasma-login-manager"
          DM_SERVICE="plasmalogin"
          PKGS_DESKTOP+=" plasma-login-manager"
        else
          DM_PACKAGE="sddm"
          DM_SERVICE="sddm"
          PKGS_DESKTOP+=" sddm"
          append_warning "plasma-login-manager não estava disponível via pacman; usando sddm automaticamente."
        fi
      else
        DM_PACKAGE="sddm"
        DM_SERVICE="sddm"
        PKGS_DESKTOP+=" sddm"
      fi
      ;;
    gnome) DM_PACKAGE="gdm"; DM_SERVICE="gdm" ;;
    xfce)
      if [[ "$DISPLAY_MANAGER_CHOICE" == "sddm" ]]; then
        DM_PACKAGE="sddm"
        DM_SERVICE="sddm"
        PKGS_DESKTOP+=" sddm"
      else
        DM_PACKAGE="lightdm"
        DM_SERVICE="lightdm"
        PKGS_DESKTOP+=" lightdm lightdm-gtk-greeter"
      fi
      ;;
    *) DM_PACKAGE=""; DM_SERVICE="" ;;
  esac
}

build_base_packages() {
  PKGS_BASE="base base-devel linux-firmware pacman-contrib sudo bash-completion git curl wget rsync unzip zip p7zip man-db man-pages ntfs-3g dosfstools e2fsprogs xfsprogs btrfs-progs efibootmgr networkmanager xdg-user-dirs xdg-utils fastfetch htop btop"
}

build_kernel_packages() {
  PKGS_KERNELS="linux linux-headers linux-zen linux-zen-headers"
}

build_boot_packages() {
  [[ "$BOOTLOADER" == "grub" ]] && PKGS_BOOT="grub os-prober" || PKGS_BOOT=""
}

build_desktop_packages() {
  PKGS_DESKTOP=""
  resolve_display_manager
  case "$DESKTOP_VARIANT" in
    kde)
      if [[ "$DESKTOP_TIER" == "full" ]]; then
        PKGS_DESKTOP+=" plasma-meta kde-applications-meta packagekit-qt6 plasma-nm plasma-pa konsole dolphin ark partitionmanager"
      else
        PKGS_DESKTOP+=" plasma-meta kde-system-meta packagekit-qt6 plasma-nm plasma-pa konsole dolphin ark partitionmanager kate gwenview okular"
      fi
      ;;
    gnome)
      if [[ "$DESKTOP_TIER" == "full" ]]; then
        PKGS_DESKTOP+=" gnome gnome-extra gnome-tweaks gnome-software packagekit"
      else
        PKGS_DESKTOP+=" gnome gnome-tweaks gnome-software packagekit dconf-editor"
      fi
      ;;
    xfce)
      if [[ "$DESKTOP_TIER" == "full" ]]; then
        PKGS_DESKTOP+=" xfce4 xfce4-goodies"
      else
        PKGS_DESKTOP+=" xfce4 xfce4-goodies xfce4-terminal ristretto mousepad"
      fi
      ;;
    "")
      case "$WINDOW_MANAGER" in
        i3) PKGS_DESKTOP+=" xorg-server xorg-xinit i3-wm i3status dmenu alacritty picom feh lightdm lightdm-gtk-greeter network-manager-applet"; DM_PACKAGE="lightdm"; DM_SERVICE="lightdm" ;;
        sway) PKGS_DESKTOP+=" sway swaybg swaylock waybar foot xorg-xwayland lightdm lightdm-gtk-greeter network-manager-applet"; DM_PACKAGE="lightdm"; DM_SERVICE="lightdm" ;;
        hyprland) PKGS_DESKTOP+=" hyprland waybar foot xdg-desktop-portal-hyprland lightdm lightdm-gtk-greeter network-manager-applet"; DM_PACKAGE="lightdm"; DM_SERVICE="lightdm" ;;
      esac
      ;;
  esac
}

build_gamer_packages() {
  PKGS_GAMER=""
  PKGS_GPU=""
  MULTILIB_REQUIRED="no"
  [[ "$INSTALL_GAMER_TOOLS" != "yes" ]] && return
  MULTILIB_REQUIRED="yes"
  PKGS_GAMER="steam lutris mangohud gamemode gamescope vulkan-tools lib32-gamemode"
  case "$GPU_VENDOR" in
    nvidia) PKGS_GPU="nvidia-open nvidia-utils lib32-nvidia-utils nvidia-settings" ;;
    amd) PKGS_GPU="mesa vulkan-radeon lib32-mesa lib32-vulkan-radeon" ;;
    intel) PKGS_GPU="mesa vulkan-intel lib32-mesa lib32-vulkan-intel" ;;
    *) PKGS_GPU="mesa lib32-mesa" ;;
  esac
}

build_font_packages() {
  PKGS_FONTS=""
  [[ "$INSTALL_FONTS" != "yes" ]] && return
  case "$FONT_TIER" in
    full) PKGS_FONTS="noto-fonts noto-fonts-extra noto-fonts-cjk noto-fonts-emoji ttf-dejavu ttf-liberation ttf-jetbrains-mono ttf-fira-code ttf-hack ttf-jetbrains-mono-nerd ttf-firacode-nerd ttf-hack-nerd adobe-source-code-pro-fonts" ;;
    developer) PKGS_FONTS="noto-fonts noto-fonts-cjk noto-fonts-emoji ttf-dejavu ttf-liberation ttf-jetbrains-mono ttf-fira-code ttf-hack ttf-jetbrains-mono-nerd ttf-firacode-nerd ttf-hack-nerd" ;;
    *) PKGS_FONTS="noto-fonts noto-fonts-cjk noto-fonts-emoji ttf-dejavu ttf-liberation" ;;
  esac
}

build_service_packages() {
  PKGS_SERVICES="iwd"
  [[ "$ENABLE_BLUETOOTH" == "yes" ]] && PKGS_SERVICES+=" bluez bluez-utils"
  [[ "$ENABLE_PRINTING" == "yes" ]] && PKGS_SERVICES+=" cups system-config-printer"
  [[ "$ENABLE_FIREWALL" == "yes" ]] && PKGS_SERVICES+=" ufw"
  [[ "$ENABLE_SSH" == "yes" ]] && PKGS_SERVICES+=" openssh"
  [[ "$ENABLE_ZRAM" == "yes" ]] && PKGS_SERVICES+=" zram-generator"
  [[ "$ENABLE_FLATPAK" == "yes" ]] && PKGS_SERVICES+=" flatpak"
  [[ "$ENABLE_REFLECTOR" == "yes" ]] && PKGS_SERVICES+=" reflector"
  if is_btrfs_root_enabled; then
    PKGS_SERVICES+=" snapper"
    [[ "$BOOTLOADER" == "grub" ]] && PKGS_SERVICES+=" grub-btrfs"
  fi
}

build_multimedia_packages() {
  PKGS_MULTIMEDIA=""
  [[ "$INSTALL_MULTIMEDIA" == "yes" ]] && PKGS_MULTIMEDIA="pipewire pipewire-pulse pipewire-alsa pipewire-jack wireplumber ffmpeg gst-libav gst-plugins-good gst-plugins-bad gst-plugins-ugly vlc"
}

build_dev_packages() {
  PKGS_DEV=""
  [[ "$INSTALL_DEV_TOOLS" == "yes" ]] && PKGS_DEV="github-cli ripgrep fd jq yq python python-pip"
}

build_app_packages() {
  PKGS_APPS=""
  [[ "$INSTALL_COMMON_APPS" == "yes" ]] && PKGS_APPS+=" file-roller gvfs gvfs-mtp"
  [[ "$EDITOR_CHOICE" == "nano" ]] && PKGS_APPS+=" nano"
  case "$BROWSER_CHOICE" in
    firefox) PKGS_APPS+=" firefox" ;;
    chromium) PKGS_APPS+=" chromium" ;;
    brave-via-aur) ;;
  esac
  case "$DESKTOP_VARIANT" in
    kde) PKGS_APPS+=" kdeconnect gwenview okular spectacle"; [[ "$INSTALL_BTRFS_ASSISTANT" == "yes" ]] && PKGS_APPS+=" btrfs-assistant" ;;
    gnome) PKGS_APPS+=" eog gnome-calculator" ;;
    xfce) PKGS_APPS+=" thunar-volman" ;;
  esac
}

build_all_packages() {
  build_base_packages
  build_kernel_packages
  build_boot_packages
  build_service_packages
  build_multimedia_packages
  build_dev_packages
  build_desktop_packages
  build_gamer_packages
  build_font_packages
  build_app_packages
  PKGS_EXTRA="$(sanitize_pkg_list "$(cpu_microcode_pkg) $PKGS_BASE $PKGS_KERNELS $PKGS_BOOT $PKGS_SERVICES $PKGS_MULTIMEDIA $PKGS_DEV $PKGS_DESKTOP $PKGS_GAMER $PKGS_GPU $PKGS_FONTS $PKGS_APPS")"
}

install_base_system() {
  begin_stage "base.pacstrap"
  build_all_packages
  enable_multilib_live_if_needed
  log "Pacotes selecionados:"
  echo "$PKGS_EXTRA"
  read -r -a pkg_array <<< "$PKGS_EXTRA"

  if network_is_up; then
    local available=() missing=() pkg
    for pkg in "${pkg_array[@]}"; do
      if pacman -Si "$pkg" >/dev/null 2>&1; then
        available+=("$pkg")
      else
        missing+=("$pkg")
      fi
    done
    if (( ${#missing[@]} > 0 )); then
      warn "Pacotes indisponíveis no repositório atual e removidos da instalação: ${missing[*]}"
    fi
    pkg_array=("${available[@]}")
  fi

  (( ${#pkg_array[@]} > 0 )) || die "Nenhum pacote válido restou para instalar via pacstrap."
  printf '%s
' "${pkg_array[@]}" > "$LOG_DIR/pacstrap-packages.txt"
  pacstrap -K "$TARGET_ROOT" "${pkg_array[@]}"
  genfstab -U "$TARGET_ROOT" > "$TARGET_ROOT/etc/fstab"
  verify_generated_fstab
  cp -f "$LOG_DIR/pacstrap-packages.txt" "$TARGET_ROOT/root/pacstrap-packages.txt" 2>/dev/null || true
  record_checkpoint "PACSTRAP_OK packages=${#pkg_array[@]}"
}

write_chroot_script() {
  save_config
  cp "$CONFIG_EXPORT" "$TARGET_ROOT/root/final-config.env"

  cat > "$TARGET_ROOT/root/post-install-v3.4.5.sh" <<'EOF'
#!/usr/bin/env bash
set -Eeuo pipefail

source /root/final-config.env
DM_PACKAGE="${DM_PACKAGE:-$DM_SERVICE}"
CHROOT_LOG="/root/post-install.log"
CHROOT_CHECKPOINTS="/root/install-logs/chroot-checkpoints.log"
mkdir -p /root/install-logs
touch "$CHROOT_LOG" "$CHROOT_CHECKPOINTS"
exec > >(tee -a "$CHROOT_LOG") 2>&1

log() { printf "\n[chroot %s] %s\n" "$(date +'%F %T')" "$*"; }
checkpoint() { printf '%s | %s
' "$(date +'%F %T')" "$*" | tee -a "$CHROOT_CHECKPOINTS" >/dev/null; }
on_error() {
  local line="$1" cmd="$2"
  checkpoint "ERROR line=$line cmd=$cmd"
  printf "\n[chroot ERRO] Linha %s: %s\n" "$line" "$cmd" >&2
  exit 1
}
trap 'on_error "$LINENO" "$BASH_COMMAND"' ERR
existing_user_groups_csv() {
  local groups=()
  local g
  for g in wheel audio video storage network lp; do
    getent group "$g" >/dev/null 2>&1 && groups+=("$g")
  done
  local IFS=,
  printf '%s' "${groups[*]}"
}
current_root_subvol_option() {
  findmnt -no OPTIONS / 2>/dev/null | tr ',' '\n' | grep '^subvol=' | head -n1 || true
}

checkpoint 'base.start'
log "Configuração base..."
echo "$HOSTNAME" > /etc/hostname

cat > /etc/hosts <<HOSTS
127.0.0.1 localhost
::1 localhost
127.0.1.1 ${HOSTNAME}.localdomain ${HOSTNAME}
HOSTS

ln -sf "/usr/share/zoneinfo/$TIMEZONE" /etc/localtime
hwclock --systohc

if grep -q "^#${LOCALE}" /etc/locale.gen; then
  sed -i "s/^#\(${LOCALE}\)/\1/" /etc/locale.gen
elif ! grep -q "^${LOCALE}" /etc/locale.gen; then
  echo "${LOCALE}" >> /etc/locale.gen
fi
locale-gen

cat > /etc/locale.conf <<LCONF
LANG=${LOCALE}
LCONF

cat > /etc/vconsole.conf <<KCONF
KEYMAP=${KEYMAP}
KCONF

checkpoint 'mkinitcpio.start'
log "mkinitcpio..."
sed -i 's/^HOOKS=.*/HOOKS=(base systemd autodetect microcode modconf kms keyboard sd-vconsole block filesystems fsck)/' /etc/mkinitcpio.conf
mkinitcpio -P
checkpoint 'mkinitcpio.ok'

if [[ "$MULTILIB_REQUIRED" == "yes" ]]; then
  log "Habilitando multilib no sistema instalado..."
  sed -i '/^\#\[multilib\]$/,/^#Include/ s/^#//' /etc/pacman.conf
  pacman -Sy --noconfirm || true
fi

log "Contas de usuário..."
echo "root:${ROOT_PASSWORD}" | chpasswd
USER_GROUPS="$(existing_user_groups_csv)"
if id "$USERNAME" >/dev/null 2>&1; then
  if [[ -n "$USER_GROUPS" ]]; then
    usermod -c "$FULLNAME" -G "$USER_GROUPS" -s /bin/bash "$USERNAME"
  else
    usermod -c "$FULLNAME" -s /bin/bash "$USERNAME"
  fi
else
  if [[ -n "$USER_GROUPS" ]]; then
    useradd -m -G "$USER_GROUPS" -s /bin/bash -c "$FULLNAME" "$USERNAME"
  else
    useradd -m -s /bin/bash -c "$FULLNAME" "$USERNAME"
  fi
fi
echo "${USERNAME}:${USER_PASSWORD}" | chpasswd
sed -i 's/^# %wheel ALL=(ALL:ALL) ALL/%wheel ALL=(ALL:ALL) ALL/' /etc/sudoers

log "Serviços systemd..."
systemctl enable NetworkManager
[[ "$ENABLE_BLUETOOTH" == "yes" ]] && systemctl enable bluetooth
[[ "$ENABLE_PRINTING" == "yes" ]] && systemctl enable cups
[[ "$ENABLE_SSH" == "yes" ]] && systemctl enable sshd
if [[ "$ENABLE_FIREWALL" == "yes" ]] && systemctl list-unit-files | grep -q '^ufw\.service'; then systemctl enable ufw; fi
if [[ "$ENABLE_REFLECTOR" == "yes" ]] && systemctl list-unit-files | grep -q '^reflector\.timer'; then systemctl enable reflector.timer; fi
if [[ "$ENABLE_FSTRIM" == "yes" ]] && systemctl list-unit-files | grep -q '^fstrim\.timer'; then systemctl enable fstrim.timer; fi
if [[ "$ENABLE_PACCACHE" == "yes" ]] && systemctl list-unit-files | grep -q '^paccache\.timer'; then systemctl enable paccache.timer; fi
if [[ "$WIFI_BACKEND_USED" == "iwd" ]] && systemctl list-unit-files | grep -q '^iwd\.service'; then systemctl enable iwd; fi
[[ -n "$DM_SERVICE" ]] && systemctl list-unit-files | grep -q "^${DM_SERVICE}\.service" && systemctl enable "$DM_SERVICE"

if [[ "$ENABLE_ZRAM" == "yes" ]]; then
  mkdir -p /etc/systemd/zram-generator.conf.d
  cat > /etc/systemd/zram-generator.conf.d/default.conf <<ZRAM
[zram0]
zram-size = ram / 2
compression-algorithm = zstd
ZRAM
fi

if [[ "$WIFI_BACKEND_USED" == "iwd" ]]; then
  mkdir -p /etc/NetworkManager/conf.d
  cat > /etc/NetworkManager/conf.d/wifi_backend.conf <<NM_IWD
[device]
wifi.backend=iwd
NM_IWD
fi

if [[ "$BOOTLOADER" == "systemd-boot" ]]; then
  mkdir -p /etc/pacman.d/hooks
  cat > /etc/pacman.d/hooks/95-systemd-boot.hook <<HOOK
[Trigger]
Type = Package
Operation = Upgrade
Target = systemd

[Action]
Description = Atualizando systemd-boot...
When = PostTransaction
Exec = /usr/bin/bootctl update
HOOK
fi

if findmnt -no FSTYPE / | grep -qx btrfs; then
  log "Configurando Snapper..."
  mkdir -p /.snapshots
  mkdir -p /etc/snapper/configs
  cat > /etc/snapper/configs/root <<SNAPCFG
SUBVOLUME="/"
FSTYPE="btrfs"
QGROUP=""
SPACE_LIMIT="0.5"
FREE_LIMIT="0.2"
ALLOW_USERS="${USERNAME}"
ALLOW_GROUPS=""
SYNC_ACL="no"
BACKGROUND_COMPARISON="yes"
NUMBER_CLEANUP="yes"
NUMBER_MIN_AGE="1800"
NUMBER_LIMIT="10"
NUMBER_LIMIT_IMPORTANT="5"
TIMELINE_CREATE="yes"
TIMELINE_CLEANUP="yes"
TIMELINE_MIN_AGE="1800"
TIMELINE_LIMIT_HOURLY="5"
TIMELINE_LIMIT_DAILY="7"
TIMELINE_LIMIT_WEEKLY="4"
TIMELINE_LIMIT_MONTHLY="3"
TIMELINE_LIMIT_YEARLY="0"
EMPTY_PRE_POST_CLEANUP="yes"
EMPTY_PRE_POST_MIN_AGE="1800"
SNAPCFG
  chmod 750 /.snapshots
  systemctl enable snapper-timeline.timer
  systemctl enable snapper-cleanup.timer
  if systemctl list-unit-files | grep -q '^grub-btrfs.path'; then
    systemctl enable grub-btrfs.path
  fi
fi

checkpoint 'bootloader.start'
log "Bootloader..."
mountpoint -q /boot || { printf "\n[chroot ERRO] /boot não está montado.\n" >&2; exit 1; }
BOOT_FSTYPE="$(findmnt -no FSTYPE /boot 2>/dev/null || true)"
[[ "$BOOT_FSTYPE" == "vfat" ]] || { printf "\n[chroot ERRO] /boot precisa estar em vfat/ESP para esta instalação UEFI. Obtido: %s\n" "$BOOT_FSTYPE" >&2; exit 1; }
if [[ "$BOOTLOADER" == "grub" ]]; then
  grub-install --target=x86_64-efi --efi-directory=/boot --bootloader-id=GRUB
  if grep -q '^#\?GRUB_DISABLE_OS_PROBER=' /etc/default/grub; then
    sed -i 's/^#\?GRUB_DISABLE_OS_PROBER=.*/GRUB_DISABLE_OS_PROBER=false/' /etc/default/grub
  else
    echo 'GRUB_DISABLE_OS_PROBER=false' >> /etc/default/grub
  fi
  if ! grep -q '^GRUB_BTRFS_OVERRIDE_BOOT_PARTITION_DETECTION=' /etc/default/grub; then
    echo 'GRUB_BTRFS_OVERRIDE_BOOT_PARTITION_DETECTION=true' >> /etc/default/grub
  fi
  sed -i 's/^GRUB_TIMEOUT=.*/GRUB_TIMEOUT=5/' /etc/default/grub || true
  if ! command -v os-prober >/dev/null 2>&1; then log "os-prober não está disponível; entradas de outros sistemas dependerão do firmware/varredura manual."; fi
  grub-mkconfig -o /boot/grub/grub.cfg
else
  bootctl --esp-path=/boot install
  ROOT_UUID="$(blkid -s UUID -o value "$(findmnt -no SOURCE /)")"
  ROOT_SUBVOL_OPT="$(current_root_subvol_option || true)"
  mkdir -p /boot/loader/entries

  emit_entry() {
    local title="$1" kernel="$2" initramfs="$3" output="$4"
    local options_line
    options_line="options root=UUID=${ROOT_UUID} rw quiet loglevel=3 nowatchdog"
    if findmnt -no FSTYPE / | grep -qx btrfs && [[ -n "$ROOT_SUBVOL_OPT" ]]; then
      options_line="options root=UUID=${ROOT_UUID} rootfstype=btrfs rootflags=${ROOT_SUBVOL_OPT} rw quiet loglevel=3 nowatchdog"
    fi
    {
      echo "title   $title"
      echo "linux   $kernel"
      pacman -Q intel-ucode >/dev/null 2>&1 && echo 'initrd  /intel-ucode.img'
      pacman -Q amd-ucode >/dev/null 2>&1 && echo 'initrd  /amd-ucode.img'
      echo "initrd  $initramfs"
      echo "${options_line}"
    } > "$output"
  }

  pacman -Q linux >/dev/null 2>&1 && emit_entry "Arch Linux" "/vmlinuz-linux" "/initramfs-linux.img" "/boot/loader/entries/arch-linux.conf"
  pacman -Q linux-zen >/dev/null 2>&1 && emit_entry "Arch Linux (zen)" "/vmlinuz-linux-zen" "/initramfs-linux-zen.img" "/boot/loader/entries/arch-linux-zen.conf"

  if [[ -d /boot/EFI/Microsoft/Boot ]]; then
    cat > /boot/loader/entries/windows.conf <<WINEFI
title   Windows Boot Manager
efi     /EFI/Microsoft/Boot/bootmgfw.efi
WINEFI
  fi

  if [[ -d /boot/EFI/ubuntu ]]; then
    cat > /boot/loader/entries/ubuntu.conf <<UBUEFI
title   Ubuntu
efi     /EFI/ubuntu/shimx64.efi
UBUEFI
  fi

  DEFAULT_ENTRY="arch-linux-zen.conf"
  [[ -f /boot/loader/entries/arch-linux-zen.conf ]] || DEFAULT_ENTRY="arch-linux.conf"
  cat > /boot/loader/loader.conf <<LDR
default ${DEFAULT_ENTRY}
timeout 5
console-mode max
editor no
LDR
fi
checkpoint 'bootloader.ok'

log "Pós-instalação refinada por ambiente..."
mkdir -p /etc/environment.d
cat > /etc/environment.d/90-desktop.conf <<ENVIRON
EDITOR=${EDITOR_CHOICE}
ENVIRON

case "$DESKTOP_VARIANT" in
  kde)
    if [[ "$DM_SERVICE" == "sddm" ]]; then
      mkdir -p /etc/sddm.conf.d
      cat > /etc/sddm.conf.d/20-theme.conf <<SDDMCONF
[Theme]
Current=breeze
CursorTheme=breeze_cursors
EnableAvatars=true
SDDMCONF
    fi
    cat > /etc/environment.d/91-kde.conf <<KDEENV
GTK_USE_PORTAL=1
KDEENV
    ;;
  gnome)
    cat > /etc/environment.d/91-gnome.conf <<GNOMEENV
GTK_USE_PORTAL=1
GNOMEENV
    ;;
  xfce)
    mkdir -p /etc/skel/.config/xfce4/xfconf/xfce-perchannel-xml
    ;;
esac

runuser -l "$USERNAME" -c 'xdg-user-dirs-update' || true

if [[ "$WIFI_CONNECTED" == "yes" ]]; then
  mkdir -p /root/install-logs
  cat > /root/install-logs/network-profile.txt <<NETINFO
Wi-Fi backend usado: $WIFI_BACKEND_USED
Wi-Fi interface: $WIFI_IFACE
Wi-Fi SSID: $WIFI_SSID_SELECTED
Wi-Fi hidden: $WIFI_HIDDEN_NETWORK
Wi-Fi profile name: $WIFI_PROFILE_NAME
NETINFO
fi

if [[ "$INSTALL_PIKAUR" == "yes" ]]; then
  if ping -c 1 -W 3 archlinux.org >/dev/null 2>&1 || ping -c 1 -W 3 1.1.1.1 >/dev/null 2>&1; then
    log "Instalando pikaur..."
    runuser -l "$USERNAME" -c 'mkdir -p ~/builds && cd ~/builds && rm -rf pikaur && git clone https://aur.archlinux.org/pikaur.git && cd pikaur && makepkg -si --noconfirm' || true
  else
    log "Sem rede no chroot; pulando instalação do pikaur."
  fi
fi

if [[ "$BROWSER_CHOICE" == "brave-via-aur" && "$INSTALL_PIKAUR" == "yes" ]]; then
  if command -v pikaur >/dev/null 2>&1; then
    log "Instalando Brave via AUR..."
    runuser -l "$USERNAME" -c 'pikaur -S --noconfirm brave-bin' || true
  else
    log "pikaur não disponível; Brave via AUR foi pulado."
  fi
fi

if [[ "$ENABLE_FIREWALL" == "yes" ]]; then
  ufw default deny incoming || true
  ufw default allow outgoing || true
  yes | ufw enable || true
fi

if [[ "$ENABLE_FLATPAK" == "yes" ]]; then
  flatpak remote-add --if-not-exists flathub https://flathub.org/repo/flathub.flatpakrepo || true
fi

if findmnt -no FSTYPE / | grep -qx btrfs; then
  snapper -c root create -d "snapshot inicial pós-instalação" || true
fi

mkdir -p /root/install-logs
cp -f "$CHROOT_LOG" /root/install-logs/post-install.log
checkpoint 'postinstall.ok'
log "Pós-instalação concluída."
EOF

  chmod +x "$TARGET_ROOT/root/post-install-v3.4.5.sh"
}

run_chroot() {
  begin_stage "system.chroot"
  if ! arch-chroot "$TARGET_ROOT" /root/post-install-v3.4.5.sh; then
    warn "Falha no pós-instalação dentro do chroot. Tentando copiar logs parciais para o sistema alvo..."
    copy_logs_to_target || true
    die "Falha na execução do pós-instalação em chroot."
  fi
  record_checkpoint "CHROOT_OK"
}

copy_logs_to_target() {
  begin_stage "logs.finalize"
  mkdir -p "$TARGET_ROOT/root/install-logs"
  cp -f "$RUNTIME_LOG" "$TARGET_ROOT/root/install-logs/live-installer.log"
  cp -f "$COMMAND_TRACE" "$TARGET_ROOT/root/install-logs/commands.log"
  cp -f "$CHECKPOINT_FILE" "$TARGET_ROOT/root/install-logs/checkpoints.log"
  cp -f "$ROLLBACK_PLAN" "$TARGET_ROOT/root/install-logs/rollback-plan.sh"
  cp -f "$CONFIG_EXPORT" "$TARGET_ROOT/root/install-logs/final-config.env"
  cp -f "$SCAN_REPORT" "$TARGET_ROOT/root/install-logs/storage-scan.txt"
  [[ -f "$PARTITION_TABLE_BACKUP" ]] && cp -f "$PARTITION_TABLE_BACKUP" "$TARGET_ROOT/root/install-logs/partition-table.sgdisk"
}

copy_wifi_profiles_to_target() {
  if [[ "$WIFI_CONNECTED" != "yes" ]]; then
    return
  fi

  mkdir -p "$TARGET_ROOT/root/install-logs"

  if [[ "$WIFI_BACKEND_USED" == "NetworkManager" ]] && compgen -G '/etc/NetworkManager/system-connections/*.nmconnection' >/dev/null 2>&1; then
    mkdir -p "$TARGET_ROOT/etc/NetworkManager/system-connections"
    cp -f /etc/NetworkManager/system-connections/*.nmconnection "$TARGET_ROOT/etc/NetworkManager/system-connections/" 2>/dev/null || true
    chmod 600 "$TARGET_ROOT"/etc/NetworkManager/system-connections/*.nmconnection 2>/dev/null || true
  fi

  if [[ "$WIFI_BACKEND_USED" == "iwd" ]]; then
    if [[ -d /var/lib/iwd ]]; then
      mkdir -p "$TARGET_ROOT/var/lib/iwd"
      cp -a /var/lib/iwd/. "$TARGET_ROOT/var/lib/iwd/" 2>/dev/null || true
    fi
    if [[ -f /etc/iwd/main.conf ]]; then
      mkdir -p "$TARGET_ROOT/etc/iwd"
      cp -f /etc/iwd/main.conf "$TARGET_ROOT/etc/iwd/main.conf" 2>/dev/null || true
    fi
  fi
}

write_summary() {
  begin_stage "summary.write"
  cat > "$TARGET_ROOT/root/INSTALACAO-V3.4.5-RESUMO.txt" <<EOF
Arch Auto Install v3.4.5-h1 - Resumo

Versão:              $VERSION
Modo:                $INSTALL_MODE
Dual boot:           $DUAL_BOOT_MODE
Desktop:             $DESKTOP_VARIANT
Tier desktop:        $DESKTOP_TIER
WM:                  $WINDOW_MANAGER
Hostname:            $HOSTNAME
Usuário:             $USERNAME
Bootloader:          $BOOTLOADER
GPU:                 $GPU_VENDOR
Display manager:     $DISPLAY_MANAGER_CHOICE
Fontes:              $FONT_TIER
Disco:               $TARGET_DISK
ESP:                 $EFI_PART
ROOT:                $ROOT_PART
HOME:                $HOME_PART
SWAP:                $SWAP_PART
Kernels:             ${PKGS_KERNELS:-linux linux-zen}
Wi‑Fi iface:         $WIFI_IFACE
Wi‑Fi SSID:          $WIFI_SSID_SELECTED
Wi‑Fi conectado:     $WIFI_CONNECTED
Backend Wi‑Fi:       $WIFI_BACKEND_USED
Perfil Wi‑Fi:        $WIFI_PROFILE_NAME
Rede oculta:         $WIFI_HIDDEN_NETWORK
Scan report:         /root/install-logs/storage-scan.txt
Logs:                /root/install-logs
EOF
}

show_summary_before_install() {
  begin_stage "validation.summary"
  ui_header "Resumo antes da instalação"
  echo "Modo:              $INSTALL_MODE"
  echo "Dual boot:         $DUAL_BOOT_MODE"
  echo "Desktop:           ${DESKTOP_VARIANT:-n/a}"
  echo "Tier:              ${DESKTOP_TIER:-n/a}"
  echo "WM:                ${WINDOW_MANAGER:-n/a}"
  echo "Bootloader:        $BOOTLOADER"
  echo "GPU:               $GPU_VENDOR"
  echo "Display manager:   $DISPLAY_MANAGER_CHOICE"
  echo "Fontes:            $FONT_TIER"
  echo "Hostname:          $HOSTNAME"
  echo "Usuário:           $USERNAME"
  echo "Disco:             ${TARGET_DISK:-n/a}"
  echo "ESP:               ${EFI_PART:-auto}"
  echo "ROOT:              ${ROOT_PART:-auto}"
  echo "HOME:              ${HOME_PART:-integrado}"
  echo "SWAP:              ${SWAP_PART:-auto/desabilitado}"
  echo "Kernels:           ${PKGS_KERNELS:-linux linux-zen}"
  echo "Pikaur:            $INSTALL_PIKAUR"
  echo "Wi‑Fi iface:       ${WIFI_IFACE:-n/a}"
  echo "Wi‑Fi SSID:        ${WIFI_SSID_SELECTED:-n/a}"
  echo "Wi‑Fi conectado:   ${WIFI_CONNECTED:-no}"
  echo "Backend Wi‑Fi:     ${WIFI_BACKEND_USED:-n/a}"
  echo "Perfil Wi‑Fi:      ${WIFI_PROFILE_NAME:-n/a}"
  echo "Rede oculta:       ${WIFI_HIDDEN_NETWORK:-no}"
  echo "Log atual:         $RUNTIME_LOG"
  echo "Storage scan:      $SCAN_REPORT"
}

main() {
  begin_stage "preflight"
  preflight
  record_checkpoint "PREFLIGHT_OK"
  begin_stage "storage.scan"
  scan_storage_layout
  record_checkpoint "SCAN_OK"
  show_banner
  show_storage_scan_summary
  ensure_network_ready || true

  ask_install_mode
  ask_profile
  ask_hardware
  BOOTLOADER="$(ui_select_one "Escolha o bootloader" "grub" "systemd-boot")"
  ask_display_manager
  ask_fonts
  ask_apps_and_services
  ask_storage_options
  collect_identity

  case "$INSTALL_MODE" in
    auto-disco-inteiro) select_disk_smart ;;
    usar-particoes-existentes) select_existing_partitions ;;
    dual-boot-assistido) select_dualboot_partitions_smart ;;
  esac

  build_all_packages
  begin_stage "validation.run"
  run_validations
  record_checkpoint "VALIDATIONS_OK"
  show_summary_before_install
  show_validation_summary
  echo
  if [[ "$INSTALL_MODE" == "auto-disco-inteiro" ]]; then
    ui_confirm "Confirma APAGAR COMPLETAMENTE o disco selecionado e iniciar a instalação?" || die "Cancelado."
    ui_confirm_typed "Esta ação vai destruir a tabela de partição e os dados do disco $TARGET_DISK." "APAGAR" || die "Confirmação digitada ausente."
  elif [[ "$INSTALL_MODE" == "dual-boot-assistido" ]]; then
    ui_confirm "Confirma iniciar a instalação em modo dual boot usando as partições selecionadas?" || die "Cancelado."
    ui_confirm_typed "Confirme que você revisou EFI_PART=$EFI_PART e ROOT_PART=$ROOT_PART e que NÃO quer tocar na ESP além da instalação do bootloader." "DUALBOOT" || die "Confirmação digitada ausente."
  else
    ui_confirm "Confirma iniciar a instalação usando as partições selecionadas?" || die "Cancelado."
  fi

  begin_stage "storage.prepare"
  prepare_storage
  record_checkpoint "STORAGE_READY"
  install_base_system
  begin_stage "network.persist"
  copy_wifi_profiles_to_target
  record_checkpoint "WIFI_PROFILE_COPY_OK"
  begin_stage "system.write-chroot"
  write_chroot_script
  record_checkpoint "CHROOT_SCRIPT_OK"
  run_chroot
  copy_logs_to_target
  write_summary

  ui_header "Instalação concluída"
  ui_text "Resumo salvo em /root/INSTALACAO-V3.4.5-RESUMO.txt"
  ui_text "Logs salvos em /root/install-logs (live-installer.log, commands.log, checkpoints.log, rollback-plan.sh)"
  if [[ "$AUTO_REBOOT" == "yes" ]]; then
    safe_umount_all
    reboot
  else
    echo
    echo "Passos finais:"
    echo "  1) umount -R /mnt"
    echo "  2) reboot"
  fi
}

main "$@"
