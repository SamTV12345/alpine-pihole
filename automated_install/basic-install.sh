#!/usr/bin/env bash
# shellcheck disable=SC1090

# Pi-hole: A black hole for Internet advertisements
# (c) Pi-hole (https://pi-hole.net)
# Network-wide ad blocking via your own hardware.
#
# Installs and Updates Pi-hole
#
# This file is copyright under the latest version of the EUPL.
# Please see LICENSE file for your rights under this license.

# pi-hole.net/donate
#
# Install with this command (from your Linux machine):
#
# curl -sSL https://install.pi-hole.net | bash

# -e option instructs bash to immediately exit if any command [1] has a non-zero exit status
# We do not want users to end up with a partially working install, so we exit the script
# instead of continuing the installation with something broken
set -e

# Append common folders to the PATH to ensure that all basic commands are available.
# When using "su" an incomplete PATH could be passed: https://github.com/pi-hole/pi-hole/issues/3209
export PATH+=':/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin'

######## VARIABLES #########
# For better maintainability, we store as much information that can change in variables
# This allows us to make a change in one place that can propagate to all instances of the variable
# These variables should all be GLOBAL variables, written in CAPS
# Local variables will be in lowercase and will exist only within functions
# It's still a work in progress, so you may see some variance in this guideline until it is complete

# Dialog result codes
# dialog code values can be set by environment variables, we only override if
# the env var is not set or empty.
: "${DIALOG_OK:=0}"
: "${DIALOG_CANCEL:=1}"
: "${DIALOG_ESC:=255}"


# List of supported DNS servers
DNS_SERVERS=$(cat << EOM
Google (ECS, DNSSEC);8.8.8.8;8.8.4.4;2001:4860:4860:0:0:0:0:8888;2001:4860:4860:0:0:0:0:8844
OpenDNS (ECS, DNSSEC);208.67.222.222;208.67.220.220;2620:119:35::35;2620:119:53::53
Level3;4.2.2.1;4.2.2.2;;
Comodo;8.26.56.26;8.20.247.20;;
DNS.WATCH (DNSSEC);84.200.69.80;84.200.70.40;2001:1608:10:25:0:0:1c04:b12f;2001:1608:10:25:0:0:9249:d69b
Quad9 (filtered, DNSSEC);9.9.9.9;149.112.112.112;2620:fe::fe;2620:fe::9
Quad9 (unfiltered, no DNSSEC);9.9.9.10;149.112.112.10;2620:fe::10;2620:fe::fe:10
Quad9 (filtered, ECS, DNSSEC);9.9.9.11;149.112.112.11;2620:fe::11;2620:fe::fe:11
Cloudflare (DNSSEC);1.1.1.1;1.0.0.1;2606:4700:4700::1111;2606:4700:4700::1001
EOM
)

# Location for final installation log storage
installLogLoc="/etc/pihole/install.log"
# This is an important file as it contains information specific to the machine it's being installed on
setupVars="/etc/pihole/setupVars.conf"
# Pi-hole uses lighttpd as a Web server, and this is the config file for it
lighttpdConfig="/etc/lighttpd/lighttpd.conf"
# This is a file used for the colorized output
coltable="/opt/pihole/COL_TABLE"

# Root of the web server
webroot="/var/www/html"


# We clone (or update) two git repositories during the install. This helps to make sure that we always have the latest versions of the relevant files.
# AdminLTE is used to set up the Web admin interface.
# Pi-hole contains various setup scripts and files which are critical to the installation.
# Search for "PI_HOLE_LOCAL_REPO" in this file to see all such scripts.
# Two notable scripts are gravity.sh (used to generate the HOSTS file) and advanced/Scripts/webpage.sh (used to install the Web admin interface)
webInterfaceGitUrl="https://github.com/pi-hole/AdminLTE.git"
webInterfaceDir="${webroot}/admin"
piholeGitUrl="https://gitlab.com/yvelon/pi-hole.git"
PI_HOLE_LOCAL_REPO="/etc/.pihole"
# List of pihole scripts, stored in an array
PI_HOLE_FILES=(chronometer list piholeDebug piholeLogFlush setupLCD update version gravity uninstall webpage)
# This directory is where the Pi-hole scripts will be installed
PI_HOLE_INSTALL_DIR="/opt/pihole"
PI_HOLE_CONFIG_DIR="/etc/pihole"
PI_HOLE_BIN_DIR="/usr/local/bin"
PI_HOLE_404_DIR="${webroot}/pihole"
FTL_CONFIG_FILE="${PI_HOLE_CONFIG_DIR}/pihole-FTL.conf"
if [ -z "$useUpdateVars" ]; then
    useUpdateVars=false
fi

adlistFile="/etc/pihole/adlists.list"
# Pi-hole needs an IP address; to begin, these variables are empty since we don't know what the IP is until this script can run
IPV4_ADDRESS=${IPV4_ADDRESS}
IPV6_ADDRESS=${IPV6_ADDRESS}
# Give settings their default values. These may be changed by prompts later in the script.
QUERY_LOGGING=true
INSTALL_WEB_INTERFACE=true
PRIVACY_LEVEL=0
CACHE_SIZE=10000

# When running inside an LXC container, it may be the case that the variable
# $USER takes as value the user running the container.
# Since it is not listed under $id, the installation fails.
# Check $USER is listed in $id, and if not, run the script as root.

if ! grep -q "$USER" <(echo $(id)); then
	USER=root
fi

if [ -z "${USER}" ]; then
    USER="$(id -un)"
fi

# dialog dimensions: Let dialog handle appropriate sizing.
r=20
c=70

######## Undocumented Flags. Shhh ########
# These are undocumented flags; some of which we can use when repairing an installation
# The runUnattended flag is one example of this
reconfigure=false
runUnattended=false
INSTALL_WEB_SERVER=true
# Check arguments for the undocumented flags
for var in "$@"; do
    case "$var" in
        "--reconfigure" ) reconfigure=true;;
        "--unattended" ) runUnattended=true;;
        "--disable-install-webserver" ) INSTALL_WEB_SERVER=false;;
    esac
done

# If the color table file exists,
if [[ -f "${coltable}" ]]; then
    # source it
    source "${coltable}"
# Otherwise,
else
    # Set these values so the installer can still run in color
    COL_NC='\e[0m' # No Color
    COL_LIGHT_GREEN='\e[1;32m'
    COL_LIGHT_RED='\e[1;31m'
    TICK="[${COL_LIGHT_GREEN}✓${COL_NC}]"
    CROSS="[${COL_LIGHT_RED}✗${COL_NC}]"
    INFO="[i]"
    # shellcheck disable=SC2034
    DONE="${COL_LIGHT_GREEN} done!${COL_NC}"
    OVER="\\r\\033[K"
fi

# A simple function that just echoes out our logo in ASCII format
# This lets users know that it is a Pi-hole, LLC product
show_ascii_berry() {
    echo -e "
        ${COL_LIGHT_GREEN}.;;,.
        .ccccc:,.
         :cccclll:.      ..,,
          :ccccclll.   ;ooodc
           'ccll:;ll .oooodc
             .;cll.;;looo:.
                 ${COL_LIGHT_RED}.. ','.
                .',,,,,,'.
              .',,,,,,,,,,.
            .',,,,,,,,,,,,....
          ....''',,,,,,,'.......
        .........  ....  .........
        ..........      ..........
        ..........      ..........
        .........  ....  .........
          ........,,,,,,,'......
            ....',,,,,,,,,,,,.
               .',,,,,,,,,'.
                .',,,,,,'.
                  ..'''.${COL_NC}
"
}

is_command() {
    # Checks to see if the given command (passed as a string argument) exists on the system.
    # The function returns 0 (success) if the command exists, and 1 if it doesn't.
    local check_command="$1"

    command -v "${check_command}" >/dev/null 2>&1
}

os_check() {
    detected_os=$(grep "\bID\b" /etc/os-release | cut -d '=' -f2 | tr -d '"')
    detected_version=$(grep VERSION_ID /etc/os-release | cut -d '=' -f2 | tr -d '"')
    if ! grep -iq "alpine" <(echo "$detected_os"); then
        printf "This installer only supports Alpine Linux."
        printf "If you wish to install pi-hole for ${detected_os}, please refer to https://github.com/pi-hole/pi-hole."
        exit 1
    fi
}

# Compatibility
package_manager_detect() {
if is_command apk ; then
    PKG_MANAGER="apk"
    UPDATE_PKG_CACHE="${PKG_MANAGER} update"
    PKG_INSTALL=("${PKG_MANAGER}" add)
    PKG_COUNT="${PKG_MANAGER} upgrade --simulate --no-progress | head -n -1 | wc -l"
    INSTALLER_DEPS=(dialog git newt procps dhcpcd openrc ncurses newt git)
    PIHOLE_DEPS=(curl bind-tools nmap-ncat psmisc sudo unzip wget libidn nettle libcap openresolv iproute2-ss jq)
    UNBOUND_DEPS=(unbound)
    PIHOLE_WEB_DEPS=(lighttpd lighttpd-mod_auth fcgi php8 php8-cgi php8-sqlite3 php8-session php8-openssl php8-json php8-fileinfo php8-phar php8-intl)
    LIGHTTPD_USER="lighttpd"
    LIGHTTPD_GROUP="lighttpd"
    LIGHTTPD_CFG="lighttpd.conf.alpine"
# If apk package managers was not found
else
    # we cannot install required packages
    printf "  %b No supported package manager found\\n" "${CROSS}"
    # so exit the installer
    exit
fi
}

# A function for checking if a directory is a git repository
is_repo() {
    # Use a named, local variable instead of the vague $1, which is the first argument passed to this function
    # These local variables should always be lowercase
    local directory="${1}"
    # A variable to store the return code
    local rc
    # If the first argument passed to this function is a directory,
    if [[ -d "${directory}" ]]; then
        # move into the directory
        pushd "${directory}" &> /dev/null || return 1
        # Use git to check if the directory is a repo
        # git -C is not used here to support git versions older than 1.8.4
        git status --short &> /dev/null || rc=$?
    # If the command was not successful,
    else
        # Set a non-zero return code if directory does not exist
        rc=1
    fi
    # Move back into the directory the user started in
    popd &> /dev/null || return 1
    # Return the code; if one is not set, return 0
    return "${rc:-0}"
}

# A function to clone a repo
make_repo() {
    # Set named variables for better readability
    local directory="${1}"
    local remoteRepo="${2}"

    # The message to display when this function is running
    str="Clone ${remoteRepo} into ${directory}"
    # Display the message and use the color table to preface the message with an "info" indicator
    printf "  %b %s..." "${INFO}" "${str}"
    # If the directory exists,
    if [[ -d "${directory}" ]]; then
        # Return with a 1 to exit the installer. We don't want to overwrite what could already be here in case it is not ours
        str="Unable to clone ${remoteRepo} into ${directory} : Directory already exists"
        printf "%b  %b%s\\n" "${OVER}" "${CROSS}" "${str}"
        return 1
    fi
    # Clone the repo and return the return code from this command
    git clone -q --depth 20 "${remoteRepo}" "${directory}" &> /dev/null || return $?
    # Move into the directory that was passed as an argument
    pushd "${directory}" &> /dev/null || return 1
    # Check current branch. If it is master, then reset to the latest available tag.
    # In case extra commits have been added after tagging/release (i.e in case of metadata updates/README.MD tweaks)
    curBranch=$(git rev-parse --abbrev-ref HEAD)
    # Show a colored message showing it's status
    printf "%b  %b %s\\n" "${OVER}" "${TICK}" "${str}"
    # Data in the repositories is public anyway so we can make it readable by everyone (+r to keep executable permission if already set by git)
    chmod -R a+rX "${directory}"
    # Move back into the original directory
    popd &> /dev/null || return 1
    return 0
}

# We need to make sure the repos are up-to-date so we can effectively install Clean out the directory if it exists for git to clone into
update_repo() {
    # Use named, local variables
    # As you can see, these are the same variable names used in the last function,
    # but since they are local, their scope does not go beyond this function
    # This helps prevent the wrong value from being assigned if you were to set the variable as a GLOBAL one
    local directory="${1}"
    local curBranch

    # A variable to store the message we want to display;
    # Again, it's useful to store these in variables in case we need to reuse or change the message;
    # we only need to make one change here
    local str="Update repo in ${1}"
    # Move into the directory that was passed as an argument
    pushd "${directory}" &> /dev/null || return 1
    # Let the user know what's happening
    printf "  %b %s..." "${INFO}" "${str}"
    # Stash any local commits as they conflict with our working code
    git stash --all --quiet &> /dev/null || true # Okay for stash failure
    git clean --quiet --force -d || true # Okay for already clean directory
    # Pull the latest commits
    git pull --no-rebase --quiet &> /dev/null || return $?
    # Check current branch. If it is master, then reset to the latest available tag.
    # In case extra commits have been added after tagging/release (i.e in case of metadata updates/README.MD tweaks)
    curBranch=$(git rev-parse --abbrev-ref HEAD)
    # Show a completion message
    printf "%b  %b %s\\n" "${OVER}" "${TICK}" "${str}"
    # Data in the repositories is public anyway so we can make it readable by everyone (+r to keep executable permission if already set by git)
    chmod -R a+rX "${directory}"
    # Move back into the original directory
    popd &> /dev/null || return 1
    return 0
}

