#! /bin/bash
#
# CompuLab modules boot loader update utility
#
# Copyright (C) 2013-2017 CompuLab, Ltd.
# Author: Igor Grinberg <grinberg@compulab.co.il>
#
# This program is free software; you can redistribute it and/or modify
# it under the terms of the GNU General Public License as published by
# the Free Software Foundation; either version 2 of the License, or
# (at your option) any later version.
#
# This program is distributed in the hope that it will be useful,
# but WITHOUT ANY WARRANTY; without even the implied warranty of
# MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
# GNU General Public License for more details.

UPDATER_VERSION="3.0.0-devel"
UPDATER_VERSION_DATE="Sep 25 2017"
UPDATER_BANNER="CompuLab boot loader update utility ${UPDATER_VERSION} (${UPDATER_VERSION_DATE})"

NORMAL="\033[0m"
WARN="\033[33;1m"
BAD="\033[31;1m"
BOLD="\033[1m"
GOOD="\033[32;1m"
BLOCK=1024

# offset is in units of BLOCK
declare -A board_cm_fx6=(
	[name]="CM-FX6"
	[eeprom_dev]="/sys/bus/i2c/devices/2-0050/eeprom"
	[file]="cm-fx6-firmware"
	[mtd_dev]="mtd0"
	[mtd_dev_file]="/dev/mtd0"
	[offset]=0
)
declare -A board_cl_som_imx7=(
	[name]="CL-SOM-iMX7"
	[eeprom_dev]="/sys/bus/i2c/devices/1-0050/eeprom"
	[file]="cl-som-imx7-firmware"
	[mtd_dev]="mtd0"
	[mtd_dev_file]="/dev/mtd0"
	[offset]=0
)
board_list=(board_cm_fx6 board_cl_som_imx7)
declare -A board

function good_msg() {
	local msg_string=$1
	msg_string="${msg_string:-...}"
	echo -e "${GOOD}>>${NORMAL}${BOLD} ${msg_string} ${NORMAL}"
}

function bad_msg() {
	local msg_string=$1
	msg_string="${msg_string:-...}"
	echo -e "${BAD}!!${NORMAL}${BOLD} ${msg_string} ${NORMAL}"
}

function warn_msg() {
	local msg_string=$1
	msg_string="${msg_string:-...}"
	echo -e "${WARN}**${NORMAL}${BOLD} ${msg_string} ${NORMAL}"
}

function failure_msg() {
		bad_msg "$1"
		bad_msg "If you reboot, your system might not boot anymore!"
		bad_msg "Please, try re-installing mtd-utils package and retry!"
}

function DD() {
	dd $* &> /dev/null & pid=$!

	while [ -e /proc/$pid ] ; do
		echo -n "."
		sleep 1
	done

	echo ""
	wait $pid
	return $?
}

function confirm() {
	good_msg "$1"

	select yn in "Yes" "No"; do
		case $yn in
			"Yes")
				return 0;
				;;
			"No")
				return 1;
				;;
			*)
				case ${REPLY,,} in
					"y"|"yes")
						return 0;
						;;
					"n"|"no"|"abort")
						return 1;
						;;
				esac
		esac
	done

	return 1;
}

function find_bootloader_file() {
	read -e -p "Please input firmware file path (or press ENTER to use \"${board[file]}\"): " filepath
	if [[ -n $filepath ]]; then
		board[file]=`eval "echo $filepath"`
	fi

	good_msg "Looking for boot loader image file: ${board[file]}"
	if [ ! -s ${board[file]} ]; then
		bad_msg "Can't find boot loader image file for the board"
		return 1;
	fi

	good_msg "...Found"
	return 0;
}

function check_spi_flash() {
	good_msg "Looking for SPI flash: ${board[mtd_dev]}"

	grep -qE "${board[mtd_dev]}: [0-f]+ [0-f]+ \"uboot\"" /proc/mtd
	if [ $? -ne 0 ]; then
		bad_msg "Can't find ${board[mtd_dev]} device, is the SPI flash support enabled in kernel?"
		return 1;
	fi

	if [ ! -c ${board[mtd_dev_file]} ]; then
		bad_msg "Can't find ${board[mtd_dev]} device special file: ${board[mtd_dev_file]}"
		return 1;
	fi

	good_msg "...Found"
	return 0;
}

function get_uboot_version() {
	local file="$1"
	grep -oaE "U-Boot [0-9]+\.[0-9]+.* \(... +[0-9]+ [0-9]+ - [0-9]+:[0-9]+:[0-9]+.*\)" "$file"
}

function check_bootloader_versions() {
	local flash_version=`echo \`get_uboot_version ${board[mtd_dev_file]}\``
	local file_version=`echo \`get_uboot_version ${board[file]}\``
	local file_size=`du -hL ${board[file]} | cut -f1`

	good_msg "Current U-Boot version in SPI flash:\t$flash_version"
	good_msg "New U-Boot version in file:\t\t$file_version ($file_size)"

	confirm "Proceed with the update?" && return 0;

	return 1;
}

function check_utility() {
	local util_name="$1"
	local utility=`which "$util_name"`

	if [[ -z "$utility" || ! -x $utility ]]; then
		bad_msg "Can't find $util_name utility! Please install $util_name before proceding!"
		return 1;
	fi

	return 0;
}

