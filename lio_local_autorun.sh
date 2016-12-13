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

# start udevd
ps -eo args | grep -v grep | grep /usr/lib/systemd/systemd-udevd \
	|| /usr/lib/systemd/systemd-udevd --daemon
udevadm settle || _fatal

# enable debugfs
cat /proc/mounts | grep debugfs &> /dev/null
if [ $? -ne 0 ]; then
	mount -t debugfs debugfs /sys/kernel/debug/
fi

# mount configfs first
cat /proc/mounts | grep configfs &> /dev/null
if [ $? -ne 0 ]; then
	mount -t configfs configfs /sys/kernel/config/
fi

modprobe target_core_mod || _fatal
modprobe target_core_iblock || _fatal
modprobe target_core_file || _fatal
modprobe iscsi_target_mod || _fatal

for i in $DYN_DEBUG_MODULES; do
	echo "module $i +pf" > /sys/kernel/debug/dynamic_debug/control || _fatal
done
for i in $DYN_DEBUG_FILES; do
	echo "file $i +pf" > /sys/kernel/debug/dynamic_debug/control || _fatal
done

[ -d /sys/kernel/config/target/iscsi ] \
	|| mkdir /sys/kernel/config/target/iscsi || _fatal

#### iSCSI Discovery authentication information
echo -n 0 > /sys/kernel/config/target/iscsi/discovery_auth/enforce_discovery_auth

#### file backstore
file_path=/lun_filer
file_size_b=1073741824
truncate --size=${file_size_b} $file_path
mkdir -p /sys/kernel/config/target/core/fileio_0/filer || _fatal
echo "fd_dev_name=${file_path}" \
	> /sys/kernel/config/target/core/fileio_0/filer/control || _fatal
echo "fd_dev_size=${file_size_b}" \
	> /sys/kernel/config/target/core/fileio_0/filer/control || _fatal
echo "$file_path" \
	> /sys/kernel/config/target/core/fileio_0/filer/wwn/vpd_unit_serial \
	|| _fatal
echo "1" > /sys/kernel/config/target/core/fileio_0/filer/enable || _fatal
# needs to be done after enable, as target_configure_device() resets it
echo "SUSE" > /sys/kernel/config/target/core/fileio_0/filer/wwn/vendor_id \
	|| _fatal

#### iblock backstore - only if started with a "vda" block device attached
iblock_dev="/dev/vda"
if [ -b "$iblock_dev" ]; then
	mkdir -p /sys/kernel/config/target/core/iblock_0/blocker || _fatal
	echo "udev_path=${iblock_dev}" \
		> /sys/kernel/config/target/core/iblock_0/blocker/control \
		|| _fatal
	echo "$iblock_dev" \
	 > /sys/kernel/config/target/core/iblock_0/blocker/wwn/vpd_unit_serial \
		|| _fatal
	echo "1" > /sys/kernel/config/target/core/iblock_0/blocker/enable \
		|| _fatal
	echo "SUSE" \
	       > /sys/kernel/config/target/core/iblock_0/blocker/wwn/vendor_id \
		|| _fatal
fi

#### iblock + dm-delay backstore
dmdelay_path=/lun_dmdelay
dmdelay_size_b=1073741824
dmdelay_size_blocks=$(($dmdelay_size_b / 512))
dmdelay_ms=6000
# XXX could use zram in guest here, but SLE12SP1 kernel only has it in staging
truncate --size=${dmdelay_size_b} $dmdelay_path || _fatal
dmdelay_loop_dev=`losetup -f` || _fatal
losetup -f $dmdelay_path || _fatal
# setup DM delay device - XXX this needs 95-dm-notify.rules to call
# "dmsetup udevcomplete", otherwise it'll hang indefinitely!
echo "0 $dmdelay_size_blocks delay $dmdelay_loop_dev 0 $dmdelay_ms" \
	| dmsetup create delayed || _fatal