# A function that combines the previous git functions to update or clone a repo
getGitFiles() {
    # Setup named variables for the git repos
    # We need the directory
    local directory="${1}"
    # as well as the repo URL
    local remoteRepo="${2}"
    # A local variable containing the message to be displayed
    local str="Check for existing repository in ${1}"
    # Show the message
    printf "  %b %s..." "${INFO}" "${str}"
    # Check if the directory is a repository
    if is_repo "${directory}"; then
        # Show that we're checking it
        printf "%b  %b %s\\n" "${OVER}" "${TICK}" "${str}"
        # Update the repo, returning an error message on failure
        update_repo "${directory}" || { printf "\\n  %b: Could not update local repository. Contact support.%b\\n" "${COL_LIGHT_RED}" "${COL_NC}"; exit 1; }
    # If it's not a .git repo,
    else
        # Show an error
        printf "%b  %b %s\\n" "${OVER}" "${CROSS}" "${str}"
        # Attempt to make the repository, showing an error on failure
        make_repo "${directory}" "${remoteRepo}" || { printf "\\n  %bError: Could not update local repository. Contact support.%b\\n" "${COL_LIGHT_RED}" "${COL_NC}"; exit 1; }
    fi
    echo ""
    # Success via one of the two branches, as the commands would exit if they failed.
    return 0
}

# Reset a repo to get rid of any local changed
resetRepo() {
    # Use named variables for arguments
    local directory="${1}"
    # Move into the directory
    pushd "${directory}" &> /dev/null || return 1
    # Store the message in a variable
    str="Resetting repository within ${1}..."
    # Show the message
    printf "  %b %s..." "${INFO}" "${str}"
    # Use git to remove the local changes
    git reset --hard &> /dev/null || return $?
    # Data in the repositories is public anyway so we can make it readable by everyone (+r to keep executable permission if already set by git)
    chmod -R a+rX "${directory}"
    # And show the status
    printf "%b  %b %s\\n" "${OVER}" "${TICK}" "${str}"
    # Return to where we came from
    popd &> /dev/null || return 1
    # Function succeeded, as "git reset" would have triggered a return earlier if it failed
    return 0
}

find_IPv4_information() {
    # Detects IPv4 address used for communication to WAN addresses.
    # Accepts no arguments, returns no values.

    # Named, local variables
    local route
    local IPv4bare

    # Find IP used to route to outside world by checking the the route to Google's public DNS server
    route=$(ip route get 8.8.8.8)

    # Get just the interface IPv4 address
    # shellcheck disable=SC2059,SC2086
    # disabled as we intentionally want to split on whitespace and have printf populate
    # the variable with just the first field.
    printf -v IPv4bare "$(printf ${route#*src })"
    # Get the default gateway IPv4 address (the way to reach the Internet)
    # shellcheck disable=SC2059,SC2086
    printf -v IPv4gw "$(printf ${route#*via })"

    if ! valid_ip "${IPv4bare}" ; then
        IPv4bare="127.0.0.1"
    fi

    # Append the CIDR notation to the IP address, if valid_ip fails this should return 127.0.0.1/8
    IPV4_ADDRESS=$(ip -oneline -family inet address show | grep "${IPv4bare}/" |  awk '{print $4}' | awk 'END {print}')
}

# Get available interfaces that are UP
get_available_interfaces() {
    # There may be more than one so it's all stored in a variable
    availableInterfaces=$(ip --oneline link show up | grep -v "lo" | awk '{print $2}' | cut -d':' -f1 | cut -d'@' -f1)
}

# A function for displaying the dialogs the user sees when first running the installer
welcomeDialogs() {
    # Display the welcome dialog using an appropriately sized window via the calculation conducted earlier in the script
    dialog --no-shadow --clear --keep-tite \
        --backtitle "Welcome" \
            --title "Pi-hole Automated Installer" \
            --msgbox "\\n\\nThis installer will transform your device into a network-wide ad blocker!" \
            "${r}" "${c}" \
            --and-widget --clear \
        --backtitle "Support Pi-hole" \
            --title "Open Source Software" \
            --msgbox "\\n\\nThe Pi-hole is free, but powered by your donations:  https://pi-hole.net/donate/" \
            "${r}" "${c}" \
            --and-widget --clear \
        --colors \
            --backtitle "Initiating network interface" \
            --title "Static IP Needed" \
            --no-button "Exit" --yes-button "Continue" \
            --defaultno \
            --yesno "\\n\\nThe Pi-hole is a SERVER so it needs a STATIC IP ADDRESS to function properly.\\n\\n\
\\Zb\\Z1IMPORTANT:\\Zn If you have not already done so, you must ensure that this device has a static IP.\\n\\n\
Depending on your operating system, there are many ways to achieve this, through DHCP reservation, or by manually assigning one.\\n\\n\
Please continue when the static addressing has been configured."\
            "${r}" "${c}" && result=0 || result="$?"

         case "${result}" in
             "${DIALOG_CANCEL}" | "${DIALOG_ESC}")
                printf "  %b Installer exited at static IP message.\\n" "${INFO}"
                exit 1
                ;;
         esac
}

# A function that lets the user pick an interface to use with Pi-hole
chooseInterface() {
    # Turn the available interfaces into a string so it can be used with dialog
    local interfacesList
    # Number of available interfaces
    local interfaceCount

    # POSIX compliant way to get the number of elements in an array
    interfaceCount=$(printf "%s\n" "${availableInterfaces}" | wc -l)

    # If there is one interface,
    if [[ "${interfaceCount}" -eq 1 ]]; then
        # Set it as the interface to use since there is no other option
        PIHOLE_INTERFACE="${availableInterfaces}"
    # Otherwise,
    else
        # Set status for the first entry to be selected
        status="ON"

        # While reading through the available interfaces
        for interface in ${availableInterfaces}; do
            # Put all these interfaces into a string
            interfacesList="${interfacesList}${interface} available ${status} "
            # All further interfaces are deselected
            status="OFF"
        done
        # shellcheck disable=SC2086
        # Disable check for double quote here as we are passing a string with spaces
        PIHOLE_INTERFACE=$(dialog --no-shadow --keep-tite --output-fd 1 \
            --cancel-label "Exit" --ok-label "Select" \
            --radiolist "Choose An Interface (press space to toggle selection)" \
            ${r} ${c} "${interfaceCount}" ${interfacesList})

        result=$?
        case ${result} in
            "${DIALOG_CANCEL}"|"${DIALOG_ESC}")
                # Show an error message and exit
                printf "  %b %s\\n" "${CROSS}" "No interface selected, exiting installer"
                exit 1
                ;;
        esac

        printf "  %b Using interface: %s\\n" "${INFO}" "${PIHOLE_INTERFACE}"
    fi
}

# This lets us prefer ULA addresses over GUA
# This caused problems for some users when their ISP changed their IPv6 addresses
# See https://github.com/pi-hole/pi-hole/issues/1473#issuecomment-301745953
testIPv6() {
    # first will contain fda2 (ULA)
    printf -v first "%s" "${1%%:*}"
    # value1 will contain 253 which is the decimal value corresponding to 0xFD
    value1=$(( (0x$first)/256 ))
    # value2 will contain 162 which is the decimal value corresponding to 0xA2
    value2=$(( (0x$first)%256 ))
    # the ULA test is testing for fc00::/7 according to RFC 4193
    if (( (value1&254)==252 )); then
        # echoing result to calling function as return value
        echo "ULA"
    fi
    # the GUA test is testing for 2000::/3 according to RFC 4291
    if (( (value1&112)==32 )); then
        # echoing result to calling function as return value
        echo "GUA"
    fi
    # the LL test is testing for fe80::/10 according to RFC 4193
    if (( (value1)==254 )) && (( (value2&192)==128 )); then
        # echoing result to calling function as return value
        echo "Link-local"
    fi
}

find_IPv6_information() {
    # Detects IPv6 address used for communication to WAN addresses.
    mapfile -t IPV6_ADDRESSES <<<"$(ip -6 address | grep 'scope global' | awk '{print $2}')"

    # For each address in the array above, determine the type of IPv6 address it is
    for i in "${IPV6_ADDRESSES[@]}"; do
        # Check if it's ULA, GUA, or LL by using the function created earlier
        result=$(testIPv6 "$i")
        # If it's a ULA address, use it and store it as a global variable
        [[ "${result}" == "ULA" ]] && ULA_ADDRESS="${i%/*}"
        # If it's a GUA address, use it and store it as a global variable
        [[ "${result}" == "GUA" ]] && GUA_ADDRESS="${i%/*}"
        # Else if it's a Link-local address, we cannot use it, so just continue
    done

    # Determine which address to be used: Prefer ULA over GUA or don't use any if none found
    # If the ULA_ADDRESS contains a value,
    if [[ -n "${ULA_ADDRESS}" ]]; then
        # set the IPv6 address to the ULA address
        IPV6_ADDRESS="${ULA_ADDRESS}"
        # Show this info to the user
        printf "  %b Found IPv6 ULA address\\n" "${INFO}"
    # Otherwise, if the GUA_ADDRESS has a value,
    elif [[ -n "${GUA_ADDRESS}" ]]; then
        # Let the user know
        printf "  %b Found IPv6 GUA address\\n" "${INFO}"
        # And assign it to the global variable
        IPV6_ADDRESS="${GUA_ADDRESS}"
    # If none of those work,
    else
        printf "  %b Unable to find IPv6 ULA/GUA address\\n" "${INFO}"
        # So set the variable to be empty
        IPV6_ADDRESS=""
    fi
}

# A function to collect IPv4 and IPv6 information of the device
collect_v4andv6_information() {
    find_IPv4_information
    # Echo the information to the user
    printf "  %b IPv4 address: %s\\n" "${INFO}" "${IPV4_ADDRESS}"
    # if `dhcpcd` is used offer to set this as static IP for the device
    if [[ -f "/etc/dhcpcd.conf" ]]; then
        # configure networking via dhcpcd
        getStaticIPv4Settings
    fi
    find_IPv6_information
    printf "  %b IPv6 address: %s\\n" "${INFO}" "${IPV6_ADDRESS}"
}

getStaticIPv4Settings() {
    # Local, named variables
    local ipSettingsCorrect
    local DHCPChoice
    # Ask if the user wants to use DHCP settings as their static IP
    # This is useful for users that are using DHCP reservations; we can use the information gathered
    DHCPChoice=$(dialog --no-shadow --keep-tite --output-fd 1 \
        --cancel-label "Exit" --ok-label "Continue" \
        --backtitle "Calibrating network interface" \
        --title "Static IP Address" \
        --menu "Do you want to use your current network settings as a static address?\\n \
            IP address:    ${IPV4_ADDRESS}\\n \
            Gateway:       ${IPv4gw}\\n" \
            "${r}" "${c}" 3 \
                "Yes" "Set static IP using current values" \
                "No" "Set static IP using custom values" \
                "Skip" "I will set a static IP later, or have already done so" 2>&1 >/dev/tty)

        result=$?
        case ${result} in
            "${DIALOG_CANCEL}" | "${DIALOG_ESC}")
            printf "  %b Cancel was selected, exiting installer%b\\n" "${COL_LIGHT_RED}" "${COL_NC}"
            exit 1
            ;;
        esac

        case ${DHCPChoice} in
            "Skip")
                return
                ;;
            "Yes")
            # If they choose yes, let the user know that the IP address will not be available via DHCP and may cause a conflict.
            dialog --no-shadow --keep-tite \
                --cancel-label "Exit" \
                --backtitle "IP information" \
                --title "FYI: IP Conflict" \
                --msgbox "\\nIt is possible your router could still try to assign this IP to a device, which would cause a conflict, \
but in most cases the router is smart enough to not do that.\n\n\
If you are worried, either manually set the address, or modify the DHCP reservation pool so it does not include the IP you want.\n\n\
It is also possible to use a DHCP reservation, but if you are going to do that, you might as well set a static address."\
                "${r}" "${c}" && result=0 || result=$?

                case ${result} in
                    "${DIALOG_CANCEL}" | "${DIALOG_ESC}")
                    printf "  %b Cancel was selected, exiting installer%b\\n" "${COL_LIGHT_RED}" "${COL_NC}"
                    exit 1
                    ;;
                esac
            ;;

            "No")
            # Otherwise, we need to ask the user to input their desired settings.
            # Start by getting the IPv4 address (pre-filling it with info gathered from DHCP)
            # Start a loop to let the user enter their information with the chance to go back and edit it if necessary
            ipSettingsCorrect=false
            until [[ "${ipSettingsCorrect}" = True ]]; do

                # Ask for the IPv4 address
                _staticIPv4Temp=$(dialog --no-shadow --keep-tite --output-fd 1 \
                    --cancel-label "Exit" \
                    --ok-label "Continue" \
                    --backtitle "Calibrating network interface" \
                    --title "IPv4 Address" \
                    --form "\\nEnter your desired IPv4 address" \
                    "${r}" "${c}" 0 \
                        "IPv4 Address:" 1 1 "${IPV4_ADDRESS}" 1 15 19 0 \
                        "IPv4 Gateway:" 2 1 "${IPv4gw}" 2 15 19 0)

                result=$?
                case ${result} in
                    "${DIALOG_CANCEL}" | "${DIALOG_ESC}")
                    printf "  %b Cancel was selected, exiting installer%b\\n" "${COL_LIGHT_RED}" "${COL_NC}"
                    exit 1
                    ;;
                esac

                IPV4_ADDRESS=${_staticIPv4Temp%$'\n'*}
                IPv4gw=${_staticIPv4Temp#*$'\n'}

                # Give the user a chance to review their settings before moving on
                dialog --no-shadow --keep-tite \
                    --no-label "Edit IP" \
                    --backtitle "Calibrating network interface" \
                    --title "Static IP Address" \
                    --defaultno \
                    --yesno "Are these settings correct?
                        IP address: ${IPV4_ADDRESS}
                        Gateway:    ${IPv4gw}" \
                    "${r}" "${c}" && ipSettingsCorrect=True
            done
            ;;
       esac
       setDHCPCD
}

