#!/bin/sh
#-
# SPDX-License-Identifier: BSD-2-Clause-FreeBSD
#
# Copyright 2023 Michael Dexter
# All rights reserved
#
# Redistribution and use in source and binary forms, with or without
# modification, are permitted providing that the following conditions
# are met:
# 1. Redistributions of source code must retain the above copyright
#	notice, this list of conditions and the following disclaimer.
# 2. Redistributions in binary form must reproduce the above copyright
#	notice, this list of conditions and the following disclaimer in the
#	documentation and/or other materials provided with the distribution.
#
# THIS SOFTWARE IS PROVIDED BY THE AUTHOR ``AS IS'' AND ANY EXPRESS OR
# IMPLIED WARRANTIES, INCLUDING, BUT NOT LIMITED TO, THE IMPLIED
# WARRANTIES OF MERCHANTABILITY AND FITNESS FOR A PARTICULAR PURPOSE
# ARE DISCLAIMED.  IN NO EVENT SHALL THE AUTHOR BE LIABLE FOR ANY
# DIRECT, INDIRECT, INCIDENTAL, SPECIAL, EXEMPLARY, OR CONSEQUENTIAL
# DAMAGES (INCLUDING, BUT NOT LIMITED TO, PROCUREMENT OF SUBSTITUTE GOODS
# OR SERVICES; LOSS OF USE, DATA, OR PROFITS; OR BUSINESS INTERRUPTION)
# HOWEVER CAUSED AND ON ANY THEORY OF LIABILITY, WHETHER IN CONTRACT,
# STRICT LIABILITY, OR TORT (INCLUDING NEGLIGENCE OR OTHERWISE) ARISING
# IN ANY WAY OUT OF THE USE OF THIS SOFTWARE, EVEN IF ADVISED OF THE
# POSSIBILITY OF SUCH DAMAGE.

# Version v0.1

f_usage() {
	echo ; echo "USAGE:"
	echo "pool.sh -d \"da0 da1\" -m label|raw|char [-P p2] [-a] -r stripe|mirror|raidz1|raidz2|raidz3|draid1|draid2|draid3|spare -v <vdev device count> -z <zpool name> [-p profile] [-y]"
	echo "pool.sh -t /path/to/device_table.tsv -c <column number> -m label|raw|char [-P p2] [-a] -r stripe|mirror|raidz1|raidz2|raidz3|draid1|draid2|draid3|spare -v <vdev device count> -p <pool name> [-y]"
	echo
	exit 1
}

# v0.2.6

if [ -r ./functions.incl ] ; then
	sh -n ./functions.incl > /dev/null 2>&1 || \
		{ echo "Function library functions.incl failed to validate" ; exit 1 ; }
	. ./functions.incl > /dev/null 2>&1 || \
		{ echo "Function library functions.incl failed to import" ; exit 1 ; }
else
	echo "Function library functions.incl not found"
	exit 1
fi

# DEFAULTS THAT MAY BE OVERIDDEN BY OPTARGS
vdev_device_count="1"
yolo="no"

while getopts d:t:c:m:P:ar:v:z:p:y opts ; do
	case $opts in
	d)
		device_string="${OPTARG}"
	;;
	t)
		[ -n "${OPTARG}" ] || f_usage
		[ -r "${OPTARG}" ] || f_usage
		device_table="${OPTARG}"
	;;
	c)
		[ -n "${OPTARG}" ] || f_usage
		# Check if numeric
		column="${OPTARG}"
	;;
	m)
		[ -n "${OPTARG}" ] || f_usage
		case "${OPTARG}" in
			label|raw|char)
				device_mode="${OPTARG}"
			;;
			*)
				f_usage
			;;
		esac
	;;
	P)
		partition="${OPTARG}"
	;;
	a)
		add_flag=add
	;;
	r)
# Useless test if there is no argument passed in - only a flag
		[ -n "${OPTARG}" ] || f_usage
		case "${OPTARG}" in
			stripe|mirror|raidz1|raidz2|raidz3|draid1|draid2|draid3|spare)
				zraid_level="${OPTARG}"
			;;
			*)
				f_usage	
			;;
		esac
	;;
	v)
		[ -n "${OPTARG}" ] || f_usage
		# VERIFY IF A NUMBER
		vdev_device_count="${OPTARG}"
	;;
	z)
		[ -n "${OPTARG}" ] || f_usage
		# NAME VALIDATION
		zpool_name="${OPTARG}"
	;;
	p)
		# Read zpool_properties from a file
		[ -f "./${OPTARG}" ] || \
			{ echo "Properties file $OPTARG not found" ; exit 1 ; }
		sh -n "./${OPTARG}" || \
			{ echo "Properties file $OPTARG invalid" ; exit 1 ; }
		. "./${OPTARG}" || \
			{ echo "Properties file $OPTARG failed to source" ; exit 1 ; }
	;;
	y)
		yolo="yes"
	;;
	*)
		f_usage
	;;
	esac
