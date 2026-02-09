#!/bin/bash
# ============================================================================
# Arch Linux Chroot Setup — Étapes 6 à 11 du guide durci
# Compatible : kernel linux (pas linux-hardened) + Docker + VMware + Hyprland
# ============================================================================
set -euo pipefail

# --- Couleurs & helpers ---
RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; CYAN='\033[0;36m'; NC='\033[0m'
info()  { echo -e "${CYAN}[ℹ]${NC} $*"; }
ok()    { echo -e "${GREEN}[✓]${NC} $*"; }
warn()  { echo -e "${YELLOW}[⚠]${NC} $*"; }
step()  { echo -e "\n${GREEN}━━━ ÉTAPE $1 ━━━${NC}"; }

# --- Récupération des variables ---
HOSTNAME_CUSTOM=$1
USER_CUSTOM=$2
LUKS_UUID=$3

# Mots de passe via fichier sécurisé (créé par install.sh)
PASS_FILE="/root/.setup_pass"
[[ -f "$PASS_FILE" ]] || { echo "Fichier mot de passe introuvable"; exit 1; }
PASS_ROOT=$(sed -n '1p' "$PASS_FILE")
PASS_USER=$(sed -n '2p' "$PASS_FILE")

# ============================================================================
# ÉTAPE 6 — Localisation
# ============================================================================
step "6 — Localisation"

ln -sf /usr/share/zoneinfo/Europe/Paris /etc/localtime
hwclock --systohc
sed -i 's/^#fr_FR.UTF-8 UTF-8/fr_FR.UTF-8 UTF-8/' /etc/locale.gen
locale-gen
echo "LANG=fr_FR.UTF-8" > /etc/locale.conf
echo "KEYMAP=fr-latin1" > /etc/vconsole.conf
ok "Fuseau horaire, locales et clavier configurés"

# ============================================================================
# ÉTAPE 7 — Réseau
# ============================================================================
step "7 — Nom de la machine"

echo "$HOSTNAME_CUSTOM" > /etc/hostname
ok "Hostname : $HOSTNAME_CUSTOM"

# ============================================================================
# ÉTAPE 8 — Sécurité des comptes
# ============================================================================
step "8 — Comptes et sudo"

echo "root:$PASS_ROOT" | chpasswd
useradd -m -G wheel,docker "$USER_CUSTOM"
echo "$USER_CUSTOM:$PASS_USER" | chpasswd
sed -i 's/^# %wheel ALL=(ALL:ALL) ALL/%wheel ALL=(ALL:ALL) ALL/' /etc/sudoers
ok "Root + utilisateur '$USER_CUSTOM' (wheel,docker) configurés"

# ============================================================================
# ÉTAPE 9 — Initramfs (hooks)
# ============================================================================
step "9 — Configuration de l'Initramfs"

sed -i 's/^HOOKS=.*/HOOKS=(base systemd autodetect microcode modconf kms keyboard sd-vconsole block sd-encrypt sd-lvm2 filesystems fsck)/' /etc/mkinitcpio.conf
ok "Hooks mkinitcpio configurés (sd-encrypt + sd-lvm2)"

# ============================================================================
# ÉTAPE 10 — Configuration du Boot (UKI)
# ============================================================================
step "10 — Unified Kernel Image (UKI)"

# 10.3 — Kernel cmdline
mkdir -p /etc/kernel
echo "rw root=/dev/mapper/vg0-root quiet rd.luks.name=${LUKS_UUID}=cryptlvm rd.luks.options=discard rootflags=subvol=@" > /etc/kernel/cmdline
ok "Cmdline configuré avec UUID LUKS"

# 10.4 — Preset UKI (pour kernel linux standard)
cat <<'EOT' > /etc/mkinitcpio.d/linux.preset
ALL_kver="/boot/vmlinuz-linux"
PRESETS=('default')
default_config="/etc/mkinitcpio.conf"
default_uki="/efi/EFI/Linux/arch-linux.efi"
EOT
ok "Preset UKI configuré"

# 10.6 — Génération de l'UKI
mkdir -p /efi/EFI/Linux
mkinitcpio -p linux
ok "UKI générée : /efi/EFI/Linux/arch-linux.efi"

# ============================================================================
# ÉTAPE 11 — Secure Boot
# ============================================================================
step "11 — Secure Boot"

# 11.1 — systemd-boot
bootctl install
ok "systemd-boot installé"

# 11.2 — Clés Secure Boot
sbctl create-keys && sbctl enroll-keys
sbctl sign -s /efi/EFI/Linux/arch-linux.efi
ok "UKI signée avec clés Secure Boot personnelles"

# 11.3 — Pacman Hook pour re-signature automatique
mkdir -p /etc/pacman.d/hooks
cat <<'EOT' > /etc/pacman.d/hooks/95-sbctl.hook
[Trigger]
Operation = Install
Operation = Upgrade
Type = Path
Target = usr/lib/modules/*/vmlinuz
Target = efi/EFI/Linux/*.efi

[Action]
Description = Re-signature automatique de l'UKI avec sbctl...
When = PostTransaction
Exec = /usr/bin/sbctl sign -s /efi/EFI/Linux/arch-linux.efi
EOT
ok "Pacman Hook sbctl configuré (re-signature auto à chaque mise à jour noyau)"

# 11.4 — Activation des services
systemctl enable NetworkManager docker vmtoolsd vmware-vmblock-fuse
ok "Services activés : NetworkManager, Docker, VMware Tools"

# ============================================================================
# HYPRLAND — Configuration VMware Ready
# ============================================================================
step "BONUS — Hyprland (VMware Ready)"

pacman -S --noconfirm hyprland foot waybar wofi mako swaybg wl-clipboard

sudo -u "$USER_CUSTOM" bash <<USEREOF
mkdir -p /home/$USER_CUSTOM/.config/{hypr,waybar,foot}

cat <<'HYPRCONF' > /home/$USER_CUSTOM/.config/hypr/hyprland.conf
# === VMware Compatibility ===
env = WLR_NO_HARDWARE_CURSORS,1
env = WLR_RENDERER_ALLOW_SOFTWARE,1
env = QT_QPA_PLATFORM,wayland

# === Moniteur ===
monitor = ,preferred,auto,1

# === Input ===
input {
    kb_layout = fr
}

# === Style ===
general {
    gaps_in = 5
    gaps_out = 10
    border_size = 2
    col.active_border = 0xff33ccff
}

decoration {
    rounding = 8
    drop_shadow = false
    blur {
        enabled = false
    }
}

# === Keybinds ===
\$mainMod = SUPER
bind = \$mainMod, RETURN, exec, foot
bind = \$mainMod, Q, killactive,
bind = \$mainMod, SPACE, exec, wofi --show drun
bind = \$mainMod, M, exit,

# === Autostart ===
exec-once = waybar & mako & swaybg -c '#1e1e2e'
HYPRCONF
USEREOF

ok "Hyprland configuré pour VMware"

# ============================================================================
# Nettoyage
# ============================================================================
rm -f "$PASS_FILE"
unset PASS_ROOT PASS_USER

echo ""
echo -e "${GREEN}━━━ Chroot terminé — Retour à install.sh ━━━${NC}"
