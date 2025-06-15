#!/usr/bin/env bash

echoerr() { cat <<< "$@" 1>&2; }


# Ask for non-existing machine name
echo -n "Identify this machine: "
read machinename
if [[ -d "$HOME/keys/$machinename" ]]; then
    echoerr "machine already exists"
    exit 2
fi
# Create keyfile
mkdir -p "$HOME/keys/$machinename"
keyname=$(cat /proc/sys/kernel/random/uuid)
dd if=/dev/urandom bs=1024 count=1 2>/dev/null > "$HOME/keys/$machinename/$keyname.lek"

# Create recovery key
keyarr=()
for i in {1..8}; do
  keyarr+=($(tr -cd 0-9 </dev/urandom | head -c 6))
done
recoverkey=$(echo ${keyarr[*]} | tr ' ' '-')
cat << EOF > "$HOME/keys/$machinename/luks-recover-key.txt"
Recovery key for LUKS root partition encryption

You can verify that the key name in /etc/crypttab matches the following UUID:

    $keyname

If this is the UUID based filename in /etc/crypttab, then you can use the following recovery key to unlock the partition:

    $recoverkey

If the above UUID does not match, then you can still use the installation passphrase in keyslot 0.
EOF

base64key=$(cat "$HOME/keys/$machinename/$keyname.lek" | base64 -w 0)

# Create key install script
cat << EOF > "$HOME/keys/$machinename/install.sh"
#!/bin/bash
echoerr() { cat <<< "\$@" 1>&2; }
if [[ "\$EUID" != 0 ]]; then
    echo "script must run as root"
fi

FILE="/etc/initramfs-tools/modules"
declare -a items=("vfat" "nls_cp437" "nls_ascii" "usb_storage")
for item in "\${items[@]}"
do
    grep -qF -- "\$item" "\$FILE" || echo "\$item" >> "\$FILE"
done

cat << "END" > /bin/luksunlockusb
#!/bin/sh
set -e
if [ \$CRYPTTAB_TRIED -eq "0" ]; then
    sleep 3
fi
if [ ! -e /mnt ]; then
    mkdir -p /mnt
fi
for usbpartition in /dev/disk/by-id/usb-*-part1; do
    usbdevice=\$(readlink -f \$usbpartition)
    if mount -t vfat \$usbdevice /mnt 2>/dev/null; then
        if [ -e /mnt/\$CRYPTTAB_KEY.lek ]; then
            cat /mnt/\$CRYPTTAB_KEY.lek
            umount \$usbdevice
            exit
        fi
        umount \$usbdevice
    fi
done
/lib/cryptsetup/askpass "Enter passphrase or insert USB key and press ENTER: "
END
chmod 755 /bin/luksunlockusb

echo -n "$base64key" | base64 -d > $keyname.lek
echo -n "$recoverkey" > $keyname.txt
sed -i "s/none/$keyname/g" /etc/crypttab
sed -i "s/keyscript=decrypt_keyctl/keyscript=\/bin\/luksunlockusb/g" /etc/crypttab
cat /etc/crypttab
FIRST_DRIVE=true

for device in \$(blkid --match-token TYPE=crypto_LUKS -o device); do
    echo \$device

    cryptsetup luksAddKey \$device $keyname.lek
    if cryptsetup open --verbose --test-passphrase --key-file $keyname.lek \$device ; then
        cryptsetup luksAddKey --key-file $keyname.lek \$device $keyname.txt
    else
        echo "error adding txt keyfile, lek file did not work. You must clean up existing key slot before running again."
        rm $keyname.lek
        rm $keyname.txt
        exit 1
    fi

done
rm $keyname.lek
rm $keyname.txt
update-initramfs -u
echo "remember to delete this install file"
EOF
