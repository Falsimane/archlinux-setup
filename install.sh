#!/bin/bash
# ============================================================================
# Arch Linux Automated Install — Étapes 1 à 11 du guide durci
# Compatible : kernel linux (pas linux-hardened) + Docker + VMware + Hyprland
# ============================================================================
set -euo pipefail

# --- Couleurs & helpers ---
RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; CYAN='\033[0;36m'; NC='\033[0m'
info()  { echo -e "${CYAN}[ℹ]${NC} $*"; }
ok()    { echo -e "${GREEN}[✓]${NC} $*"; }
warn()  { echo -e "${YELLOW}[⚠]${NC} $*"; }
die()   { echo -e "${RED}[✗]${NC} $*" >&2; exit 1; }
step()  { echo -e "\n${GREEN}━━━ ÉTAPE $1 ━━━${NC}"; }

# ============================================================================
# ÉTAPE 1 — Environnement et Préparation
# ============================================================================
step "1 — Vérifications pré-vol"

# Clavier français
loadkeys fr && ok "Clavier FR chargé"

# Vérification UEFI 64-bit
FW_SIZE=$(cat /sys/firmware/efi/fw_platform_size 2>/dev/null || echo "0")
[[ "$FW_SIZE" == "64" ]] && ok "Mode UEFI 64-bit détecté" || die "UEFI 64-bit requis (détecté: $FW_SIZE)"

# Connectivité réseau
ping -c 2 -W 3 archlinux.org &>/dev/null && ok "Réseau OK" || die "Pas de connexion réseau"

# Synchronisation NTP
timedatectl set-ntp true && ok "NTP activé"

# ============================================================================
# CONFIGURATION INTERACTIVE
# ============================================================================
step "2 — Configuration"

lsblk -dno NAME,SIZE,MODEL | grep -v "loop"
read -rp "Cible (ex: sda) : " TARGET_DISK
DRIVE="/dev/$TARGET_DISK"
[[ -b "$DRIVE" ]] || die "Disque $DRIVE introuvable"

TOTAL_GB=$(( $(lsblk -bno SIZE "$DRIVE" | head -n1) / 1024 / 1024 / 1024 ))
info "Disque détecté : ${TOTAL_GB} Go"

read -rp "Hostname : " MY_HOSTNAME
[[ -n "$MY_HOSTNAME" ]] || die "Hostname vide"
read -rp "User : " MY_USER
[[ -n "$MY_USER" ]] || die "Utilisateur vide"