# Configure networking via dhcpcd
setDHCPCD() {
    # Check if the IP is already in the file
    if grep -q "${IPV4_ADDRESS}" /etc/dhcpcd.conf; then
        printf "  %b Static IP already configured\\n" "${INFO}"
    # If it's not,
    else
        # we can append these lines to dhcpcd.conf to enable a static IP
        echo "interface ${PIHOLE_INTERFACE}
        static ip_address=${IPV4_ADDRESS}
        static routers=${IPv4gw}
        static domain_name_servers=${PIHOLE_DNS_1} ${PIHOLE_DNS_2}" | tee -a /etc/dhcpcd.conf >/dev/null
        # Then use the ip command to immediately set the new address
        ip addr replace dev "${PIHOLE_INTERFACE}" "${IPV4_ADDRESS}"
        # Also give a warning that the user may need to reboot their system
        printf "  %b Set IP address to %s\\n" "${TICK}" "${IPV4_ADDRESS%/*}"
        printf "  %b You may need to restart after the install is complete\\n" "${INFO}"
    fi
}

# Check an IP address to see if it is a valid one
valid_ip() {
    # Local, named variables
    local ip=${1}
    local stat=1

    # Regex matching one IPv4 component, i.e. an integer from 0 to 255.
    # See https://tools.ietf.org/html/rfc1340
    local ipv4elem="(25[0-5]|2[0-4][0-9]|1[0-9][0-9]|[1-9][0-9]?|0)";
    # Regex matching an optional port (starting with '#') range of 1-65536
    local portelem="(#(6553[0-5]|655[0-2][0-9]|65[0-4][0-9]{2}|6[0-4][0-9]{3}|[1-5][0-9]{4}|[1-9][0-9]{0,3}|0))?";
    # Build a full IPv4 regex from the above subexpressions
    local regex="^${ipv4elem}\\.${ipv4elem}\\.${ipv4elem}\\.${ipv4elem}${portelem}$"

    # Evaluate the regex, and return the result
    [[ $ip =~ ${regex} ]]

    stat=$?
    return "${stat}"
}

valid_ip6() {
    local ip=${1}
    local stat=1

    # Regex matching one IPv6 element, i.e. a hex value from 0000 to FFFF
    local ipv6elem="[0-9a-fA-F]{1,4}"
    # Regex matching an IPv6 CIDR, i.e. 1 to 128
    local v6cidr="(\\/([1-9]|[1-9][0-9]|1[0-1][0-9]|12[0-8])){0,1}"
    # Regex matching an optional port (starting with '#') range of 1-65536
    local portelem="(#(6553[0-5]|655[0-2][0-9]|65[0-4][0-9]{2}|6[0-4][0-9]{3}|[1-5][0-9]{4}|[1-9][0-9]{0,3}|0))?";
    # Build a full IPv6 regex from the above subexpressions
    local regex="^(((${ipv6elem}))*((:${ipv6elem}))*::((${ipv6elem}))*((:${ipv6elem}))*|((${ipv6elem}))((:${ipv6elem})){7})${v6cidr}${portelem}$"

    # Evaluate the regex, and return the result
    [[ ${ip} =~ ${regex} ]]

    stat=$?
    return "${stat}"
}

# Easy installation of unbound
installUnbound() {
    local stat=0
    dialog --title "Install unbound" --yesno "Do you wish to install unbound? \\n Unbound is a DNS resolver.\\n    It affords greater privacy than using public DNS servers." "${r}" "${c}"
    stat=$?
    return "${stat}"
}


# A function to choose the upstream DNS provider(s)
setDNS() {
    # Local, named variables
    local DNSSettingsCorrect

    # In an array, list the available upstream providers
    DNSChooseOptions=()
    local DNSServerCount=0
    # Save the old Internal Field Separator in a variable,
    OIFS=$IFS
    # and set the new one to newline
    IFS=$'\n'
    # Put the DNS Servers into an array
    for DNSServer in ${DNS_SERVERS}
    do
        DNSName="$(cut -d';' -f1 <<< "${DNSServer}")"
        DNSChooseOptions[DNSServerCount]="${DNSName}"
        (( DNSServerCount=DNSServerCount+1 ))
        DNSChooseOptions[DNSServerCount]=""
        (( DNSServerCount=DNSServerCount+1 ))
    done
    DNSChooseOptions[DNSServerCount]="Custom"
    (( DNSServerCount=DNSServerCount+1 ))
    DNSChooseOptions[DNSServerCount]=""
    # Restore the IFS to what it was
    IFS=${OIFS}
    # In a dialog, show the options
    DNSchoices=$(dialog --no-shadow --keep-tite --output-fd 1 \
                    --cancel-label "Exit" \
                    --menu "Select Upstream DNS Provider. To use your own, select Custom." "${r}" "${c}" 7 \
        "${DNSChooseOptions[@]}")

        result=$?
        case ${result} in
            "${DIALOG_CANCEL}" | "${DIALOG_ESC}")
            printf "  %b Cancel was selected, exiting installer%b\\n" "${COL_LIGHT_RED}" "${COL_NC}"
            exit 1
            ;;
        esac

    # Depending on the user's choice, set the GLOBAL variables to the IP of the respective provider
    if [[ "${DNSchoices}" == "Custom" ]]
    then
        # Loop until we have a valid DNS setting
        until [[ "${DNSSettingsCorrect}" = True ]]; do
            # Signal value, to be used if the user inputs an invalid IP address
            strInvalid="Invalid"
            if [[ ! "${PIHOLE_DNS_1}" ]]; then
                if [[ ! "${PIHOLE_DNS_2}" ]]; then
                    # If the first and second upstream servers do not exist, do not prepopulate an IP address
                    prePopulate=""
                else
                    # Otherwise, prepopulate the dialogue with the appropriate DNS value(s)
                    prePopulate=", ${PIHOLE_DNS_2}"
                fi
            elif  [[ "${PIHOLE_DNS_1}" ]] && [[ ! "${PIHOLE_DNS_2}" ]]; then
                prePopulate="${PIHOLE_DNS_1}"
            elif [[ "${PIHOLE_DNS_1}" ]] && [[ "${PIHOLE_DNS_2}" ]]; then
                prePopulate="${PIHOLE_DNS_1}, ${PIHOLE_DNS_2}"
            fi

            # Prompt the user to enter custom upstream servers
            piholeDNS=$(dialog --no-shadow --keep-tite --output-fd 1 \
                            --cancel-label "Exit" \
                            --backtitle "Specify Upstream DNS Provider(s)" \
                            --inputbox "Enter your desired upstream DNS provider(s), separated by a comma.\
If you want to specify a port other than 53, separate it with a hash.\
\\n\\nFor example '8.8.8.8, 8.8.4.4' or '127.0.0.1#5335'"\
                                "${r}" "${c}" "${prePopulate}")

            result=$?
            case ${result} in
                "${DIALOG_CANCEL}" | "${DIALOG_ESC}")
                printf "  %b Cancel was selected, exiting installer%b\\n" "${COL_LIGHT_RED}" "${COL_NC}"
                exit 1
                ;;
            esac

            # Clean user input and replace whitespace with comma.
            piholeDNS=$(sed 's/[, \t]\+/,/g' <<< "${piholeDNS}")

            # Separate the user input into the two DNS values (separated by a comma)
            printf -v PIHOLE_DNS_1 "%s" "${piholeDNS%%,*}"
            printf -v PIHOLE_DNS_2 "%s" "${piholeDNS##*,}"

            # If the first DNS value is invalid or empty, this if statement will be true and we will set PIHOLE_DNS_1="Invalid"
            if ! valid_ip "${PIHOLE_DNS_1}" || [[ ! "${PIHOLE_DNS_1}" ]]; then
                PIHOLE_DNS_1=${strInvalid}
            fi
            # If the second DNS value is invalid or empty, this if statement will be true and we will set PIHOLE_DNS_2="Invalid"
            if ! valid_ip "${PIHOLE_DNS_2}" && [[ "${PIHOLE_DNS_2}" ]]; then
                PIHOLE_DNS_2=${strInvalid}
            fi
            # If either of the DNS servers are invalid,
            if [[ "${PIHOLE_DNS_1}" == "${strInvalid}" ]] || [[ "${PIHOLE_DNS_2}" == "${strInvalid}" ]]; then
                # explain this to the user,
                dialog --no-shadow --keep-tite \
                    --title "Invalid IP Address(es)" \
                    --backtitle "Invalid IP" \
                    --msgbox "\\nOne or both of the entered IP addresses were invalid. Please try again.\
\\n\\nInvalid IPs: ${PIHOLE_DNS_1}, ${PIHOLE_DNS_2}" \
                    "${r}" "${c}"

                # set the variables back to nothing,
                if [[ "${PIHOLE_DNS_1}" == "${strInvalid}" ]]; then
                    PIHOLE_DNS_1=""
                fi
                if [[ "${PIHOLE_DNS_2}" == "${strInvalid}" ]]; then
                    PIHOLE_DNS_2=""
                fi
                # and continue the loop.
                DNSSettingsCorrect=False
            else
                dialog --no-shadow --no-collapse --keep-tite \
                    --backtitle "Specify Upstream DNS Provider(s)" \
                    --title "Upstream DNS Provider(s)" \
                    --yesno "Are these settings correct?\\n"$'\t'"DNS Server 1:"$'\t'"${PIHOLE_DNS_1}\\n"$'\t'"DNS Server 2:"$'\t'"${PIHOLE_DNS_2}" \
                    "${r}" "${c}" && result=0 || result=$?

                case ${result} in
                    "${DIALOG_OK}")
                        DNSSettingsCorrect=True
                        ;;
                    "${DIALOG_CANCEL}")
                        DNSSettingsCorrect=False
                        ;;
                    "${DIALOG_ESC}")
                        printf "  %b Escape pressed, exiting installer at DNS Settings%b\\n" "${COL_LIGHT_RED}" "${COL_NC}"
                        exit 1
                        ;;
                esac
            fi
        done
    else
        # Save the old Internal Field Separator in a variable,
        OIFS=$IFS
        # and set the new one to newline
        IFS=$'\n'
        for DNSServer in ${DNS_SERVERS}
        do
            DNSName="$(cut -d';' -f1 <<< "${DNSServer}")"
            if [[ "${DNSchoices}" == "${DNSName}" ]]
            then
                PIHOLE_DNS_1="$(cut -d';' -f2 <<< "${DNSServer}")"
                PIHOLE_DNS_2="$(cut -d';' -f3 <<< "${DNSServer}")"
                break
            fi
        done
        # Restore the IFS to what it was
        IFS=${OIFS}
    fi

    # Display final selection
    local DNSIP=${PIHOLE_DNS_1}
    [[ -z ${PIHOLE_DNS_2} ]] || DNSIP+=", ${PIHOLE_DNS_2}"
    printf "  %b Using upstream DNS: %s (%s)\\n" "${INFO}" "${DNSchoices}" "${DNSIP}"
}

# Allow the user to enable/disable logging
setLogging() {
    # Ask the user if they want to enable logging
    dialog --no-shadow --keep-tite \
        --backtitle "Pihole Installation" \
        --title "Enable Logging" \
        --yesno "\\n\\nWould you like to enable query logging?" \
        "${r}" "${c}" && result=0 || result=$?

    case ${result} in
        "${DIALOG_OK}")
            # If they chose yes,
            printf "  %b Query Logging on.\\n" "${INFO}"
            QUERY_LOGGING=true
            ;;
        "${DIALOG_CANCEL}")
            # If they chose no,
            printf "  %b Query Logging off.\\n" "${INFO}"
            QUERY_LOGGING=false
            ;;
        "${DIALOG_ESC}")
            # User pressed <ESC>
            printf "  %b Escape pressed, exiting installer at Query Logging choice.%b\\n" "${COL_LIGHT_RED}" "${COL_NC}"
            exit 1
            ;;
    esac
}

# Allow the user to set their FTL privacy level
setPrivacyLevel() {
    # The default selection is level 0
    PRIVACY_LEVEL=$(dialog --no-shadow --keep-tite --output-fd 1 \
        --cancel-label "Exit" \
        --ok-label "Continue" \
        --radiolist "Select a privacy mode for FTL. https://docs.pi-hole.net/ftldns/privacylevels/" \
        "${r}" "${c}" 6 \
        "0" "Show everything" on \
        "1" "Hide domains" off \
        "2" "Hide domains and clients" off \
        "3" "Anonymous mode" off 2>&1 >/dev/tty)

        result=$?
        case ${result} in
            "${DIALOG_OK}")
                printf "  %b Using privacy level: %s\\n" "${INFO}" "${PRIVACY_LEVEL}"
                ;;
            "${DIALOG_CANCEL}" | "${DIALOG_ESC}")
                printf "  %b Cancelled privacy level selection.%b\\n" "${COL_LIGHT_RED}" "${COL_NC}"
                exit 1
                ;;
        esac
}