udevadm settle
dmdelay_dev="/dev/dm-0"
mkdir -p /sys/kernel/config/target/core/iblock_1/delayer || _fatal
echo "udev_path=${dmdelay_dev}" \
	> /sys/kernel/config/target/core/iblock_1/delayer/control || _fatal
echo "$dmdelay_dev" \
	> /sys/kernel/config/target/core/iblock_1/delayer/wwn/vpd_unit_serial \
	|| _fatal
echo "1" > /sys/kernel/config/target/core/iblock_1/delayer/enable || _fatal
echo "SUSE" > /sys/kernel/config/target/core/iblock_1/delayer/wwn/vendor_id \
	|| _fatal

mkdir /sys/kernel/config/target/iscsi/${TARGET_IQN} || _fatal

for tpgt in tpgt_1 tpgt_2; do
	mkdir /sys/kernel/config/target/iscsi/${TARGET_IQN}/${tpgt}/ || _fatal

	# file backend as lun 0
	mkdir -p /sys/kernel/config/target/iscsi/${TARGET_IQN}/${tpgt}/lun/lun_0
	[ $? -eq 0 ] || _fatal
	ln -s /sys/kernel/config/target/core/fileio_0/filer \
		/sys/kernel/config/target/iscsi/${TARGET_IQN}/${tpgt}/lun/lun_0/68c6222530
	[ $? -eq 0 ] || _fatal

	# iblock backend as lun1
	if [ -b "$iblock_dev" ]; then
		mkdir -p /sys/kernel/config/target/iscsi/${TARGET_IQN}/${tpgt}/lun/lun_1
		[ $? -eq 0 ] || _fatal
		ln -s /sys/kernel/config/target/core/iblock_0/blocker \
			/sys/kernel/config/target/iscsi/${TARGET_IQN}/${tpgt}/lun/lun_1/68c6222531
		[ $? -eq 0 ] || _fatal
	fi

	# dm-delay backend as lun2
	mkdir -p /sys/kernel/config/target/iscsi/${TARGET_IQN}/${tpgt}/lun/lun_2
	[ $? -eq 0 ] || _fatal
	ln -s /sys/kernel/config/target/core/iblock_1/delayer \
		/sys/kernel/config/target/iscsi/${TARGET_IQN}/${tpgt}/lun/lun_2/68c6222532
	[ $? -eq 0 ] || _fatal

	#### Network portals for iSCSI Target Portal Group
	#### iSCSI Target Ports
	#### Attributes for iSCSI Target Portal Group
	echo 0 > /sys/kernel/config/target/iscsi/${TARGET_IQN}/${tpgt}/attrib/t10_pi
	echo 0 > /sys/kernel/config/target/iscsi/${TARGET_IQN}/${tpgt}/attrib/default_erl
	echo 1 > /sys/kernel/config/target/iscsi/${TARGET_IQN}/${tpgt}/attrib/demo_mode_discovery
	echo 0 > /sys/kernel/config/target/iscsi/${TARGET_IQN}/${tpgt}/attrib/prod_mode_write_protect
	echo 1 > /sys/kernel/config/target/iscsi/${TARGET_IQN}/${tpgt}/attrib/demo_mode_write_protect
	echo 0 > /sys/kernel/config/target/iscsi/${TARGET_IQN}/${tpgt}/attrib/cache_dynamic_acls
	echo 64 > /sys/kernel/config/target/iscsi/${TARGET_IQN}/${tpgt}/attrib/default_cmdsn_depth
	echo 1 > /sys/kernel/config/target/iscsi/${TARGET_IQN}/${tpgt}/attrib/generate_node_acls
	echo 2 > /sys/kernel/config/target/iscsi/${TARGET_IQN}/${tpgt}/attrib/netif_timeout
	echo 15 > /sys/kernel/config/target/iscsi/${TARGET_IQN}/${tpgt}/attrib/login_timeout
	# disable auth
	echo 0 > /sys/kernel/config/target/iscsi/${TARGET_IQN}/${tpgt}/attrib/authentication

	#### authentication for iSCSI Target Portal Group
	#### Parameters for iSCSI Target Portal Group
	echo "2048~65535" > /sys/kernel/config/target/iscsi/${TARGET_IQN}/${tpgt}/param/OFMarkInt
	echo "2048~65535" > /sys/kernel/config/target/iscsi/${TARGET_IQN}/${tpgt}/param/IFMarkInt
	echo "No" > /sys/kernel/config/target/iscsi/${TARGET_IQN}/${tpgt}/param/OFMarker
	echo "No" > /sys/kernel/config/target/iscsi/${TARGET_IQN}/${tpgt}/param/IFMarker
	echo "0" > /sys/kernel/config/target/iscsi/${TARGET_IQN}/${tpgt}/param/ErrorRecoveryLevel
	echo "Yes" > /sys/kernel/config/target/iscsi/${TARGET_IQN}/${tpgt}/param/DataSequenceInOrder
	echo "Yes" > /sys/kernel/config/target/iscsi/${TARGET_IQN}/${tpgt}/param/DataPDUInOrder
	echo "1" > /sys/kernel/config/target/iscsi/${TARGET_IQN}/${tpgt}/param/MaxOutstandingR2T
	echo "20" > /sys/kernel/config/target/iscsi/${TARGET_IQN}/${tpgt}/param/DefaultTime2Retain
	echo "2" > /sys/kernel/config/target/iscsi/${TARGET_IQN}/${tpgt}/param/DefaultTime2Wait
	echo "65536" > /sys/kernel/config/target/iscsi/${TARGET_IQN}/${tpgt}/param/FirstBurstLength
	echo "262144" > /sys/kernel/config/target/iscsi/${TARGET_IQN}/${tpgt}/param/MaxBurstLength
	echo "262144" > /sys/kernel/config/target/iscsi/${TARGET_IQN}/${tpgt}/param/MaxXmitDataSegmentLength
	echo "8192" > /sys/kernel/config/target/iscsi/${TARGET_IQN}/${tpgt}/param/MaxRecvDataSegmentLength
	echo "Yes" > /sys/kernel/config/target/iscsi/${TARGET_IQN}/${tpgt}/param/ImmediateData
	echo "Yes" > /sys/kernel/config/target/iscsi/${TARGET_IQN}/${tpgt}/param/InitialR2T
	echo "LIO Target" > /sys/kernel/config/target/iscsi/${TARGET_IQN}/${tpgt}/param/TargetAlias
	echo "1" > /sys/kernel/config/target/iscsi/${TARGET_IQN}/${tpgt}/param/MaxConnections
	echo "CRC32C,None" > /sys/kernel/config/target/iscsi/${TARGET_IQN}/${tpgt}/param/DataDigest
	echo "CRC32C,None" > /sys/kernel/config/target/iscsi/${TARGET_IQN}/${tpgt}/param/HeaderDigest
	echo "CHAP,None" > /sys/kernel/config/target/iscsi/${TARGET_IQN}/${tpgt}/param/AuthMethod

	for initiator in $INITIATOR_IQNS; do
		# hash IQN and concat first 10 bytes with LUN as ID (XXX serial number?)
		IQN_SHA=`echo $initiator | sha256sum -`
		IQN_SHA=${IQN_SHA:0:9}
		echo "provisioning ACL for $initiator (${IQN_SHA})"

		#### iSCSI Initiator ACLs for iSCSI Target Portal Group
		mkdir -p /sys/kernel/config/target/iscsi/${TARGET_IQN}/${tpgt}/acls/${initiator}
		[ $? -eq 0 ] || _fatal
		echo 64 > /sys/kernel/config/target/iscsi/${TARGET_IQN}/${tpgt}/acls/${initiator}/cmdsn_depth
		#### iSCSI Initiator ACL authentication information
		#### iSCSI Initiator ACL TPG attributes
		echo 0 > /sys/kernel/config/target/iscsi/${TARGET_IQN}/${tpgt}/acls/${initiator}/attrib/random_r2t_offsets
		echo 0 > /sys/kernel/config/target/iscsi/${TARGET_IQN}/${tpgt}/acls/${initiator}/attrib/random_datain_seq_offsets
		echo 0 > /sys/kernel/config/target/iscsi/${TARGET_IQN}/${tpgt}/acls/${initiator}/attrib/random_datain_pdu_offsets
		echo 30 > /sys/kernel/config/target/iscsi/${TARGET_IQN}/${tpgt}/acls/${initiator}/attrib/nopin_response_timeout
		echo 15 > /sys/kernel/config/target/iscsi/${TARGET_IQN}/${tpgt}/acls/${initiator}/attrib/nopin_timeout
		echo 0 > /sys/kernel/config/target/iscsi/${TARGET_IQN}/${tpgt}/acls/${initiator}/attrib/default_erl
		echo 5 > /sys/kernel/config/target/iscsi/${TARGET_IQN}/${tpgt}/acls/${initiator}/attrib/dataout_timeout_retries
		echo 3 > /sys/kernel/config/target/iscsi/${TARGET_IQN}/${tpgt}/acls/${initiator}/attrib/dataout_timeout

		for lun in 0 1 2; do
			#### iSCSI Initiator LUN ACLs for iSCSI Target Portal Group
			[ -e /sys/kernel/config/target/iscsi/${TARGET_IQN}/${tpgt}/lun/lun_${lun} ] || continue

			mkdir -p /sys/kernel/config/target/iscsi/${TARGET_IQN}/${tpgt}/acls/${initiator}/lun_${lun}
			[ $? -eq 0 ] || _fatal
			ln -s /sys/kernel/config/target/iscsi/${TARGET_IQN}/${tpgt}/lun/lun_${lun} \
				/sys/kernel/config/target/iscsi/${TARGET_IQN}/${tpgt}/acls/${initiator}/lun_${lun}/${IQN_SHA}${lun}
			echo 0 > /sys/kernel/config/target/iscsi/${TARGET_IQN}/${tpgt}/acls/${initiator}/lun_${lun}/write_protect
		done
	done