# Fonction : demande un mot de passe 2x avec validation de longueur
ask_pass() {
    local label="$1" min_len="$2" result_var="$3"
    while true; do
        read -rs -p "$label (min ${min_len} car.) : " pass1; echo
        if [[ ${#pass1} -lt $min_len ]]; then
            warn "Trop court (${#pass1}/${min_len} caractères). Réessayez."
            continue
        fi
        read -rs -p "Confirmez $label : " pass2; echo
        if [[ "$pass1" != "$pass2" ]]; then
            warn "Les mots de passe ne correspondent pas. Réessayez."
            continue
        fi
        eval "$result_var=\$pass1"
        ok "$label défini ✓"
        break
    done
}

ask_pass "Password LUKS (chiffrement disque)" 2 PASS_LUKS
ask_pass "Password Root" 2 PASS_ROOT
ask_pass "Password Utilisateur ($MY_USER)" 2 PASS_USER

# Calcul dynamique des partitions
REC_EFI=1
REC_ROOT=$(( TOTAL_GB * 15 / 100 )); [[ $REC_ROOT -lt 30 ]] && REC_ROOT=30
REC_VAR=$(( TOTAL_GB * 20 / 100 ));  [[ $REC_VAR -lt 15 ]] && REC_VAR=15
REC_HOME=$(( TOTAL_GB - REC_EFI - REC_ROOT - REC_VAR ))

echo -e "\n--- ALLOCATION (Disque: ${TOTAL_GB}G) ---"
echo "EFI: ${REC_EFI}G | Root: ${REC_ROOT}G | Var: ${REC_VAR}G | Home: ${REC_HOME}G"
read -rp "Appliquer ? (y/n) : " AUTO_SIZE
if [[ $AUTO_SIZE != "y" ]]; then
    read -rp "EFI (Go): " REC_EFI
    read -rp "Root (Go): " REC_ROOT
    read -rp "Var (Go): " REC_VAR
fi

# ============================================================================
# ÉTAPE 2 — Partitionnement & Chiffrement
# ============================================================================
step "2 — Partitionnement GPT"

# Nettoyage complet si relance après échec
info "Nettoyage d'une éventuelle exécution précédente..."
umount -R /mnt 2>/dev/null || true
swapoff -a 2>/dev/null || true
# Désactiver LVM (sans supprimer, juste désactiver)
vgchange -an vg0 2>/dev/null || true
# Forcer la suppression des device-mapper restants
dmsetup remove_all -f 2>/dev/null || true
cryptsetup close cryptlvm 2>/dev/null || true
wipefs -af "${DRIVE}"* 2>/dev/null || true
ok "Disque prêt (état propre)"

sgdisk -Z "$DRIVE"
sgdisk -n 1:0:+"${REC_EFI}G" -t 1:ef00 "$DRIVE"
sgdisk -n 2:0:0 -t 2:8309 "$DRIVE"

# Forcer le kernel à relire la nouvelle table de partitions
partprobe "$DRIVE"
sleep 2

# Détecter les noms de partitions (nvme vs sda)
PART_EFI=$(lsblk -lno NAME "$DRIVE" | sed -n '2p')
PART_LUKS=$(lsblk -lno NAME "$DRIVE" | sed -n '3p')
DEV_EFI="/dev/$PART_EFI"
DEV_LUKS="/dev/$PART_LUKS"

ok "Partitions créées : EFI=$DEV_EFI | LUKS=$DEV_LUKS"

# Chiffrement LUKS2 + Argon2id
info "Chiffrement LUKS2..."
echo -n "$PASS_LUKS" | cryptsetup luksFormat --type luks2 --pbkdf argon2id "$DEV_LUKS" -d -
echo -n "$PASS_LUKS" | cryptsetup open "$DEV_LUKS" cryptlvm --allow-discards -d -
ok "Conteneur LUKS ouvert (avec TRIM/discard)"

# ============================================================================
# ÉTAPE 2.4 — Sauvegarde en-tête LUKS (CRITIQUE)
# ============================================================================
step "2.4 — Sauvegarde en-tête LUKS"

rm -f /root/luks-header-backup.img
cryptsetup luksHeaderBackup "$DEV_LUKS" --header-backup-file /root/luks-header-backup.img
ok "En-tête LUKS sauvegardé dans /root/luks-header-backup.img"
warn "⚠️  COPIEZ CE FICHIER SUR UNE CLÉ USB CHIFFRÉE !"
warn "    Sans cet en-tête, vos données sont irrécupérables en cas de corruption."
echo ""
read -rp "Appuyez sur [Entrée] pour continuer..."

# ============================================================================
# ÉTAPE 2.3 + 3 — LVM + Btrfs + Subvolumes
# ============================================================================
step "3 — LVM, Btrfs et Subvolumes"

pvcreate /dev/mapper/cryptlvm
vgcreate vg0 /dev/mapper/cryptlvm
lvcreate -L "${REC_ROOT}G" vg0 -n root
lvcreate -L "${REC_VAR}G" vg0 -n var
lvcreate -l 100%FREE vg0 -n home
ok "Volumes logiques créés"

# Formatage
mkfs.fat -F 32 "$DEV_EFI"
mkfs.btrfs -f -L ROOT /dev/vg0/root
mkfs.btrfs -f -L VAR  /dev/vg0/var
mkfs.btrfs -f -L HOME /dev/vg0/home
ok "Systèmes de fichiers formatés"

# Subvolumes Btrfs (incluant @snapshots et @var-snapshots pour Snapper)
info "Création des subvolumes Btrfs..."

mount /dev/vg0/root /mnt
btrfs subvolume create /mnt/@
btrfs subvolume create /mnt/@snapshots
umount /mnt

mount /dev/vg0/var /mnt
btrfs subvolume create /mnt/@var
btrfs subvolume create /mnt/@var-snapshots
umount /mnt

mount /dev/vg0/home /mnt
btrfs subvolume create /mnt/@home
umount /mnt

ok "Subvolumes créés : @, @snapshots, @var, @var-snapshots, @home"

# Montages
mount -o subvol=@ /dev/vg0/root /mnt
mkdir -p /mnt/{efi,home,var,.snapshots}
mount "$DEV_EFI" /mnt/efi
mount -o subvol=@home /dev/vg0/home /mnt/home
mount -o subvol=@var,compress=zstd:3 /dev/vg0/var /mnt/var
mount -o subvol=@snapshots /dev/vg0/root /mnt/.snapshots
ok "Montages terminés"

# ============================================================================
# ÉTAPE 4 — Installation du système
# ============================================================================
step "4 — Miroirs sécurisés + Installation"

# Sélection de miroirs HTTPS via reflector
info "Sélection des miroirs HTTPS (France)..."
reflector --country France --protocol https --latest 15 --sort rate --save /etc/pacman.d/mirrorlist
ok "Miroirs HTTPS configurés"

# Détection microcode CPU
UCODE=""
if grep -q "GenuineIntel" /proc/cpuinfo; then
    UCODE="intel-ucode"
elif grep -q "AuthenticAMD" /proc/cpuinfo; then
    UCODE="amd-ucode"
fi
[[ -n "$UCODE" ]] && info "Microcode détecté : $UCODE"

pacstrap -K /mnt \
    base linux linux-firmware \
    lvm2 btrfs-progs cryptsetup \
    networkmanager sudo-rs sbctl neovim \
    ${UCODE} \
    docker git \
    open-vm-tools mesa \
    man-db man-pages texinfo

ok "Système de base installé"

# ============================================================================
# ÉTAPE 5 — fstab + passage au chroot
# ============================================================================
step "5 — Génération du fstab et chroot"

genfstab -U /mnt >> /mnt/etc/fstab
ok "fstab généré"

# Passage sécurisé des mots de passe via fichier temporaire
mkdir -p /mnt/tmp
PASS_FILE="/mnt/tmp/.setup_pass"
printf '%s\n%s\n%s' "$PASS_ROOT" "$PASS_USER" "$PASS_LUKS" > "$PASS_FILE"
chmod 600 "$PASS_FILE"

# Copie du script chroot
cp chroot_setup.sh /mnt/chroot_setup.sh
chmod +x /mnt/chroot_setup.sh

# Récupération de l'UUID LUKS pour le cmdline
LUKS_UUID=$(blkid -s UUID -o value "$DEV_LUKS")

info "Entrée dans le chroot..."
arch-chroot /mnt ./chroot_setup.sh "$MY_HOSTNAME" "$MY_USER" "$LUKS_UUID"

# Nettoyage
rm -f /mnt/chroot_setup.sh /mnt/tmp/.setup_pass
unset PASS_LUKS PASS_ROOT PASS_USER

# ============================================================================
# FINALISATION
# ============================================================================
echo ""
echo -e "${GREEN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
echo -e "${GREEN}  ✅ INSTALLATION TERMINÉE !${NC}"
echo -e "${GREEN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
echo ""
warn "Avant de rebooter :"
warn "  1. Copiez /root/luks-header-backup.img sur une clé USB"
warn "  2. Activez Secure Boot dans le BIOS/UEFI"
echo ""
info "Puis : umount -R /mnt && reboot"
