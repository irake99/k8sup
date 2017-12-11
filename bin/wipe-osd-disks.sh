#!/bin/bash
set -e

QUICK_UPGRADE="0"

while getopts "y" OPTION
do
  case $OPTION in
    y) QUICK_UPGRADE="1" ;;
    *) echo "Unknown argument"; exit 1 ;;
  esac
done


function asksure() {
  read -p "Are you sure to delete all OSD disks? (Y/n): " -r
  #echo
  if [[ ! $REPLY =~ ^[Y]$ ]]; then
    echo "Exit!"
    exit 1
  fi

}

if [ "${QUICK_UPGRADE}" == "0" ]; then
  asksure
fi

function get_avail_disks {
  BLOCKS=$(readlink /sys/class/block/* -e | grep -v "usb" | grep -o "sd[a-z]$")
  [[ -n "${BLOCKS}" ]] || ( echo "" ; return 1 )

  while read disk ; do
    # Double check it
    if ! lsblk /dev/${disk} > /dev/null 2>&1; then
      continue
    fi

    if [ -z "$(lsblk /dev/${disk} -no MOUNTPOINT)" ]; then
      # Find it
      echo "/dev/${disk}"
    fi
  done < <(echo "$BLOCKS")
}

DISKS=$(get_avail_disks)
# Wipe osd disks only
for disk in ${DISKS}
do
  echo "Wipe OSD disk: ${disk}"
  parted --script ${disk} mktable gpt
  echo ""
done

echo "Done!"