done

[ "$zraid_level" ] || f_usage
[ "$zpool_name" ] || f_usage

NL="
" # END-QUOTE
# -d device_string or -t device_table are sanitized to device_list
device_list=""

if [ -n "$device_string" ] ; then
	[ -n "$device_table" ] && f_usage
	[ -n "$column" ] && f_usage
	# THIS HANDLES SPACES ON THE COMMAND LINE AND WITHOUT IFS=" "
	# tr requires tr -s '[:space:]' '\n'

	for device in $device_string ; do
		# Handle the first run
		if [ -z "$device_list" ] ; then
			device_list="$device"	
		else
			device_list="$device_list$NL$device"
		fi
	done
else
	[ -n "$device_string" ] && f_usage
	[ -n "$column" ] || f_usage
	while read row ; do
		if [ -z "$device_list" ] ; then
			device_list="$( echo "$row" | cut -d$'\t' -f $_f$column )"
		else
			device_list="$device_list$NL$( echo "$row" | cut -d$'\t' -f $_f$column )"
		fi
	done < $device_table
fi


# MAIN

hardware_device_count=""

# Count the number of devices for vdev calculations
for device in $device_list ; do
	f_dev_check $device$partition $device_mode || \
		{ echo Invalid device $device ; exit 1 ; }
# Decide if this belongs here
	zpool labelclear -f $( f_dev_path $device $device_mode )/$device$partition \
		> /dev/null 2>&1
	hardware_device_count=$(( $hardware_device_count + 1 ))	
done

# While we explicitly take a type stripe, zfs simply omits the type
[ "$zraid_level" = "stripe" ] && zraid_level=""

vdev_member_count="1"   # One device when entering the loop, by definition
vdev_string=""
#balanced_device_count="1"

# Step through the devices
for device in $device_list ; do
	# Starts at 1 for a new vdev and prefaces the vdev_string with the zraid_level string
	if [ $vdev_member_count = 1 ] ; then

		# Must be quoted on illumos, illegal number on Linux

		# The first one must be quoted but not the second?!?
		# Thinks it is file redirection
#		[ "$hardware_device_count" < "$vdev_device_count" ] && break
#		[ $(( $hardware_device_count -lt $vdev_device_count )) ] && break

		# Default of "sripe" is one vdev, overridden by the user -v "disks per vdev"
		# If total drives are than requested vdev_device_count, break and leave out
		[ "$hardware_device_count" -lt $vdev_device_count ] && break
		# Prepend the zraid_level to the vdev_string followed by the device
		vdev_string="$vdev_string $zraid_level $( f_dev_path $device $device_mode )/$device$partition"
	else
		# Do not prepend with the zraid_level, only add the device to the vdev_string
		vdev_string="$vdev_string $( f_dev_path $device $device_mode )/$device$partition"
	fi

	# Decrement because we just used a device from the list
	hardware_device_count=$(( $hardware_device_count - 1 ))
# NOT USED!!!
#	balanced_device_count=$vdev_member_count
	vdev_member_count=$(( $vdev_member_count +1 ))

	# Must be quoted on illumos, illegal number on Linux
#	if [ "$vdev_member_count" > "$vdev_device_count" ] ; then
#	if [ $(( $vdev_member_count -gt $vdev_device_count )) ] ; then

	# If entering with a vdev with more than requested members, start a new one
	if [ "$vdev_member_count" -gt $vdev_device_count ] ; then
		vdev_member_count=1
	fi
done

#set -x

if [ $add_flag ]; then
	#CHECK TO SEE IF THE POOL EXISTS... perhaps grep for raidz level
        sub_command="add"
else
        sub_command="create $zpool_properties -f"
fi

echo ; echo "The generated zpool command is:" ; echo
echo zpool $sub_command $zpool_name $vdev_string

if [ $add_flag ]; then
	echo ; echo "running zpool $sub_command -n" ; echo
	zpool $sub_command -n $zpool_name $vdev_string
fi

if [ "$yolo" = "no" ] ; then
	echo ; echo "Perform zpool operation? THIS CANNOT BE UNDONE"
	echo -n "(y/n): " ; read go
		[ "$go" = "n" ] && exit 0
fi

zpool $sub_command $zpool_name $vdev_string
zpool list | grep $zpool_name
zfs list | grep $zpool_name

exit 0
