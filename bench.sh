#!/bin/sh
#-
# SPDX-License-Identifier: BSD-2-Clause-FreeBSD
#
# Copyright 2023, 2025 Michael Dexter
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

# Version v0.2

f_usage() {
	echo "USAGE:"
	echo "bench.sh ( Run default test in current directory )"
	echo "bench.sh [ -p <path> ] [ -r <runtime> ] [ -f <fio profile> ]"
	echo "bench.sh -d \"da0 da1\" -m label|raw|char [ -P <partition> ] [ -r <runtime> ] [ -f <fio profile> ]"
	echo "bench.sh -t /path/to/device_table.tsv -c <column number> -m label|raw|char [ -P <partition> ] [ -r <runtime> ] [ -f <fio profile> ]"
	exit 1
}

# Abort early if there is no chance of success
which fio > /dev/null 2>&1 || { echo benchmarks/fio not installed ; exit 1 ; }
which jq > /dev/null 2>&1 || { echo textproc/jq not installed ; exit 1 ; }
which uuidgen > /dev/null 2>&1 || { echo uuidgen not installed ; exit 1 ; }

# Internal variables
# Directory for JSON output. Could it be absorbed into shell variables?
output_dir="/tmp/$( uuidgen )"
mkdir -p $output_dir || { echo Failed to create /tmp/$output_dir ; exit 1 ; }


# BASH on Linux requires ./<file>
if [ -r ./functions.incl ] ; then
	sh -n ./functions.incl > /dev/null 2>&1 || \
		{ echo "Function library functions.incl failed to validate" ; exit 1 ; }
	. ./functions.incl > /dev/null 2>&1 || \
		{ echo "Function library functions.incl failed to import" ; exit 1 ; }
else
	echo "Function library functions.incl not found"
	exit 1
fi

while getopts p:d:t:c:m:P:r:f: opts ; do
	case $opts in
	p)
		[ -d "${OPTARG}" ] || { echo "${OPTARG}" is not a directory" ; exit 1 ; }
		[ -w "${OPTARG}" ] || { echo "${OPTARG}" is not writable" ; exit 1 ; }
		file_path="${OPTARG}"
	;;
	d)
		device_string="${OPTARG}"
	;;
	t)
# THE OPTARG COLON SHOULD TEST FOR INPUT, no? VERIFY
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
	r)
		[ -n "${OPTARG}" ] || f_usage
		# Check if numeric
		run_time="${OPTARG}"
	;;
	f)
		# -r handles both but they are different issues
		# Why does the exit not exit?
		[ -f "./${OPTARG}" ] || { echo "Fio profile "${OPTARG}" not found" ; exit 1 ; }
		[ -r "./${OPTARG}" ] || { echo "Fio profile "${OPTARG}" not readable" ; exit 1 ; }
		fio_profile="${OPTARG}"
	;;
	*)
		f_usage
	;;
	esac
done

if [ -n "$device_string" ] ; then
	[ -n "$device_mode" ] || { echo "-d requires -m" ; exit 1 ; }
fi

# Defaults that can be overridden by user input and can be customized here
run_time="10"

# posixaio engine is failing in 2025 on FreeBSD 14.2
#fio: pid=4254, err=45/file:engines/posixaio.c:180, func=xfer, error=Operation not supported

# fio 3.38 engine support on FreeBSD 14.2
# sync
# psync
# vsync
# pvsync
# pvsync2

#default_fio_string="--name=bench.sh --ioengine=posixaio --direct=1 --fdatasync=1 --rw=write --gtod_reduce=1 --size=1g --numjobs=1 --iodepth=1 --time_based --end_fsync=1"

default_fio_string="--name=bench.sh --ioengine=sync --direct=1 --fdatasync=1 --rw=write --gtod_reduce=1 --size=1g --numjobs=1 --iodepth=1 --time_based --end_fsync=1"

# Works on tmpfs
# fio --runtime=10 --name=tmpfs --ioengine=posixaio --fdatasync=1 --rw=write --gtod_reduce=1 --size=1g --numjobs=1 --iodepth=1 --time_based --end_fsync=1 --filename="$1"

# Works on gluster
#fio --runtime=10 --name=glusterfs --ioengine=posixaio --fdatasync=1 --rw=write --direct=1 --gtod_reduce=1 --size=1g --numjobs=1 --iodepth=1 --time_based --end_fsync=1 --filename=/mnt/gfs-ssd-replica/foo


# Additional time to allow tasks to complete. Must set this variable after user input
sleep_time=$(( $run_time + 5 ))

