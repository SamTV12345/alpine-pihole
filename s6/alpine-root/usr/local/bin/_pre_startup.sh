#!/bin/bash -e

if [ "${PH_VERBOSE:-0}" -gt 0 ] ; then
    set -x ;
fi

echo "  [i] Starting unbound"
unbound -d &
echo "  [i] Started unbound"

# The below functions are all contained in bash_functions.sh
# shellcheck source=/dev/null
. /usr/local/bin/bash_functions.sh

echo "  [i] Configuring additional parameters"

change_setting "DNSSEC" "true"
change_setting "REV_SERVER" "$REV_SERVER"
change_setting "REV_SERVER_CIDR" "$REV_SERVER_CIDR"
change_setting "REV_SERVER_TARGET" "$REV_SERVER_TARGET"
change_setting "REV_SERVER_DOMAIN" "$REV_SERVER_DOMAIN"
change_setting "PIHOLE_DNS_1" "$DNS1"
change_setting "PIHOLE_DNS_2" "$DNS2"
change_setting "CACHE_SIZE" "15000"
change_setting "DNS_FQDN_REQUIRED" "true"
change_setting "DNS_BOGUS_PRIV" "true"
change_setting "DNSMASQ_LISTENING" "local"
change_setting "USER_DOWNLOAD_BINARIES" "1"

echo "  [i] Configured additional parameters"

echo "  [i] Pre Startup complete"
echo ""
. _startup.sh


