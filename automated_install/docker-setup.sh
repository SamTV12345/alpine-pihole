#!/usr/bin/env bash

mkdir -p /etc/pihole/
mkdir -p /var/run/pihole


setupVars=/etc/pihole/setupVars.conf

export CORE_LOCAL_REPO=/etc/.pihole
export WEB_LOCAL_REPO=/var/www/html/admin

detect_arch() {
  DETECTED_ARCH=$(apk --print-arch)
  S6_ARCH=$DETECTED_ARCH
  case $DETECTED_ARCH in
  amd64)
    S6_ARCH="x86_64";;
  armel)
    S6_ARCH="armhf";;
  armhf)
    S6_ARCH="armhf";;
  arm64)
    S6_ARCH="aarch64";;
  i386)
    S6_ARCH="i686";;
esac
}

DOCKER_TAG=$(cat /pihole.docker.tag)
# Helps to have some additional tools in the dev image when debugging
if [[ "${DOCKER_TAG}" = 'nightly' ||  "${DOCKER_TAG}" = 'dev' ]]; then
  apt-get update
  apt-get install --no-install-recommends -y nano less
  rm -rf /var/lib/apt/lists/*
fi

detect_arch
S6_OVERLAY_VERSION=v3.1.1.2

echo "https://github.com/just-containers/s6-overlay/releases/download/${S6_OVERLAY_VERSION}/s6-overlay-${S6_ARCH}.tar.xz"
curl -L -s "https://github.com/just-containers/s6-overlay/releases/download/${S6_OVERLAY_VERSION}/s6-overlay-noarch.tar.xz" | tar Jxpf - -C /
curl -L -s "https://github.com/just-containers/s6-overlay/releases/download/${S6_OVERLAY_VERSION}/s6-overlay-${S6_ARCH}.tar.xz" | tar Jxpf - -C /

ls /init
mv /init /s6-init

# Preseed variables to assist with using --unattended install
{
  echo "PIHOLE_INTERFACE=eth0"
  echo "IPV4_ADDRESS=0.0.0.0"
  echo "IPV6_ADDRESS=0:0:0:0:0:0"
  echo "PIHOLE_DNS_1=8.8.8.8"
  echo "QUERY_LOGGING=true"
  echo "INSTALL_WEB_SERVER=true"
  echo "INSTALL_WEB_INTERFACE=true"
  echo "LIGHTTPD_ENABLED=true"
}>> "${setupVars}"
source $setupVars

export USER=pihole

export S6_OVERLAY_VERSION=v3.1.1.2

export PIHOLE_SKIP_OS_CHECK=true

cat </etc/pihole/automated_install/basic-install.sh | bash -sex -- --unattended

# At this stage, if we are building a :nightly tag, then switch the Pi-hole install to dev versions
if [[ "${DOCKER_TAG}" = 'nightly'  ]]; then
  yes | pihole checkout dev
fi

sed -i '/^WEBPASSWORD/d' /etc/pihole/setupVars.conf

# sed a new function into the `pihole` script just above the `helpFunc()` function for later use.
sed -i $'s/helpFunc() {/unsupportedFunc() {\\\n  echo "Function not supported in Docker images"\\\n  exit 0\\\n}\\\n\\\nhelpFunc() {/g' /usr/local/bin/pihole

# Replace a few of the `pihole` options with calls to `unsupportedFunc`:
# pihole -up / pihole updatePihole
sed -i $'s/)\s*updatePiholeFunc/) unsupportedFunc/g' /usr/local/bin/pihole
# pihole uninstall
sed -i $'s/)\s*uninstallFunc/) unsupportedFunc/g' /usr/local/bin/pihole
# pihole -r / pihole reconfigure
sed -i $'s/)\s*reconfigurePiholeFunc/) unsupportedFunc/g' /usr/local/bin/pihole

mv /etc/pihole/macvendor.db /macvendor.db
ln -s /macvendor.db /etc/pihole/macvendor.db

if [ ! -f /.piholeFirstBoot ]; then
  touch /.piholeFirstBoot
fi

cp
ls /etc/lighttpd
echo 'Docker install successful'
