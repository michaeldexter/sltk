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

# Reminder: part.sh is using diskinfo to determine the serial number thus -c 4

f_usage() {
	echo "USAGE:"
	echo "part.sh -d \"da0 da1\" [ -s swap size in GB ]"
	echo "part.sh -t /path/to/device_table.tsv -c <column number> [ -s 0|1|2 swap size in GB ]"
	exit 1
}

if [ -r ./functions.incl ] ; then
	sh -n ./functions.incl > /dev/null 2>&1 || \
		{ echo "Function library functions.incl failed to validate" ; exit 1 ; }
	. ./functions.incl > /dev/null 2>&1 || \
		{ echo "Function library functions.incl failed to import" ; exit 1 ; }
else
	echo "Function library functions.incl not found"
	exit 1
fi

while getopts d:t:c:s: opts ; do
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
	s)
		[ -n "${OPTARG}" ] || f_usage
		case "${OPTARG}" in
			0|1|2)
				swap_size="${OPTARG}"
			;;
			*)
				f_usage	
			;;
		esac
	;;
	*)
		f_usage
	;;
	esac
done

NL="
" # END-QUOTE
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

for device in $device_list ; do
	f_dev_check "$device" raw || { echo Invalid device $device ; exit 1 ; }
# HOW WILL THIS BEHAVE FOR EACH MODE?
	f_part_check "$device" raw && { echo "Device $device is already partitioned. depart it first" ; exit 1 ; }
	f_part "$device" raw "$swap_size"
	f_boot "$device" raw
done