done

set +x

echo "LUN 0: file backed logical unit, using LIO fileio"
if [ -b "$iblock_dev" ]; then
	echo "LUN 1: $iblock_dev backed logical unit, using LIO iblock"
fi
echo "LUN 2: loopback file with 1s dm-delay I/O latency"

# standalone iSCSI target - listen on ports 3260 and 3261 of assigned address
ip link show eth0 | grep $MAC_ADDR1
if [ $? -eq 0 ]; then
	mkdir /sys/kernel/config/target/iscsi/${TARGET_IQN}/tpgt_1/np/${IP_ADDR1}:3260
	mkdir /sys/kernel/config/target/iscsi/${TARGET_IQN}/tpgt_2/np/${IP_ADDR1}:3261

	echo "target ready at: iscsi://${IP_ADDR1}:3260/${TARGET_IQN}/"
	echo "target ready at: iscsi://${IP_ADDR1}:3261/${TARGET_IQN}/"
fi

ip link show eth0 | grep $MAC_ADDR2
if [ $? -eq 0 ]; then
	mkdir /sys/kernel/config/target/iscsi/${TARGET_IQN}/tpgt_1/np/${IP_ADDR2}:3260
	mkdir /sys/kernel/config/target/iscsi/${TARGET_IQN}/tpgt_2/np/${IP_ADDR2}:3261

	echo "target ready at: iscsi://${IP_ADDR2}:3260/${TARGET_IQN}/"
	echo "target ready at: iscsi://${IP_ADDR2}:3261/${TARGET_IQN}/"
fi
echo 1 > /sys/kernel/config/target/iscsi/${TARGET_IQN}/tpgt_1/enable
echo 1 > /sys/kernel/config/target/iscsi/${TARGET_IQN}/tpgt_2/enable