# Function to ask the user if they want to install the dashboard
setAdminFlag() {
    # Similar to the logging function, ask what the user wants
    dialog --no-shadow --keep-tite \
        --backtitle "Pihole Installation" \
        --title "Admin Web Interface" \
        --yesno "\\n\\nDo you want to install the Admin Web Interface?" \
        "${r}" "${c}" && result=0 || result=$?

    case ${result} in
        "${DIALOG_OK}")
            # If they chose yes,
            printf "  %b Installing Admin Web Interface\\n" "${INFO}"
            # Set the flag to install the web interface
            INSTALL_WEB_INTERFACE=true
            ;;
        "${DIALOG_CANCEL}")
            # If they chose no,
            printf "  %b Not installing Admin Web Interface\\n" "${INFO}"
            # Set the flag to not install the web interface
            INSTALL_WEB_INTERFACE=false
            INSTALL_WEB_SERVER=false
            ;;
        "${DIALOG_ESC}")
            # User pressed <ESC>
            printf "  %b Escape pressed, exiting installer at Admin Web Interface choice.%b\\n" "${COL_LIGHT_RED}" "${COL_NC}"
            exit 1
            ;;
    esac

    # If the user wants to install the Web admin interface (i.e. it has not been deselected above) and did not deselect the web server via command-line argument
    if [[ "${INSTALL_WEB_INTERFACE}" == true && "${INSTALL_WEB_SERVER}" == true ]]; then
        # Get list of required PHP modules, excluding base package (common) and handler (cgi)
        local i php_modules
        for i in "${PIHOLE_WEB_DEPS[@]}"; do [[ $i == 'php'* && $i != *'-common' && $i != *'-cgi' ]] && php_modules+=" ${i#*-}"; done
        dialog --no-shadow --keep-tite \
            --backtitle "Pi-hole Installation" \
            --title "Web Server" \
            --yesno "\\n\\nA web server is required for the Admin Web Interface.\
\\n\\nDo you want to install lighttpd and the required PHP modules?\
\\n\\nNB: If you disable this, and, do not have an existing web server \
and required PHP modules (${php_modules# }) installed, the web interface \
will not function. Additionally the web server user needs to be member of \
the \"pihole\" group for full functionality." \
            "${r}" "${c}" && result=0 || result=$?

        case ${result} in
            "${DIALOG_OK}")
                # If they chose yes,
                printf "  %b Installing lighttpd\\n" "${INFO}"
                # Set the flag to install the web server
                INSTALL_WEB_SERVER=true
                ;;
            "${DIALOG_CANCEL}")
                # If they chose no,
                printf "  %b Not installing lighttpd\\n" "${INFO}"
                # Set the flag to not install the web server
                INSTALL_WEB_SERVER=false
                ;;
            "${DIALOG_ESC}")
                # User pressed <ESC>
                printf "  %b Escape pressed, exiting installer at web server choice.%b\\n" "${COL_LIGHT_RED}" "${COL_NC}"
                exit 1
                ;;
        esac
    fi
}

# A function to display a list of example blocklists for users to select
chooseBlocklists() {
    # Back up any existing adlist file, on the off chance that it exists. Useful in case of a reconfigure.
    if [[ -f "${adlistFile}" ]]; then
        mv "${adlistFile}" "${adlistFile}.old"
    fi
    # Let user select (or not) blocklists
    dialog --no-shadow --keep-tite \
        --backtitle "Pi-hole Installation" \
        --title "Blocklists" \
        --yesno "\\nPi-hole relies on third party lists in order to block ads.\
\\n\\nYou can use the suggestion below, and/or add your own after installation.\
\\n\\nSelect 'Yes' to include:\
\\n\\nStevenBlack's Unified Hosts List" \
        "${r}" "${c}" && result=0 || result=$?

    case ${result} in
        "${DIALOG_OK}")
            # If they chose yes,
            printf "  %b Installing StevenBlack's Unified Hosts List\\n" "${INFO}"
            echo "https://raw.githubusercontent.com/StevenBlack/hosts/master/hosts" >> "${adlistFile}"
            ;;
        "${DIALOG_CANCEL}")
            # If they chose no,
            printf "  %b Not installing StevenBlack's Unified Hosts List\\n" "${INFO}"
            ;;
        "${DIALOG_ESC}")
            # User pressed <ESC>
            printf "  %b Escape pressed, exiting installer at blocklist choice.%b\\n" "${COL_LIGHT_RED}" "${COL_NC}"
            exit 1
            ;;
    esac
    # Create an empty adList file with appropriate permissions.
    if [ ! -f "${adlistFile}" ]; then
        install -m 644 /dev/null "${adlistFile}"
    else
        chmod 644 "${adlistFile}"
    fi
}

# Used only in unattended setup
# If there is already the adListFile, we keep it, else we create it using all default lists
installDefaultBlocklists() {
    # In unattended setup, could be useful to use userdefined blocklist.
    # If this file exists, we avoid overriding it.
    if [[ -f "${adlistFile}" ]]; then
        return;
    fi
        echo "https://raw.githubusercontent.com/StevenBlack/hosts/master/hosts" >> "${adlistFile}"
}

# Check if /etc/dnsmasq.conf is from pi-hole.  If so replace with an original and install new in .d directory
version_check_dnsmasq() {
    # Local, named variables
    local dnsmasq_conf="/etc/dnsmasq.conf"
    local dnsmasq_conf_orig="/etc/dnsmasq.conf.orig"
    local dnsmasq_pihole_id_string="addn-hosts=/etc/pihole/gravity.list"
    local dnsmasq_pihole_id_string2="# Dnsmasq config for Pi-hole's FTLDNS"
    local dnsmasq_original_config="${PI_HOLE_LOCAL_REPO}/advanced/dnsmasq.conf.original"
    local dnsmasq_pihole_01_source="${PI_HOLE_LOCAL_REPO}/advanced/01-pihole.conf"
    local dnsmasq_pihole_01_target="/etc/dnsmasq.d/01-pihole.conf"
    local dnsmasq_rfc6761_06_source="${PI_HOLE_LOCAL_REPO}/advanced/06-rfc6761.conf"
    local dnsmasq_rfc6761_06_target="/etc/dnsmasq.d/06-rfc6761.conf"

    # If the dnsmasq config file exists
    if [[ -f "${dnsmasq_conf}" ]]; then
        printf "  %b Existing dnsmasq.conf found..." "${INFO}"
        # If a specific string is found within this file, we presume it's from older versions on Pi-hole,
        if grep -q "${dnsmasq_pihole_id_string}" "${dnsmasq_conf}" ||
           grep -q "${dnsmasq_pihole_id_string2}" "${dnsmasq_conf}"; then
            printf " it is from a previous Pi-hole install.\\n"
            printf "  %b Backing up dnsmasq.conf to dnsmasq.conf.orig..." "${INFO}"
            # so backup the original file,
            mv -f "${dnsmasq_conf}" "${dnsmasq_conf_orig}"
            printf "%b  %b Backing up dnsmasq.conf to dnsmasq.conf.orig...\\n" "${OVER}"  "${TICK}"
            printf "  %b Restoring default dnsmasq.conf..." "${INFO}"
            # and replace it with the default
            install -D -m 644 "${dnsmasq_original_config}" "${dnsmasq_conf}"
            printf "%b  %b Restoring default dnsmasq.conf...\\n" "${OVER}"  "${TICK}"
        else
            # Otherwise, don't to anything
            printf " it is not a Pi-hole file, leaving alone!\\n"
        fi
    else
        # If a file cannot be found,
        printf "  %b No dnsmasq.conf found... restoring default dnsmasq.conf..." "${INFO}"
        # restore the default one
        install -D -m 644 "${dnsmasq_original_config}" "${dnsmasq_conf}"
        printf "%b  %b No dnsmasq.conf found... restoring default dnsmasq.conf...\\n" "${OVER}"  "${TICK}"
    fi

    printf "  %b Installing %s..." "${INFO}" "${dnsmasq_pihole_01_target}"
    # Check to see if dnsmasq directory exists (it may not due to being a fresh install and dnsmasq no longer being a dependency)
    if [[ ! -d "/etc/dnsmasq.d"  ]];then
        install -d -m 755 "/etc/dnsmasq.d"
    fi
    # Copy the new Pi-hole DNS config file into the dnsmasq.d directory
    install -D -m 644 "${dnsmasq_pihole_01_source}" "${dnsmasq_pihole_01_target}"
    printf "%b  %b Installed %s\n" "${OVER}"  "${TICK}" "${dnsmasq_pihole_01_target}"
    # Add settings with the GLOBAL DNS variables that we populated earlier
    # First, set the interface to listen on
    addOrEditKeyValPair "${dnsmasq_pihole_01_target}" "interface" "$PIHOLE_INTERFACE"
    if [[ "${PIHOLE_DNS_1}" != "" ]]; then
        # then add in the primary DNS server.
        addOrEditKeyValPair "${dnsmasq_pihole_01_target}" "server" "$PIHOLE_DNS_1"
    fi
    # Ditto if DNS2 is not empty
    if [[ "${PIHOLE_DNS_2}" != "" ]]; then
        addKey "${dnsmasq_pihole_01_target}" "server=$PIHOLE_DNS_2"
    fi

    # Set the cache size
    addOrEditKeyValPair "${dnsmasq_pihole_01_target}" "cache-size" "$CACHE_SIZE"

    sed -i 's/^#conf-dir=\/etc\/dnsmasq.d$/conf-dir=\/etc\/dnsmasq.d/' "${dnsmasq_conf}"

    # If the user does not want to enable logging,
    if [[ "${QUERY_LOGGING}" == false ]] ; then
        # remove it from the DNS config file
        removeKey "${dnsmasq_pihole_01_target}" "log-queries"
    else
        # Otherwise, enable it by adding the directive to the DNS config file
        addKey "${dnsmasq_pihole_01_target}" "log-queries"
    fi

    printf "  %b Installing %s..." "${INFO}" "${dnsmasq_rfc6761_06_source}"
    install -D -m 644 "${dnsmasq_rfc6761_06_source}" "${dnsmasq_rfc6761_06_target}"
    printf "%b  %b Installed %s\n" "${OVER}"  "${TICK}" "${dnsmasq_rfc6761_06_target}"
}

# Clean an existing installation to prepare for upgrade/reinstall
clean_existing() {
    # Local, named variables
    # ${1} Directory to clean
    local clean_directory="${1}"
    # Pop the first argument, and shift all addresses down by one (i.e. ${2} becomes ${1})
    shift
    # Then, we can access all arguments ($@) without including the directory to clean
    local old_files=( "$@" )

    # Remove each script in the old_files array
    for script in "${old_files[@]}"; do
        rm -f "${clean_directory}/${script}.sh"
    done
}

get_download_url() {
    local arch=$(uname -m)
    case "$arch" in
        x86_64)
	    download_url="https://gitlab.com/yvelon/pihole-FTL-alpine/-/package_files/58428479/download";;
        i686)
	    download_url="https://gitlab.com/yvelon/pihole-FTL-alpine/-/package_files/58428804/download";;
        armv7l)
	    download_url="https://gitlab.com/yvelon/pihole-FTL-alpine/-/package_files/58552166/download";;
	aarch64)
	    download_url="https://gitlab.com/yvelon/pihole-FTL-alpine/-/package_files/58555597/download";;
        *)
            download_url="";;
   esac
   echo "$download_url"
}

