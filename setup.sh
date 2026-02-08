#!/bin/bash

# Configuration des variables basées sur tes captures
LUKS_DEV="/dev/sda2"
MAPPER_NAME="cryptlvm"
VG_NAME="vg0"
EFI_DEV="/dev/sda1"

echo "--- Démarrage de la procédure de chroot ---"

# 1. Ouverture de LUKS
if [ ! -e "/dev/mapper/$MAPPER_NAME" ]; then
    echo "[1/4] Ouverture du conteneur LUKS..."
    cryptsetup open "$LUKS_DEV" "$MAPPER_NAME" || { echo "Échec cryptsetup"; exit 1; }
else
    echo "[!] Le mapper $MAPPER_NAME est déjà ouvert."
fi

# 2. Activation LVM
echo "[2/4] Activation des volumes LVM..."
vgchange -ay "$VG_NAME"

# 3. Montage des partitions Btrfs (Subvolumes)
echo "[3/4] Montage des sous-volumes Btrfs..."
mount -o subvol=@ "/dev/mapper/$VG_NAME-root" /mnt
mount -o subvol=@var "/dev/mapper/$VG_NAME-var" /mnt/var
mount -o subvol=@home "/dev/mapper/$VG_NAME-home" /mnt/home
mount "$EFI_DEV" /mnt/efi

# 4. Entrée en chroot
echo "[4/4] Entrée dans l'environnement Arch-Chroot..."
echo "Astuce : Pense à vérifier ton /etc/kernel/cmdline une fois dedans."
arch-chroot /mnt
