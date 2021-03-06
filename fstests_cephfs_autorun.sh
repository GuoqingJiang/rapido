#!/bin/bash
#
# Copyright (C) SUSE LINUX GmbH 2016, all rights reserved.
#
# This library is free software; you can redistribute it and/or modify it
# under the terms of the GNU Lesser General Public License as published
# by the Free Software Foundation; either version 2.1 of the License, or
# (at your option) version 3.
#
# This library is distributed in the hope that it will be useful, but
# WITHOUT ANY WARRANTY; without even the implied warranty of MERCHANTABILITY
# or FITNESS FOR A PARTICULAR PURPOSE.  See the GNU Lesser General Public
# License for more details.

if [ ! -f /vm_autorun.env ]; then
	echo "Error: autorun scripts must be run from within an initramfs VM"
	exit 1
fi

. /vm_autorun.env

set -x

# path to xfstests within the initramfs
XFSTESTS_DIR="/fstests/xfstests"

hostname_fqn="`cat /proc/sys/kernel/hostname`" || _fatal "hostname unavailable"
hostname_short="${hostname_fqn%%.*}"

# need hosts file for hostname -s
cat > /etc/hosts <<EOF
127.0.0.1	$hostname_fqn	$hostname_short
EOF

_ini_parse "/etc/ceph/keyring" "client.${CEPH_USER}" "key"
[ -z "$key" ] && _fatal "client.${CEPH_USER} key not found in keyring"
if [ -z "$CEPH_MON_NAME" ]; then
	# pass global section and use mon_host
	_ini_parse "/etc/ceph/ceph.conf" "global" "mon_host"
	MON_ADDRESS="$mon_host"
else
	_ini_parse "/etc/ceph/ceph.conf" "mon.${CEPH_MON_NAME}" "mon_addr"
	MON_ADDRESS="$mon_addr"
fi

# enable debugfs
cat /proc/mounts | grep debugfs &> /dev/null
if [ $? -ne 0 ]; then
	mount -t debugfs debugfs /sys/kernel/debug/
fi

cat /proc/mounts | grep configfs &> /dev/null
if [ $? -ne 0 ]; then
	mount -t configfs configfs /sys/kernel/config/
fi

for i in $DYN_DEBUG_MODULES; do
	echo "module $i +pf" > /sys/kernel/debug/dynamic_debug/control || _fatal
done
for i in $DYN_DEBUG_FILES; do
	echo "file $i +pf" > /sys/kernel/debug/dynamic_debug/control || _fatal
done

mkdir -p /mnt/test
mount -t ceph ${MON_ADDRESS}:/ /mnt/test -o name=${CEPH_USER},secret=${key} \
	|| _fatal

cat > ${XFSTESTS_DIR}/configs/`hostname -s`.config << EOF
MODULAR=0
TEST_DIR=/mnt/test
TEST_DEV=${MON_ADDRESS}:/
TEST_FS_MOUNT_OPTS="-o name=${CEPH_USER},secret=${key}"
FSTYP="ceph"
EOF

set +x

if [ -n "$FSTESTS_AUTORUN_CMD" ]; then
	cd ${XFSTESTS_DIR} || _fatal
	eval "$FSTESTS_AUTORUN_CMD"
fi