# Install the scripts from repository to their various locations
installScripts() {
    # Local, named variables
    local str="Installing scripts from ${PI_HOLE_LOCAL_REPO}"
    printf "  %b %s..." "${INFO}" "${str}"

    # Clear out script files from Pi-hole scripts directory.
    clean_existing "${PI_HOLE_INSTALL_DIR}" "${PI_HOLE_FILES[@]}"

    # Install files from local core repository
    if is_repo "${PI_HOLE_LOCAL_REPO}"; then
        # move into the directory
        cd "${PI_HOLE_LOCAL_REPO}"
        # Install the scripts by:
        #  -o setting the owner to the user
        #  -Dm755 create all leading components of destination except the last, then copy the source to the destination and setting the permissions to 755
        #
        # This first one is the directory
        install -o "${USER}" -Dm755 -d "${PI_HOLE_INSTALL_DIR}"
        # The rest are the scripts Pi-hole needs
        install -o "${USER}" -Dm755 -t "${PI_HOLE_INSTALL_DIR}" gravity.sh
        install -o "${USER}" -Dm755 -t "${PI_HOLE_INSTALL_DIR}" ./advanced/Scripts/*.sh
        install -o "${USER}" -Dm755 -t "${PI_HOLE_INSTALL_DIR}" ./automated\ install/uninstall.sh
        install -o "${USER}" -Dm755 -t "${PI_HOLE_INSTALL_DIR}" ./advanced/Scripts/COL_TABLE
        install -o "${USER}" -Dm755 -t "${PI_HOLE_BIN_DIR}" pihole
        install -Dm644 ./advanced/bash-completion/pihole /etc/bash_completion.d/pihole
        printf "%b  %b %s\\n" "${OVER}" "${TICK}" "${str}"

    else
        # Otherwise, show an error and exit
        printf "%b  %b %s\\n" "${OVER}"  "${CROSS}" "${str}"
        printf "\\t\\t%bError: Local repo %s not found, exiting installer%b\\n" "${COL_LIGHT_RED}" "${PI_HOLE_LOCAL_REPO}" "${COL_NC}"
        return 1
    fi
}

# Install the configs from PI_HOLE_LOCAL_REPO to their various locations
installConfigs() {
    printf "\\n  %b Installing configs from %s...\\n" "${INFO}" "${PI_HOLE_LOCAL_REPO}"
    # Make sure Pi-hole's config files are in place
    version_check_dnsmasq

    # Install list of DNS servers
    # Format: Name;Primary IPv4;Secondary IPv4;Primary IPv6;Secondary IPv6
    # Some values may be empty (for example: DNS servers without IPv6 support)
    echo "${DNS_SERVERS}" > "${PI_HOLE_CONFIG_DIR}/dns-servers.conf"
    chmod 644 "${PI_HOLE_CONFIG_DIR}/dns-servers.conf"

    # Install template file if it does not exist
    if [[ ! -r "${FTL_CONFIG_FILE}" ]]; then
        install -d -m 0755 ${PI_HOLE_CONFIG_DIR}
        if ! install -o pihole -m 664 "${PI_HOLE_LOCAL_REPO}/advanced/Templates/pihole-FTL.conf" "${FTL_CONFIG_FILE}" &>/dev/null; then
            printf "  %b Error: Unable to initialize configuration file %s/pihole-FTL.conf\\n" "${COL_LIGHT_RED}" "${PI_HOLE_CONFIG_DIR}"
            return 1
        fi
    fi

    # Install empty custom.list file if it does not exist
    if [[ ! -r "${PI_HOLE_CONFIG_DIR}/custom.list" ]]; then
        if ! install -o root -m 644 /dev/null "${PI_HOLE_CONFIG_DIR}/custom.list" &>/dev/null; then
            printf "  %b Error: Unable to initialize configuration file %s/custom.list\\n" "${COL_LIGHT_RED}" "${PI_HOLE_CONFIG_DIR}"
            return 1
        fi
    fi

    # Install pihole-FTL.service
    install -m 0755 "${PI_HOLE_LOCAL_REPO}/advanced/Templates/pihole-FTL.service" "/etc/init.d/pihole-FTL"

    # If the user chose to install the dashboard,
    if [[ "${INSTALL_WEB_SERVER}" == true ]]; then
        # and if the Web server conf directory does not exist,
        if [[ ! -d "/etc/lighttpd" ]]; then
            # make it and set the owners
            install -d -m 755 -o "${USER}" -g root /etc/lighttpd
        # Otherwise, if the config file already exists
        elif [[ -f "${lighttpdConfig}" ]]; then
            # back up the original
            mv "${lighttpdConfig}"{,.orig}
        fi
        # and copy in the config file Pi-hole needs
        install -D -m 644 ${PI_HOLE_LOCAL_REPO}/advanced/${LIGHTTPD_CFG} "${lighttpdConfig}"
        # In some cases, the php binary ends in 8 or not, modify the config file accordingly
        if ls /usr/bin | grep -q php-cgi8; then
            sed -i 's|/usr/bin/php-cgi|/usr/bin/php-cgi8|g'  "${lighttpdConfig}"
        fi
        # Make sure the external.conf file exists, as lighttpd v1.4.50 crashes without it
        if [ ! -f /etc/lighttpd/external.conf ]; then
            install -m 644 /dev/null /etc/lighttpd/external.conf
        fi
        # If there is a custom block page in the html/pihole directory, replace 404 handler in lighttpd config
        if [[ -f "${PI_HOLE_404_DIR}/custom.php" ]]; then
            sed -i 's/^\(server\.error-handler-404\s*=\s*\).*$/\1"\/pihole\/custom\.php"/' "${lighttpdConfig}"
        fi
        # Make the directories if they do not exist and set the owners
        mkdir -p /run/lighttpd
        chown ${LIGHTTPD_USER}:${LIGHTTPD_GROUP} /run/lighttpd
        mkdir -p /var/cache/lighttpd/compress
        chown ${LIGHTTPD_USER}:${LIGHTTPD_GROUP} /var/cache/lighttpd/compress
        mkdir -p /var/cache/lighttpd/uploads
        chown ${LIGHTTPD_USER}:${LIGHTTPD_GROUP} /var/cache/lighttpd/uploads
    fi
}

install_manpage() {
    # Copy Pi-hole man pages and call mandb to update man page database
    # Default location for man files for /usr/local/bin is /usr/local/share/man
    # on lightweight systems may not be present, so check before copying.
    printf "  %b Testing man page installation" "${INFO}"
    if ! is_command mandb ; then
        # if mandb is not present, no manpage support
        printf "%b  %b man not installed\\n" "${OVER}" "${INFO}"
        return
    elif [[ ! -d "/usr/local/share/man" ]]; then
        # appropriate directory for Pi-hole's man page is not present
        printf "%b  %b man pages not installed\\n" "${OVER}" "${INFO}"
        return
    fi
    if [[ ! -d "/usr/local/share/man/man8" ]]; then
        # if not present, create man8 directory
        install -d -m 755 /usr/local/share/man/man8
    fi
    if [[ ! -d "/usr/local/share/man/man5" ]]; then
        # if not present, create man5 directory
        install -d -m 755 /usr/local/share/man/man5
    fi
    # Testing complete, copy the files & update the man db
    install -D -m 644 ${PI_HOLE_LOCAL_REPO}/manpages/pihole.8 /usr/local/share/man/man8/pihole.8
    install -D -m 644 ${PI_HOLE_LOCAL_REPO}/manpages/pihole-FTL.8 /usr/local/share/man/man8/pihole-FTL.8

    # remove previously installed "pihole-FTL.conf.5" man page
    if [[ -f "/usr/local/share/man/man5/pihole-FTL.conf.5" ]]; then
        rm /usr/local/share/man/man5/pihole-FTL.conf.5
    fi

    if mandb -q &>/dev/null; then
        # Updated successfully
        printf "%b  %b man pages installed and database updated\\n" "${OVER}" "${TICK}"
        return
    else
        # Something is wrong with the system's man installation, clean up
        # our files, (leave everything how we found it).
        rm /usr/local/share/man/man8/pihole.8 /usr/local/share/man/man8/pihole-FTL.8
        printf "%b  %b man page db not updated, man pages not installed\\n" "${OVER}" "${CROSS}"
    fi
}

stop_service() {
    # Stop service passed in as argument.
    # Can softfail, as process may not be installed when this is called
    local str="Stopping ${1} service"
    printf "  %b %s..." "${INFO}" "${str}"
    service "${1}" stop &> /dev/null || true
    printf "%b  %b %s...\\n" "${OVER}" "${TICK}" "${str}"
}

# Start/Restart service passed in as argument
restart_service() {
    # Local, named variables
    local str="Restarting ${1} service"
    printf "  %b %s..." "${INFO}" "${str}"
    service "${1}" restart &> /dev/null
    printf "%b  %b %s...\\n" "${OVER}" "${TICK}" "${str}"
}

# Enable service so that it will start with next reboot
enable_service() {
    # Local, named variables
    local str="Enabling ${1} service to start on reboot"
    printf "  %b %s..." "${INFO}" "${str}"
    rc-update add "${1}" &> /dev/null
    printf "%b  %b %s...\\n" "${OVER}" "${TICK}" "${str}"
}

# Disable service so that it will not with next reboot
disable_service() {
    # Local, named variables
    local str="Disabling ${1} service"
    printf "  %b %s..." "${INFO}" "${str}"
    rc-update del "${1}" &> /dev/null
    printf "%b  %b %s...\\n" "${OVER}" "${TICK}" "${str}"
}

check_service_active() {
    rc-update show "${1}" &> /dev/null
}

update_package_cache() {
    # Update package cache on apt based OSes. Do this every time since
    # it's quick and packages can be updated at any time.

    # Local, named variables
    local str="Update local cache of available packages"
    printf "  %b %s..." "${INFO}" "${str}"
    # Create a command from the package cache variable
    if eval "${UPDATE_PKG_CACHE}" &> /dev/null; then
        printf "%b  %b %s\\n" "${OVER}" "${TICK}" "${str}"
    else
        # Otherwise, show an error and exit
        printf "%b  %b %s\\n" "${OVER}" "${CROSS}" "${str}"
        printf "  %b Error: Unable to update package cache. Please try \"%s\"%b\\n" "${COL_LIGHT_RED}" "sudo ${UPDATE_PKG_CACHE}" "${COL_NC}"
        return 1
    fi
}

# Let user know if they have outdated packages on their system and
# advise them to run a package update at soonest possible.
notify_package_updates_available() {
    # Local, named variables
    local str="Checking ${PKG_MANAGER} for upgraded packages"
    printf "\\n  %b %s..." "${INFO}" "${str}"
    # Store the list of packages in a variable
    updatesToInstall=$(eval "${PKG_COUNT}")

    if [[ -d "/lib/modules/$(uname -r)" ]]; then
        if [[ "${updatesToInstall}" -eq 0 ]]; then
            printf "%b  %b %s... up to date!\\n\\n" "${OVER}" "${TICK}" "${str}"
        else
            printf "%b  %b %s... %s updates available\\n" "${OVER}" "${TICK}" "${str}" "${updatesToInstall}"
            printf "  %b %bIt is recommended to update your OS after installing the Pi-hole!%b\\n\\n" "${INFO}" "${COL_LIGHT_GREEN}" "${COL_NC}"
        fi
    else
        printf "%b  %b %s\\n" "${OVER}" "${CROSS}" "${str}"
        printf "      Kernel update detected. If the install fails, please reboot and try again\\n"
    fi
}

install_dependent_packages() {
    # Install packages passed in via argument array
    # No spinner - conflicts with set -e
    declare -a installArray

    for i in "$@"; do
        printf "  %b Checking for %s..." "${INFO}" "${i}"
        if "${PKG_MANAGER}" info | grep -Eq "^${i}\$" &> /dev/null; then
            printf "%b  %b Checking for %s\\n" "${OVER}" "${TICK}" "${i}"
        else
            printf "%b  %b Checking for %s (will be installed)\\n" "${OVER}" "${INFO}" "${i}"
            installArray+=("${i}")
        fi
    done
    # If there's anything to install, install everything in the list.
    if [[ "${#installArray[@]}" -gt 0 ]]; then
        printf "  %b Processing %s install(s) for: %s, please wait...\\n" "${INFO}" "${PKG_MANAGER}" "${installArray[*]}"
        printf '%*s\n' "${c}" '' | tr " " -;
        "${PKG_INSTALL[@]}" "${installArray[@]}"
        printf '%*s\n' "${c}" '' | tr " " -;

        # Initialize openrc if we installed it
        if [[ "${installArray[*]}" =~ "openrc" ]] && [[ ! -d /run/openrc ]]; then
            mkdir /run/openrc
            touch /run/openrc/softlevel
            openrc
        fi
        return
    fi
    printf "\\n"
    return 0
}

# Install the Web interface dashboard
installPiholeWeb() {
    printf "\\n  %b Installing 404 page...\\n" "${INFO}"

    local str="Creating directory for 404 page, and copying files"
    printf "  %b %s..." "${INFO}" "${str}"
    # Install the directory
    install -d -m 0755 ${PI_HOLE_404_DIR}
    # and the 404 handler
    install -D -m 644 ${PI_HOLE_LOCAL_REPO}/advanced/index.php ${PI_HOLE_404_DIR}/

    printf "%b  %b %s\\n" "${OVER}" "${TICK}" "${str}"

    local str="Backing up index.lighttpd.html"
    printf "  %b %s..." "${INFO}" "${str}"
    # If the default index file exists,
    if [[ -f "${webroot}/index.lighttpd.html" ]]; then
        # back it up
        mv ${webroot}/index.lighttpd.html ${webroot}/index.lighttpd.orig
        printf "%b  %b %s\\n" "${OVER}" "${TICK}" "${str}"
    else
        # Otherwise, don't do anything
        printf "%b  %b %s\\n" "${OVER}" "${INFO}" "${str}"
        printf "      No default index.lighttpd.html file found... not backing up\\n"
    fi

    # Install Sudoers file
    local str="Installing sudoer file"
    printf "\\n  %b %s..." "${INFO}" "${str}"
    # Make the .d directory if it doesn't exist,
    install -d -m 755 /etc/sudoers.d/
    # and copy in the pihole sudoers file
    install -m 0640 ${PI_HOLE_LOCAL_REPO}/advanced/Templates/pihole.sudo /etc/sudoers.d/pihole
    # Add lighttpd user (OS dependent) to sudoers file
    echo "${LIGHTTPD_USER} ALL=NOPASSWD: ${PI_HOLE_BIN_DIR}/pihole" >> /etc/sudoers.d/pihole

    # If the Web server user is lighttpd,
    if [[ "$LIGHTTPD_USER" == "lighttpd" ]]; then
        # Allow executing pihole via sudo with Fedora
        # Usually /usr/local/bin ${PI_HOLE_BIN_DIR} is not permitted as directory for sudoable programs
        echo "Defaults secure_path = /sbin:/bin:/usr/sbin:/usr/bin:${PI_HOLE_BIN_DIR}" >> /etc/sudoers.d/pihole
    fi
    # Set the strict permissions on the file
    chmod 0440 /etc/sudoers.d/pihole
    printf "%b  %b %s\\n" "${OVER}" "${TICK}" "${str}"
}

# Installs a cron file
installCron() {
    # Install the cron job
    local str="Installing latest Cron script"
    printf "\\n  %b %s..." "${INFO}" "${str}"
    # Copy the cron file over from the local repo
    # File must not be world or group writeable and must be owned by root
    install -D -m 644 -o root -g root ${PI_HOLE_LOCAL_REPO}/advanced/Templates/pihole.cron /etc/cron.d/pihole
    # Randomize gravity update time
    sed -i "s/59 1 /$((1 + RANDOM % 58)) $((3 + RANDOM % 2))/" /etc/cron.d/pihole
    # Randomize update checker time
    sed -i "s/59 17/$((1 + RANDOM % 58)) $((12 + RANDOM % 8))/" /etc/cron.d/pihole
    printf "%b  %b %s\\n" "${OVER}" "${TICK}" "${str}"
}

# Gravity is a very important script as it aggregates all of the domains into a single HOSTS formatted list,
# which is what Pi-hole needs to begin blocking ads
runGravity() {
    # Run gravity in the current shell
    { /opt/pihole/gravity.sh --force; }
}

# Check if the pihole user exists and create if it does not
create_pihole_user() {
    local str="Checking for user 'pihole'"
    printf "  %b %s..." "${INFO}" "${str}"
    # If the pihole user exists,
    if id -u pihole &> /dev/null; then
        # and if the pihole group exists,
        if getent group pihole > /dev/null 2>&1; then
            # succeed
            printf "%b  %b %s\\n" "${OVER}" "${TICK}" "${str}"
        else
            local str="Checking for group 'pihole'"
            printf "  %b %s..." "${INFO}" "${str}"
            local str="Creating group 'pihole'"
            # if group can be created
            if addgroup pihole pihole; then
                printf "%b  %b %s\\n" "${OVER}" "${TICK}" "${str}"
                local str="Creating and adding user 'pihole' to group 'pihole'"
                printf "  %b %s..." "${INFO}" "${str}"
            fi
        fi
    else
        # If the pihole user doesn't exist,
        printf "%b  %b %s" "${OVER}" "${CROSS}" "${str}"
        local str="Creating user 'pihole'"
        printf "%b  %b %s..." "${OVER}" "${INFO}" "${str}"
        # create her with the useradd command,
        if getent group pihole > /dev/null 2>&1; then
            addgroup -S pihole
            adduser -S -s /usr/sbin/nologin pihole
            addgroup pihole pihole
        else
            addgroup -S pihole
            adduser -S -s /usr/sbin/nologin pihole
            addgroup pihole pihole
            printf "%b  %b %s\\n" "${OVER}" "${CROSS}" "${str}"
        fi
    fi
}

# This function saves any changes to the setup variables into the setupvars.conf file for future runs
finalExports() {
    # set or update the variables in the file

    addOrEditKeyValPair "${setupVars}" "PIHOLE_INTERFACE" "${PIHOLE_INTERFACE}"
    addOrEditKeyValPair "${setupVars}" "PIHOLE_DNS_1" "${PIHOLE_DNS_1}"
    addOrEditKeyValPair "${setupVars}" "PIHOLE_DNS_2" "${PIHOLE_DNS_2}"
    addOrEditKeyValPair "${setupVars}" "QUERY_LOGGING" "${QUERY_LOGGING}"
    addOrEditKeyValPair "${setupVars}" "INSTALL_WEB_SERVER" "${INSTALL_WEB_SERVER}"
    addOrEditKeyValPair "${setupVars}" "INSTALL_WEB_INTERFACE" "${INSTALL_WEB_INTERFACE}"
    addOrEditKeyValPair "${setupVars}" "LIGHTTPD_ENABLED" "${LIGHTTPD_ENABLED}"
    addOrEditKeyValPair "${setupVars}" "CACHE_SIZE" "${CACHE_SIZE}"
    addOrEditKeyValPair "${setupVars}" "DNS_FQDN_REQUIRED" "${DNS_FQDN_REQUIRED:-true}"
    addOrEditKeyValPair "${setupVars}" "DNS_BOGUS_PRIV" "${DNS_BOGUS_PRIV:-true}"
    addOrEditKeyValPair "${setupVars}" "DNSMASQ_LISTENING" "${DNSMASQ_LISTENING:-local}"

    chmod 644 "${setupVars}"

    # Set the privacy level
    addOrEditKeyValPair "${FTL_CONFIG_FILE}" "PRIVACYLEVEL" "${PRIVACY_LEVEL}"

    # Bring in the current settings and the functions to manipulate them
    source "${setupVars}"
    # shellcheck source=advanced/Scripts/webpage.sh
    source "${PI_HOLE_LOCAL_REPO}/advanced/Scripts/webpage.sh"

    # Look for DNS server settings which would have to be reapplied
    ProcessDNSSettings

    # Look for DHCP server settings which would have to be reapplied
    ProcessDHCPSettings
}

# Install the logrotate script
installLogrotate() {
    local str="Installing latest logrotate script"
    local target=/etc/pihole/logrotate

    printf "\\n  %b %s..." "${INFO}" "${str}"
    if [[ -f ${target} ]]; then

        # Account for changed logfile paths from /var/log -> /var/log/pihole/ made in core v5.11.
        if  grep -q "/var/log/pihole.log" ${target}  ||  grep -q "/var/log/pihole-FTL.log" ${target}; then
            sed -i 's/\/var\/log\/pihole.log/\/var\/log\/pihole\/pihole.log/g' ${target}
            sed -i 's/\/var\/log\/pihole-FTL.log/\/var\/log\/pihole\/FTL.log/g' ${target}

            printf "\\n\\t%b Old log file paths updated in existing logrotate file. \\n" "${INFO}"
            return 3
        fi

        printf "\\n\\t%b Existing logrotate file found. No changes made.\\n" "${INFO}"
        # Return value isn't that important, using 2 to indicate that it's not a fatal error but
        # the function did not complete.
        return 2
    fi
    # Copy the file over from the local repo
    install -D -m 644 "${PI_HOLE_LOCAL_REPO}"/advanced/Templates/logrotate ${target}
    # Different operating systems have different user / group
    # settings for logrotate that makes it impossible to create
    # a static logrotate file that will work with e.g.
    # Rasbian and Ubuntu at the same time. Hence, we have to
    # customize the logrotate script here in order to reflect
    # the local properties of the /var/log directory
    logusergroup="$(stat -c '%U %G' /var/log)"
    # If there is a usergroup for log rotation,
    if [[ -n "${logusergroup}" ]]; then
        # replace the line in the logrotate script with that usergroup.
        sed -i "s/# su #/su ${logusergroup}/g;" ${target}
    fi
    printf "%b  %b %s\\n" "${OVER}" "${TICK}" "${str}"
}

# Install base files and web interface
installPihole() {
    # If the user wants to install the Web interface,
    if [[ "${INSTALL_WEB_INTERFACE}" == true ]]; then
        if [[ ! -d "${webroot}" ]]; then
            # make the Web directory if necessary
            install -d -m 0755 ${webroot}
        fi

        if [[ "${INSTALL_WEB_SERVER}" == true ]]; then
            # Set the owner and permissions
            chown ${LIGHTTPD_USER}:${LIGHTTPD_GROUP} ${webroot}
            chmod 0775 ${webroot}
            # Repair permissions if webroot is not world readable
            chmod a+rx /var/www
            chmod a+rx ${webroot}
            # Give lighttpd access to the pihole group so the web interface can
            # manage the gravity.db database
            addgroup ${LIGHTTPD_USER} pihole || true
            # If the lighttpd command is executable,
            if is_command lighty-enable-mod ; then
                # enable fastcgi and fastcgi-php
                lighty-enable-mod fastcgi fastcgi-php > /dev/null || true
            else
                # Otherwise, show info about installing them
                printf "  %b Warning: 'lighty-enable-mod' utility not found\\n" "${INFO}"
                printf "      Please ensure fastcgi is enabled if you experience issues\\n"
            fi
        fi
    fi
    # Install base files and web interface
    if ! installScripts; then
        printf "  %b Failure in dependent script copy function.\\n" "${CROSS}"
        exit 1
    fi

    # /opt/pihole/utils.sh should be installed by installScripts now, so we can use it
    if [ -f "${PI_HOLE_INSTALL_DIR}/utils.sh" ]; then
        # shellcheck disable=SC1091
        source "${PI_HOLE_INSTALL_DIR}/utils.sh"
    else
        printf "  %b Failure: /opt/pihole/utils.sh does not exist .\\n" "${CROSS}"
        exit 1
    fi

    # Install config files
    if ! installConfigs; then
        printf "  %b Failure in dependent config copy function.\\n" "${CROSS}"
        exit 1
    fi
    # If the user wants to install the dashboard,
    if [[ "${INSTALL_WEB_INTERFACE}" == true ]]; then
        # do so
        installPiholeWeb
    fi
    # Install the cron file
    installCron

    # Install the logrotate file
    installLogrotate || true

    # Check if dnsmasq is present. If so, disable it and back up any possible
    # config file
    disable_dnsmasq

    # install a man page entry for pihole
    install_manpage

    # Update setupvars.conf with any variables that may or may not have been changed during the install
    finalExports
}

# Installation complete message with instructions for the user
displayFinalMessage() {
    # If the number of arguments is > 0,
    if [[ "${#1}" -gt 0 ]] ; then
        # set the password to the first argument.
        pwstring="$1"
    elif [[ $(grep 'WEBPASSWORD' -c "${setupVars}") -gt 0 ]]; then
        # Else if the password exists from previous setup, we'll load it later
        pwstring="unchanged"
    else
        # Else, inform the user that there is no set password.
        pwstring="NOT SET"
    fi
    # If the user wants to install the dashboard,
    if [[ "${INSTALL_WEB_INTERFACE}" == true ]]; then
        # Store a message in a variable and display it
        additional="View the web interface at http://pi.hole/admin or http://${IPV4_ADDRESS%/*}/admin\\n\\nYour Admin Webpage login password is ${pwstring}"
    fi

    # Final completion message to user
    dialog --no-shadow --keep-tite \
        --title "Installation Complete!" \
        --msgbox "Configure your devices to use the Pi-hole as their DNS server using:\
\\n\\nIPv4:	${IPV4_ADDRESS%/*}\
\\nIPv6:	${IPV6_ADDRESS:-"Not Configured"}\
\\nIf you have not done so already, the above IP should be set to static.\
\\n${additional}" "${r}" "${c}"
}

update_dialogs() {
    # If pihole -r "reconfigure" option was selected,
    if [[ "${reconfigure}" = true ]]; then
        # set some variables that will be used
        opt1a="Repair"
        opt1b="This will retain existing settings"
        strAdd="You will remain on the same version"
    else
        # Otherwise, set some variables with different values
        opt1a="Update"
        opt1b="This will retain existing settings."
        strAdd="You will be updated to the latest version."
    fi
    opt2a="Reconfigure"
    opt2b="Resets Pi-hole and allows re-selecting settings."

    # Display the information to the user
    UpdateCmd=$(dialog --no-shadow --keep-tite --output-fd 1 \
                --cancel-label Exit \
                --title "Existing Install Detected!" \
                --menu "\\n\\nWe have detected an existing install.\
\\n\\nPlease choose from the following options:\
\\n($strAdd)"\
                    "${r}" "${c}" 2 \
    "${opt1a}"  "${opt1b}" \
    "${opt2a}"  "${opt2b}") || result=$?

    case ${result} in
        "${DIALOG_CANCEL}" | "${DIALOG_ESC}")
            printf "  %b Cancel was selected, exiting installer%b\\n" "${COL_LIGHT_RED}" "${COL_NC}"
            exit 1
            ;;
    esac

    # Set the variable based on if the user chooses
    case ${UpdateCmd} in
        # repair, or
        "${opt1a}")
            printf "  %b %s option selected\\n" "${INFO}" "${opt1a}"
            useUpdateVars=true
            ;;
        # reconfigure,
        "${opt2a}")
            printf "  %b %s option selected\\n" "${INFO}" "${opt2a}"
            useUpdateVars=false
            ;;
    esac
}

check_download_exists() {
    status=$(curl --head --silent "https://ftl.pi-hole.net/${1}" | head -n 1)
    if grep -q "404" <<< "$status"; then
        return 1
    else
        return 0
    fi
}

fully_fetch_repo() {
    # Add upstream branches to shallow clone
    local directory="${1}"

    cd "${directory}" || return 1
    if is_repo "${directory}"; then
        git remote set-branches origin '*' || return 1
        git fetch --quiet || return 1
    else
        return 1
    fi
    return 0
}

get_available_branches() {
    # Return available branches
    local directory
    directory="${1}"
    local output

    cd "${directory}" || return 1
    # Get reachable remote branches, but store STDERR as STDOUT variable
    output=$( { git ls-remote --heads --quiet | cut -d'/' -f3- -; } 2>&1 )
    # echo status for calling function to capture
    echo "$output"
    return
}

fetch_checkout_pull_branch() {
    # Check out specified branch
    local directory
    directory="${1}"
    local branch
    branch="${2}"

    # Set the reference for the requested branch, fetch, check it put and pull it
    cd "${directory}" || return 1
    git remote set-branches origin "${branch}" || return 1
    git stash --all --quiet &> /dev/null || true
    git clean --quiet --force -d || true
    git fetch --quiet || return 1
    checkout_pull_branch "${directory}" "${branch}" || return 1
}

checkout_pull_branch() {
    # Check out specified branch
    local directory
    directory="${1}"
    local branch
    branch="${2}"
    local oldbranch

    cd "${directory}" || return 1

    oldbranch="$(git symbolic-ref HEAD)"

    str="Switching to branch: '${branch}' from '${oldbranch}'"
    printf "  %b %s" "${INFO}" "$str"
    git checkout "${branch}" --quiet || return 1
    printf "%b  %b %s\\n" "${OVER}" "${TICK}" "$str"
    # Data in the repositories is public anyway so we can make it readable by everyone (+r to keep executable permission if already set by git)
    chmod -R a+rX "${directory}"

    git_pull=$(git pull --no-rebase || return 1)

    printf "  %b %s\\n" "${INFO}" "${git_pull}"

    return 0
}

clone_or_update_repos() {
    # If the user wants to reconfigure,
    if [[ "${reconfigure}" == true ]]; then
        printf "  %b Performing reconfiguration, skipping download of local repos\\n" "${INFO}"
        # Reset the Core repo
        resetRepo ${PI_HOLE_LOCAL_REPO} || \
        { printf "  %b Unable to reset %s, exiting installer%b\\n" "${COL_LIGHT_RED}" "${PI_HOLE_LOCAL_REPO}" "${COL_NC}"; \
        exit 1; \
        }
        # If the Web interface was installed,
        if [[ "${INSTALL_WEB_INTERFACE}" == true ]]; then
            # reset it's repo
            resetRepo ${webInterfaceDir} || \
            { printf "  %b Unable to reset %s, exiting installer%b\\n" "${COL_LIGHT_RED}" "${webInterfaceDir}" "${COL_NC}"; \
            exit 1; \
            }
        fi
    # Otherwise, a repair is happening
    else
        # so get git files for Core
        if ldd /bin/ls | grep -q "ld-musl-i386"; then
            getGitFiles ${PI_HOLE_LOCAL_REPO} ${piholeGitUrl} || \
            { printf "  %b Unable to clone %s into %s, unable to continue%b\\n" "${COL_LIGHT_RED}" "${piholeGitUrl}" "${PI_HOLE_LOCAL_REPO}" "${COL_NC}"; \
            exit 1; \
            }
        else
            getGitFiles ${PI_HOLE_LOCAL_REPO} ${piholeGitUrl} || \
            { printf "  %b Unable to clone %s into %s, unable to continue%b\\n" "${COL_LIGHT_RED}" "${piholeGitUrl}" "${PI_HOLE_LOCAL_REPO}" "${COL_NC}"; \
            exit 1; \
            }
        fi
        # If the Web interface was installed,
        if [[ "${INSTALL_WEB_INTERFACE}" == true ]]; then
            # get the Web git files
            getGitFiles ${webInterfaceDir} ${webInterfaceGitUrl} || \
            { printf "  %b Unable to clone %s into ${webInterfaceDir}, exiting installer%b\\n" "${COL_LIGHT_RED}" "${webInterfaceGitUrl}" "${COL_NC}"; \
            exit 1; \
            }
        fi
    fi
}

# Download FTL binary to random temp directory and install FTL binary
# Disable directive for SC2120 a value _can_ be passed to this function, but it is passed from an external script that sources this one
# shellcheck disable=SC2120
FTLinstall() {
    # Local, named variables
    local str="Downloading and Installing FTL"
    printf "  %b %s..." "${INFO}" "${str}"
    install -m 0640 "${PI_HOLE_LOCAL_REPO}/advanced/pihole-FTL.sha256" "${PI_HOLE_CONFIG_DIR}/pihole-FTL.sha256"

    if [ "${USER_DOWNLOAD_BINARIES}" -eq 0 ]; then

        compile_ftl
        # Before stopping FTL, we download the macvendor database
        curl -ssl "https://ftl.pi-hole.net/macvendor.db" -o "${PI_HOLE_CONFIG_DIR}/macvendor.db" || true
        chmod 644 "${PI_HOLE_CONFIG_DIR}/macvendor.db"
        chown pihole:pihole "${PI_HOLE_CONFIG_DIR}/macvendor.db"

        # Always replace pihole-FTL.service
        install -m 0755 "${PI_HOLE_LOCAL_REPO}/advanced/Templates/pihole-FTL.service" "/etc/init.d/pihole-FTL"

        # Stop pihole-FTL service if available
        stop_service pihole-FTL &> /dev/null
        # Installed the FTL service
        printf "%b  %b %s\\n" "${OVER}" "${TICK}" "${str}"

        return 0
    else
        # Add a temporary entry to resolv.conf
        echo "1.1.1.1" >> "/etc/resolv.conf"

        # Move into the temp ftl directory
        pushd "$(mktemp -d)" > /dev/null || { printf "Unable to make temporary directory for FTL binary download\\n"; return 1; }

        # Before stopping FTL, we download the macvendor database
        curl -sSL "https://ftl.pi-hole.net/macvendor.db" -o "${PI_HOLE_CONFIG_DIR}/macvendor.db" || true
        chmod 644 "${PI_HOLE_CONFIG_DIR}/macvendor.db"
        chown pihole:pihole "${PI_HOLE_CONFIG_DIR}/macvendor.db"

        # Stop pihole-FTL service if available
        stop_service pihole-FTL &> /dev/null

        # Install the new version with the correct permissions
	curl -sSL "$(get_download_url)" > pihole-FTL
        install -m 0755 pihole-FTL /usr/bin/pihole-FTL

        # Move back into the original directory the user was in
        popd > /dev/null || { printf "Unable to return to original directory after FTL binary download.\\n"; return 1; }

        # Installed the FTL service
        printf "%b  %b %s\\n" "${OVER}" "${TICK}" "${str}"

	# Remove the line we added in
	sed -i '$d' "/etc/resolv.conf"

        return 0
    fi
}

disable_dnsmasq() {
    # dnsmasq can now be stopped and disabled if it exists
    if is_command dnsmasq; then
        if check_service_active "dnsmasq";then
            printf "  %b FTL can now resolve DNS Queries without dnsmasq running separately\\n" "${INFO}"
            stop_service dnsmasq
            disable_service dnsmasq
        fi
    fi

    # Backup existing /etc/dnsmasq.conf if present and ensure that
    # /etc/dnsmasq.conf contains only "conf-dir=/etc/dnsmasq.d"
    local conffile="/etc/dnsmasq.conf"
    if [[ -f "${conffile}" ]]; then
        printf "  %b Backing up %s to %s.old\\n" "${INFO}" "${conffile}" "${conffile}"
        mv "${conffile}" "${conffile}.old"
    fi
    # Create /etc/dnsmasq.conf
    echo "conf-dir=/etc/dnsmasq.d" > "${conffile}"
    chmod 644 "${conffile}"
}

get_binary_name() {
    # This gives the machine architecture which may be different from the OS architecture...
    local machine
    machine=$(uname -m)

    local l_binary

    local str="Detecting processor"
    printf "  %b %s..." "${INFO}" "${str}"
    # If the machine is arm or aarch
    if [[ "${machine}" == "arm"* || "${machine}" == *"aarch"* ]]; then
        # ARM
        local rev
        rev=$(uname -m | sed "s/[^0-9]//g;")
        local lib
        lib=$(ldd "$(which sh)" | grep -E '^\s*/lib' | awk '{ print $1 }')
        if [[ "${lib}" == "/lib/ld-linux-aarch64.so.1" ]]; then
            printf "%b  %b Detected AArch64 (64 Bit ARM) processor\\n" "${OVER}" "${TICK}"
            # set the binary to be used
            l_binary="pihole-FTL-aarch64-linux-gnu"
        elif [[ "${lib}" == "/lib/ld-linux-armhf.so.3" ]]; then
            # Hard-float available: Use gnueabihf binaries
            # If ARMv8 or higher is found (e.g., BCM2837 as found in Raspberry Pi Model 3B)
            if [[ "${rev}" -gt 7 ]]; then
                printf "%b  %b Detected ARMv8 (or newer) processor\\n" "${OVER}" "${TICK}"
                # set the binary to be used
                l_binary="pihole-FTL-armv8-linux-gnueabihf"
            elif [[ "${rev}" -eq 7 ]]; then
                # Otherwise, if ARMv7 is found (e.g., BCM2836 as found in Raspberry Pi Model 2)
                printf "%b  %b Detected ARMv7 processor (with hard-float support)\\n" "${OVER}" "${TICK}"
                # set the binary to be used
                l_binary="pihole-FTL-armv7-linux-gnueabihf"
            else
                # Otherwise, use the ARMv6 binary (e.g., BCM2835 as found in Raspberry Pi Zero and Model 1)
                printf "%b  %b Detected ARMv6 processor (with hard-float support)\\n" "${OVER}" "${TICK}"
                # set the binary to be used
                l_binary="pihole-FTL-armv6-linux-gnueabihf"
            fi
        else
            # No hard-float support found: Use gnueabi binaries
            # Use the ARMv4-compliant binary only if we detected an ARMv4T core
            if [[ "${rev}" -eq 4 ]]; then
                printf "%b  %b Detected ARMv4 processor\\n" "${OVER}" "${TICK}"
                # set the binary to be used
                l_binary="pihole-FTL-armv4-linux-gnueabi"
            # Otherwise, use the ARMv5 binary. To date (end of 2020), all modern ARM processors
            # are backwards-compatible to the ARMv5
            else
                printf "%b  %b Detected ARMv5 (or newer) processor\\n" "${OVER}" "${TICK}"
                # set the binary to be used
                l_binary="pihole-FTL-armv5-linux-gnueabi"
            fi
        fi
    elif [[ "${machine}" == "x86_64" ]]; then
        # This gives the processor of packages dpkg installs (for example, "i386")
        local dpkgarch
        dpkgarch=$(dpkg --print-processor 2> /dev/null || dpkg --print-architecture 2> /dev/null)

        # Special case: This is a 32 bit OS, installed on a 64 bit machine
        # -> change machine processor to download the 32 bit executable
        # We only check this for Debian-based systems as this has been an issue
        # in the past (see https://github.com/pi-hole/pi-hole/pull/2004)
        if [[ "${dpkgarch}" == "i386" ]]; then
            printf "%b  %b Detected 32bit (i686) processor\\n" "${OVER}" "${TICK}"
            l_binary="pihole-FTL-linux-x86_32"
        elif ldd /bin/ls | grep -q "ld-musl-x86_64"; then
            printf "%b  %b Detected musl-x86_64 architecture\\n" "${OVER}" "${TICK}"
            l_binary="pihole-FTL-musl-linux-x86_64"
        elif ldd /bin/ls | grep -q "ld-musl-i386"; then
            printf "%b %b Detected musl-x86_32 architecture\\n" "${OVER}" "${TICK}"
            l_binary="pihole-compile"
        else
            # 64bit
            printf "%b  %b Detected x86_64 processor\\n" "${OVER}" "${TICK}"
            # set the binary to be used
            l_binary="pihole-FTL-linux-x86_64"
        fi
    else
        # Something else - we try to use 32bit executable and warn the user
        if [[ ! "${machine}" == "i686" ]]; then
            printf "%b  %b %s...\\n" "${OVER}" "${CROSS}" "${str}"
            printf "  %b %bNot able to detect processor (unknown: %s), trying x86 (32bit) executable%b\\n" "${INFO}" "${COL_LIGHT_RED}" "${machine}" "${COL_NC}"
            printf "  %b Contact Pi-hole Support if you experience issues (e.g: FTL not running)\\n" "${INFO}"
        else
            printf "%b  %b Detected 32bit (i686) processor\\n" "${OVER}" "${TICK}"
        fi
        l_binary="pihole-FTL-linux-x86_32"
    fi

    # Returning a string value via echo
    echo ${l_binary}
}