# PROBABLY SHOULD VALIDATE INCOMPATIBLE OPTIONS
# -d and -t mainly device table vs. string but that should be handled in the template
# Combine these if possible
# Verify that -m label and -P partition are not specified

# THESE FAIL on just -p path
#[ "$file_path" -a "device_string" ] && { echo "-p and -d are mutally exclusive" ; exit 1 ; }
#[ "$file_path" -a "device_table" ] && { echo "-p and -t are mutally exclusive" ; exit 1 ; }

NL="
" # END-QUOTE
device_list=""

# ADDED CHECK FOR PWD USE - NOT IN TEMPLATE
if [ "$device_string" -o "$device_table" ] ; then
# Shell check: Prefer [ p ] || [ q ] as [ p -o q ] is not well defined.
# NOT INDENTING FOR NOW
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
# Test already performed above
#	[ -n "$device_string" ] && f_usage
	[ -n "$column" ] || f_usage
	while read row ; do
		if [ -z "$device_list" ] ; then
			device_list="$( echo "$row" | cut -d$'\t' -f $_f$column )"
		else
			device_list="$device_list$NL$( echo "$row" | cut -d$'\t' -f $_f$column )"
		fi
	done < $device_table
fi
# NOT INDENTING LONG LINES FOR NOW
fi


# MAIN

# Operate in the current or specified directory if -d or -t are not provided
# If #device_list is defined, go that route. Otherwise see if $file_path is defined or use pwd


# Determine if working on user-specified device(s), a directory path, or the pwd
if [ -n "$device_list" ] ; then

	# PREFLIGHT ALL DEVICES BECAUSE A BACKGROUNDED RUN WITH GARBAGE INPUT IS A MESS
	for device in $device_list ; do
		f_dev_check $device$partition $device_mode || { echo Device $device$partition not found ; exit 1 ; }

		# Do not bench a partitioned device if a -P partition is not specified
		if [ ! -n $partition ] ; then
			f_part_check $device $device_mode && { echo Device $device is partitioned, exiting ; exit 1 ; }
		fi
	done
	# END PREFLIGHT

	# Reminder: The fio profile name is the last argument
#	echo "Starting parallel fio runs with a total runtime of $sleep_time"
	for device in $device_list ; do
		if [ -n "$fio_profile" ] ; then
			# Profile specified and optionally runtime
			# How not repeat ourselves?

			fio --runtime=$run_time \
				--filename=$( f_dev_path $device $device_mode )/$device$partition \
				--output-format=json $fio_profile \
					> $output_dir/$device${partition}-fio.json &
		else

			# No user input or only runtime
			fio --runtime=$run_time $default_fio_string \
				--filename=$( f_dev_path $device $device_mode )/$device$partition \
				--output-format=json \
					> $output_dir/$device${partition}-fio.json &
		fi
	done
else

# OPERATING ON A PATH, user-specified or pwd

	if [ -n "$file_path" ] ; then
		# Trail with a slash to be safe? Verfied to be a directory earlier
		target="$file_path/fio.tmp"
	else
		# Following the default fio naming convention
		target="fio.tmp"
	fi

#	echo "Starting fio run with a runtime of $run_time"
# TIL: name is required in the profile and at the command line; if no filename is given, filename is fio.tmp
	if [ -n "$fio_profile" ] ; then
		# Profile specified and optionally runtime
#		echo "Running: fio --runtime=$run_time --filename=$target $fio_profile"
		fio --runtime=$run_time --filename=$target --output-format=json $fio_profile \
			> $output_dir/fio.json

		[ -f $file_path/fio.tmp ] && rm $file_path/fio.tmp
	else
		# No user input or only runtime
#		echo "Running: fio --runtime=$run_time $default_fio_string --filename=$target"
		fio --runtime=$run_time $default_fio_string --filename=$target --output-format=json \
			> $output_dir/fio.json

		[ -f ./fio.tmp ] && rm ./fio.tmp
	fi

fi # End MAIN device_list

# Parallel jobs are backgrounded. Immediately sleep upon backgrounding them
sleep $sleep_time

#echo ; echo The parsed output is:
#ls $output_dir/*.json

echo ; echo "The maximum write IOPS of the run was:"
jq '.jobs[0].write.iops' $output_dir/*.json | cut -d . -f1 | sort -n

echo "The maximum write throughput of the run was:"
jq '.jobs[0].write.bw' $output_dir/*.json | sort -n

echo ; echo "The maximum read IOPS of the run was:"
jq '.jobs[0].read.iops' $output_dir/*.json | cut -d . -f1 | sort -n

echo "The maximum read throughput of the run was:"
jq '.jobs[0].read.bw' $output_dir/*.json | sort -n

echo
exit 0