function check_utilities() {
	good_msg "Checking for utilities..."

	check_utility "diff"		|| return 1;
	check_utility "grep"		|| return 1;
	check_utility "sed"		|| return 1;
	check_utility "hexdump"		|| return 1;
	check_utility "dd"		|| return 1;
	check_utility "flash_erase"	|| return 1;
	check_utility "flash_unlock"    || return 1;

	good_msg "...Done"
	return 0;
}

function erase_spi_flash() {
	good_msg "Erasing SPI flash..."

	flash_erase ${board[mtd_dev_file]} 0 0
	if [ $? -ne 0 ]; then
		failure_msg "Failed erasing SPI flash!"
		return 1;
	fi

	good_msg "...Done"
	return 0;
}

function write_bootloader() {
	good_msg "Writing boot loader to the SPI flash..."

	DD if=${board[file]} of=${board[mtd_dev_file]} bs=$BLOCK skip=${board[offset]} seek=1
	if [ $? -ne 0 ]; then
		failure_msg "Failed writing boot loader to the SPI flash!"
		return 1;
	fi

	good_msg "...Done"
	return 0;
}

function check_bootloader() {
	good_msg "Checking boot loader in the SPI flash..."

	local test_file="${board[file]}.test"
	local size=$((`du -L ${board[file]} | cut -f1`))
	local short_size=$((size-${board[offset]}))

	{ dd if=/dev/zero count=$size bs=$BLOCK | tr '\000' '\377' > $test_file; } &> /dev/null
	DD if=${board[mtd_dev_file]} of=$test_file bs=$BLOCK skip=1 seek=${board[offset]} count=$short_size
	if [ $? -ne 0 ]; then
		failure_msg "Failed reading boot loader from the SPI flash!"
		return 1;
	fi

	diff ${board[file]} $test_file > /dev/null
	if [ $? -ne 0 ]; then
		failure_msg "Boot loader check failed!"
		return 1;
	fi

	rm -f $test_file

	good_msg "...Done"
	return 0;
}

function check_board_specific() {
	if [ ! -e ${board[eeprom_dev]} ]; then
		return 1;
	fi;

	local module=`hexdump -C ${board[eeprom_dev]} | grep 00000080 | sed "s/.*|\(${board[name]}\).*/\1/g"`

	if [ "$module" != ${board[name]} ]; then
		return 1;
	fi;

	good_msg "Board ${board[name]} detected"
	return 0;
}

# Copy specific board parameters to associative array board
function board_update() {
	declare -n orig_array="$1"

	for key in "${!orig_array[@]}"; do
		board["$key"]="${orig_array["$key"]}"
	done
}

function check_board() {
	good_msg "Checking that the board is supported"

	for board_arr in ${board_list[@]}; do
		board_update $board_arr
		check_board_specific && return 0
	done

	bad_msg "This board is not supported!"
	return 1
}

function error_exit() {
	bad_msg "Boot loader update failed!"
	exit $1;
}

function env_set() {
	local var=$1
	local value=$2

	# Unlock the SPI flash.
	# The U-Boot environment is stored in /dev/mtd1.
	# The reason for the need to unlock /dev/mtd2 should be investigated.
	flash_unlock /dev/mtd2 0
	fw_setenv $var "$value"
	flash_unlock /dev/mtd2 0

	local match=`fw_printenv $var | grep -e "^$var=$value\$" | wc -l`
	[ $match -eq 1 ] && return 0;

	return 1;
}

function reset_environment() {
	warn_msg "Resetting U-Boot environment will override any changes made to the environment!"
	confirm "Reset U-Boot environment (recommended)?"
	if [ $? -eq 1 ]; then
		good_msg "U-boot environment will not be reset."
		return 0;
	fi

	check_utility "fw_setenv" && check_utility "fw_printenv"
	if [[ $? -ne 0 ]]; then
		bad_msg "Cannot reset environment."
		return 1;
	fi

	local bootcmd_new="env default -a && saveenv; reset"
	env_set bootcmd "$bootcmd_new" && env_set bootdelay 0
	if [[ $? -eq 0 ]]; then
		good_msg "U-boot environment will be reset on restart."
		return 0;
	fi

	bad_msg "U-Boot environment reset failed!"
	return 1;
}

# Update firmware header offset in the file
function update_offset() {
	local offset=`hexdump -v -e '"%_ad" 16/1 " %02X" "\n"' ${board[file]} | grep -E -m 1 "^[0-9]+ D1 ([0-9A-F]{2} ){2}4[01]" | awk '{print $1}'`
	board[offset]=$(($offset/$BLOCK))
}

#main()
echo -e "\n${UPDATER_BANNER}\n"

check_utilities			|| error_exit 4;
check_board			|| error_exit 3;
find_bootloader_file		|| error_exit 1;
update_offset			|| error_exit 8;
check_spi_flash			|| error_exit 2;
check_bootloader_versions	|| exit 0;

warn_msg "Do not power off or reset your computer!!!"

erase_spi_flash			|| error_exit 5;
write_bootloader		|| error_exit 6;
check_bootloader		|| error_exit 7;

good_msg "Boot loader update succeeded!\n"

reset_environment		|| exit 0;

good_msg "Done!\n"