FTLcheckUpdate() {
    #In the next section we check to see if FTL is already installed (in case of pihole -r).
    #If the installed version matches the latest version, then check the installed sha1sum of the binary vs the remote sha1sum. If they do not match, then download
    printf "  %b Checking for existing FTL binary...\\n" "${INFO}"

    local ftlLoc
    ftlLoc=$(command -v pihole-FTL 2>/dev/null)
    if [ -z "$ftlLoc" ]; then
        return 0
    fi

    local binary
    binary="${1}"

    # if dnsmasq exists and is running at this point, force reinstall of FTL Binary
    if is_command dnsmasq; then
        if check_service_active "dnsmasq";then
            return 0
        fi
    fi

    if [ "$USER_DOWNLOAD_BINARIES" -eq 1 ]; then
        local localSha256
        localSha256=$(sha256sum $ftlLoc | cut -d ' ' -f 1)
        if grep -q "$localSha256"  "${PI_HOLE_CONFIG_DIR}/pihole-FTL.sha256"; then
            return 1
        else
            return 0
        fi
    else
        if grep -q "$(pihole-FTL -v)" "${PI_HOLE_CONFIG_DIR}/pihole-FTL.sha256"; then
            return 1
        else
            return 0
        fi
    fi
}

compile_ftl() {
    # Record the current directory
    pushd . > /dev/null
    # Compile phihole-FTL using musl and install pihole under alpine linux

    # Add some basic programs
    apk add git bash curl sudo

    # Clone the repository that allows compiling pihole-FTL
    pihole_ftl_musl="https://gitlab.com/yvelon/pihole-FTL-alpine.git"
    pihole_ftl_musl_dir="pihole-FTL-alpine"

    pushd "$(mktemp -d)" > /dev/null || { printf "Unable to make temporary directory for FTL binary download\\n"; exit; }
    git clone "$pihole_ftl_musl"
    cd "$pihole_ftl_musl_dir"

    # Install abuild to Compile
    apk add abuild

    # Create abuild keys and build pihole-FTL
    abuild-keygen -a -i
    abuild -F -r

    build_package=$(find /root -name "pihole-FTL*" | grep packages)
    apk --allow-untrusted --force-non-repository add "$build_package"
    popd > /dev/null
}

