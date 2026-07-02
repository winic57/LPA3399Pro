#!/bin/bash

BUILDROOT=$(pwd)
TARGET=$1
NAME=$(whoami)
HOST=$(hostname)
DATETIME=`date +"%Y-%m-%d %H:%M:%S"`
if [[ $RK_ROOTFS_TYPE -eq "squashfs" ]]; then
	echo "# rootfs type is $RK_ROOTFS_TYPE, create ssh keys to $TARGET/etc/ssh"
	ssh-keygen -A -f $TARGET
fi
echo "built by $NAME on $HOST at $DATETIME" > $TARGET/timestamp
exit 0