# Detect suitable FTL binary platform
FTLdetect() {
    printf "\\n  %b FTL Checks...\\n\\n" "${INFO}"

    printf "  %b" "${2}"

    if FTLcheckUpdate "${1}"; then
        FTLinstall "${1}" || return 1
    fi
}

make_temporary_log() {
    # Create a random temporary file for the log
    TEMPLOG=$(mktemp /tmp/pihole_temp.XXXXXX)
    # Open handle 3 for templog
    # https://stackoverflow.com/questions/18460186/writing-outputs-to-log-file-and-console
    exec 3>"$TEMPLOG"
    # Delete templog, but allow for addressing via file handle
    # This lets us write to the log without having a temporary file on the drive, which
    # is meant to be a security measure so there is not a lingering file on the drive during the install process
    rm "$TEMPLOG"
}

copy_to_install_log() {
    # Copy the contents of file descriptor 3 into the install log
    # Since we use color codes such as '\e[1;33m', they should be removed
    sed 's/\[[0-9;]\{1,5\}m//g' < /proc/$$/fd/3 > "${installLogLoc}"
    chmod 644 "${installLogLoc}"
}

main() {
    ######## FIRST CHECK ########
    # Must be root to install
    local str="Root user check"
    printf "\\n"

    # If the user's id is zero,
    if [[ "${EUID}" -eq 0 ]]; then
        # they are root and all is good
        printf "  %b %s\\n" "${TICK}" "${str}"
        # Show the Pi-hole logo so people know it's genuine since the logo and name are trademarked
        show_ascii_berry
        make_temporary_log
    else
        # Otherwise, they do not have enough privileges, so let the user know
        printf "  %b %s\\n" "${INFO}" "${str}"
        printf "  %b %bScript called with non-root privileges%b\\n" "${INFO}" "${COL_LIGHT_RED}" "${COL_NC}"
        printf "      The Pi-hole requires elevated privileges to install and run\\n"
        printf "      Please check the installer for any concerns regarding this requirement\\n"
        printf "      Make sure to download this script from a trusted source\\n\\n"
        printf "  %b Sudo utility check" "${INFO}"

        # If the sudo command exists, try rerunning as admin
        if is_command sudo ; then
            printf "%b  %b Sudo utility check\\n" "${OVER}"  "${TICK}"

            # when run via curl piping
            if [[ "$0" == "bash" ]]; then
                # Download the install script and run it with admin rights
                exec curl -sSL https://raw.githubusercontent.com/pi-hole/pi-hole/master/automated%20install/basic-install.sh | sudo bash "$@"
            else
                # when run via calling local bash script
                exec sudo bash "$0" "$@"
            fi

            exit $?
        else
            # Otherwise, tell the user they need to run the script as root, and bail
            printf "%b  %b Sudo utility check\\n" "${OVER}" "${CROSS}"
            printf "  %b Sudo is needed for the Web Interface to run pihole commands\\n\\n" "${INFO}"
            printf "  %b %bPlease re-run this installer as root${COL_NC}\\n" "${INFO}" "${COL_LIGHT_RED}"
            exit 1
        fi
    fi

    # Check that Alpine community repository is enabled.
    # As per https://gitlab.com/yvelon/pi-hole/-/issues/20
    # it is possible that some user have multiple lines with community, some commented out
    # and others uncommented.
    # Fix this by grepping for any line not commented
    # Just in case, remove any spaces to match beginning of the line
    sed 's/\s//g' /etc/apk/repositories | grep "community" | grep -Eq "^http" || \
        (printf "%b  %b Alpine's community repository is disabled.\\n" "${OVER}" "${CROSS}" && \
        printf "  %b Please, enable it by editing /etc/apk/repositories\\n" "${INFO}" && \
        exit 1)

    # Check for supported package managers so that we may install dependencies
    package_manager_detect

    # Notify user of package availability
    notify_package_updates_available

    # Install packages necessary to perform os_check
    printf "  %b Checking for / installing Required dependencies for OS Check...\\n" "${INFO}"
    install_dependent_packages "${OS_CHECK_DEPS[@]}"

    # Check that the installed OS is officially supported - display warning if not
    os_check

    # Install packages used by this installation script
    printf "  %b Checking for / installing Required dependencies for this install script...\\n" "${INFO}"
    install_dependent_packages "${INSTALLER_DEPS[@]}"

    # If the setup variable file exists,
    if [[ -f "${setupVars}" ]]; then
        # if it's running unattended,
        if [[ "${runUnattended}" == true ]]; then
            printf "  %b Performing unattended setup, no dialogs will be displayed\\n" "${INFO}"
            # Use the setup variables
            useUpdateVars=true
            # also disable debconf-apt-progress dialogs
            export DEBIAN_FRONTEND="noninteractive"
        else
            # If running attended, show the available options (repair/reconfigure)
            update_dialogs
        fi
    fi

    if [[ "${useUpdateVars}" == false ]]; then
        # Display welcome dialogs
        welcomeDialogs
        # Create directory for Pi-hole storage
        install -d -m 755 /etc/pihole/
        # Determine available interfaces
        get_available_interfaces
        # Find interfaces and let the user choose one
        chooseInterface
        # find IPv4 and IPv6 information of the device
        collect_v4andv6_information
	# Decide wheter to install unbound
	printf "Install unbound: ${INSTALL_UNBOUND}"
	if (installUnbound); then
		PIHOLE_DNS_1="127.0.0.1#5335"
		INSTALL_UNBOUND=0
	else
		# Decide what upstream DNS Servers to use
		INSTALL_UNBOUND=1
		printf "Decided not to install unbound.\n"
		setDNS
	fi
        # Give the user a choice of blocklists to include in their install. Or not.
        chooseBlocklists
        # Let the user decide if they want the web interface to be installed automatically
        setAdminFlag
        # Let the user decide if they want query logging enabled...
        setLogging
        # Let the user decide the FTL privacy level
        setPrivacyLevel
        # Download or compile binaries
        if ( dialog --title "Download pre-compiled pihole-FTL" --defaultno --yesno "Do you wish to download a pre-compiled version of pihole-FTL? \n Compiling it may take some time. However, only download pre-compiled binaries if you trust this repository." 30 80 ); then
            #YES
            USER_DOWNLOAD_BINARIES=1
        else
            #NO
            USER_DOWNLOAD_BINARIES=0
        fi
    else
        # Setup adlist file if not exists
        installDefaultBlocklists

        # Source ${setupVars} to use predefined user variables in the functions
        source "${setupVars}"

        # Get the privacy level if it exists (default is 0)
        if [[ -f "${FTL_CONFIG_FILE}" ]]; then
            PRIVACY_LEVEL=$(sed -ne 's/PRIVACYLEVEL=\(.*\)/\1/p' "${FTL_CONFIG_FILE}")

            # If no setting was found, default to 0
            PRIVACY_LEVEL="${PRIVACY_LEVEL:-0}"
        fi
    fi
    # Download or update the scripts by updating the appropriate git repos
    clone_or_update_repos

    # Install the Core dependencies
    local dep_install_list=("${PIHOLE_DEPS[@]}")
    if [[ "${INSTALL_WEB_SERVER}" == true ]]; then
        # And, if the setting says so, install the Web admin interface dependencies
        dep_install_list+=("${PIHOLE_WEB_DEPS[@]}")
    fi
    if [[ "${INSTALL_UNBOUND}" == 0 ]]; then
	dep_install_list+=("${UNBOUND_DEPS[@]}")
    fi

    # Install packages used by the actual software
    printf "  %b Checking for / installing Required dependencies for Pi-hole software...\\n" "${INFO}"
    install_dependent_packages "${dep_install_list[@]}"
    unset dep_install_list

    # On some systems, lighttpd is not enabled on first install. We need to enable it here if the user
    # has chosen to install the web interface, else the LIGHTTPD_ENABLED check will fail
    if [[ "${INSTALL_WEB_SERVER}" == true ]]; then
        enable_service lighttpd
    fi
    if [[ "${runUnattended}" == false ]]; then
        if [ "${INSTALL_UNBOUND}" -eq 0 ]; then
                # Copy unbound configuration
                install -m 0640 ${PI_HOLE_LOCAL_REPO}/advanced/Templates/unbound.conf /etc/unbound/unbound.conf
                # Download root.hints
                wget -S https://www.internic.net/domain/named.cache -O /etc/unbound/root.hints
                rc-update add unbound
                rc-service unbound start
        fi
    fi
    # Determine if lighttpd is correctly enabled
    if check_service_active "lighttpd"; then
        LIGHTTPD_ENABLED=true
    else
        LIGHTTPD_ENABLED=false
    fi
    # Create the pihole user
    create_pihole_user

    # Check if FTL is installed - do this early on as FTL is a hard dependency for Pi-hole
    local funcOutput
    funcOutput=$(get_binary_name) #Store output of get_binary_name here
    local binary
    binary="pihole-FTL${funcOutput##*pihole-FTL}" #binary name will be the last line of the output of get_binary_name (it always begins with pihole-FTL)
    local theRest
    theRest="${funcOutput%pihole-FTL*}" # Print the rest of get_binary_name's output to display (cut out from first instance of "pihole-FTL")
    if ! FTLdetect "${binary}" "${theRest}"; then
        printf "  %b FTL Engine not installed\\n" "${CROSS}"
        exit 1
    fi

    # Install and log everything to a file
    installPihole | tee -a /proc/$$/fd/3

    # Copy the temp log file into final log location for storage
    copy_to_install_log

    if [[ "${INSTALL_WEB_INTERFACE}" == true ]]; then
        # Add password to web UI if there is none
        pw=""
        # If no password is set,
        if [[ $(grep 'WEBPASSWORD' -c "${setupVars}") == 0 ]] ; then
            # generate a random password
            pw=$(head /dev/urandom | LC_ALL=C tr -dc A-Za-z0-9 | head -c 8)
            # shellcheck disable=SC1091
            . /opt/pihole/webpage.sh
            echo "WEBPASSWORD=$(HashPassword "${pw}")" >> "${setupVars}"
        fi
    fi

    # If the Web server was installed,
    if [[ "${INSTALL_WEB_SERVER}" == true ]]; then
        if [[ "${LIGHTTPD_ENABLED}" == true ]]; then
            restart_service lighttpd
            enable_service lighttpd
        else
            printf "  %b Lighttpd is disabled, skipping service restart\\n" "${INFO}"
        fi
    fi

    printf "  %b Restarting services...\\n" "${INFO}"
    # Start services
    # When Alpine is running inside a LXC container, the required
    # devfs service is not running.
    # See https://gitlab.com/yvelon/pi-hole/-/issues/2
    # Start it
    rc-update add devfs sysinit
    if ! rc-service devfs status > /dev/null 2>&1; then
        rc-service devfs start
    fi

    # Enable FTL
    # Ensure the service is enabled before trying to start it
    rc-update add pihole-FTL
    rc-service pihole-FTL start

    # If this is an update from a previous Pi-hole installation
    # we need to move any existing `pihole*` logs from `/var/log` to `/var/log/pihole`
    # if /var/log/pihole.log is not a symlink (set during FTL startup) move the files
    # can be removed with Pi-hole v6.0
    # To be sure FTL is not running when we move the files we explicitly stop it here

    stop_service pihole-FTL &> /dev/null

    if [ ! -d /var/log/pihole/ ]; then
        mkdir -m 0755 /var/log/pihole/
    fi

    # Special handling for pihole-FTL.log -> pihole/FTL.log
    if [ -f /var/log/pihole-FTL.log ] && [ ! -L /var/log/pihole-FTL.log ]; then
        # /var/log/pihole-FTL.log      -> /var/log/pihole/FTL.log
        # /var/log/pihole-FTL.log.1    -> /var/log/pihole/FTL.log.1
        # /var/log/pihole-FTL.log.2.gz -> /var/log/pihole/FTL.log.2.gz
        # /var/log/pihole-FTL.log.3.gz -> /var/log/pihole/FTL.log.3.gz
        # /var/log/pihole-FTL.log.4.gz -> /var/log/pihole/FTL.log.4.gz
        # /var/log/pihole-FTL.log.5.gz -> /var/log/pihole/FTL.log.5.gz
        for f in /var/log/pihole-FTL.log*; do mv "$f" "$( sed "s/pihole-/pihole\//" <<< "$f")"; done
    fi

    # Remaining log files
    if [ -f /var/log/pihole.log ] && [ ! -L /var/log/pihole.log ]; then
        mv /var/log/pihole*.* /var/log/pihole/ 2>/dev/null
    fi

    # Download and compile the aggregated block list
    runGravity

    # Force an update of the updatechecker
    /opt/pihole/updatecheck.sh
    /opt/pihole/updatecheck.sh x remote

    if [[ "${useUpdateVars}" == false ]]; then
        displayFinalMessage "${pw}"
    fi

    # If the Web interface was installed,
    if [[ "${INSTALL_WEB_INTERFACE}" == true ]]; then
        # If there is a password,
        if (( ${#pw} > 0 )) ; then
            # display the password
            printf "  %b Web Interface password: %b%s%b\\n" "${INFO}" "${COL_LIGHT_GREEN}" "${pw}" "${COL_NC}"
            printf "  %b This can be changed using 'pihole -a -p'\\n\\n" "${INFO}"
        fi
    fi

    if [[ "${useUpdateVars}" == false ]]; then
        # If the Web interface was installed,
        if [[ "${INSTALL_WEB_INTERFACE}" == true ]]; then
            printf "  %b View the web interface at http://pi.hole/admin or http://%s/admin\\n\\n" "${INFO}" "${IPV4_ADDRESS%/*}"
        fi
        # Explain to the user how to use Pi-hole as their DNS server
        printf "  %b You may now configure your devices to use the Pi-hole as their DNS server\\n" "${INFO}"
        [[ -n "${IPV4_ADDRESS%/*}" ]] && printf "  %b Pi-hole DNS (IPv4): %s\\n" "${INFO}" "${IPV4_ADDRESS%/*}"
        [[ -n "${IPV6_ADDRESS}" ]] && printf "  %b Pi-hole DNS (IPv6): %s\\n" "${INFO}" "${IPV6_ADDRESS}"
        printf "  %b If you have not done so already, the above IP should be set to static.\\n" "${INFO}"
        INSTALL_TYPE="Installation"
    else
        INSTALL_TYPE="Update"
    fi

    # Display where the log file is
    printf "\\n  %b The install log is located at: %s\\n" "${INFO}" "${installLogLoc}"
    printf "  %b %b%s complete! %b\\n" "${TICK}" "${COL_LIGHT_GREEN}" "${INSTALL_TYPE}" "${COL_NC}"

    if [[ "${INSTALL_TYPE}" == "Update" ]]; then
        printf "\\n"
        "${PI_HOLE_BIN_DIR}"/pihole version --current
    fi
}
if [[ "${SKIP_INSTALL}" != true ]] ; then
    main "$@"
fi
