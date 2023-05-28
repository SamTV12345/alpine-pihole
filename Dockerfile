FROM alpine:3.18

RUN cat /etc/apk/repositories
ENV WEBPASSWORD=changeme

ENV REV_SERVER true
ENV REV_SERVER_TARGET 10.2.3.1
ENV REV_SERVER_DOMAIN local.domain
ENV REV_SERVER_CIDR 10.2.3.4/24
ENV DNSSEC true
ENV DNS1 127.0.0.1#5335
ENV DNS2 127.0.0.1#5335

RUN cat /etc/apk/repositories

RUN apk --no-cache update && apk upgrade \
        && apk --no-cache add bash git openrc libcap curl shadow libcap busybox-openrc busybox-mdev-openrc busybox-extras-openrc dnsmasq unbound expat \
        && mkdir -p /run/openrc \
        && touch /run/openrc/softlevel

COPY s6/alpine-root /
COPY s6/service /usr/local/bin/service
COPY version/versions /etc/pihole/versions

ENTRYPOINT [ "/s6-init" ]

RUN mkdir -p /etc/pihole
# Maybe temporary fix permanent?
RUN touch /etc/pihole/setupVars.conf
COPY advanced /etc/pihole/advanced
COPY automated_install /etc/pihole/automated_install

RUN bash /etc/pihole/automated_install/docker-setup.sh
RUN curl --output /etc/unbound/root.hints https://www.internic.net/domain/named.cache
RUN cp /etc/unbound/unbound.conf /etc/unbound/unbound.conf.bak
RUN sed '/^server:/a verbosity: 0\nport: 5335\ndo-ip4: yes\ndo-udp: yes\ndo-tcp: yes\ndo-ip6: no\nprefer-ip6: no\nroot-hints: "/etc/unbound/root.hints"\nharden-glue: yes\nharden-dnssec-stripped: yes\nuse-caps-for-id: no\nedns-buffer-size: 1232\nprefetch: yes\nnum-threads: 1\nso-rcvbuf: 1m\nprivate-address: 192.168.0.0/16\nprivate-address: 169.254.0.0/16\nprivate-address: 172.16.0.0/12\nprivate-address: 10.0.0.0/8\nprivate-address: fd00::/8\nprivate-address: fe80::/10' /etc/unbound/unbound.conf.bak >/etc/unbound/unbound.conf

# php config start passes special ENVs into
ARG PHP_ENV_CONFIG
ENV PHP_ENV_CONFIG /etc/lighttpd/conf-enabled/15-fastcgi-php.conf
ARG PHP_ERROR_LOG
ENV PHP_ERROR_LOG /var/log/lighttpd/error-pihole.log
ENV IPv6 True

EXPOSE 53 53/udp
EXPOSE 67/udp
EXPOSE 80

ENV S6_KEEP_ENV 1
ENV S6_BEHAVIOUR_IF_STAGE2_FAILS 2
ENV S6_CMD_WAIT_FOR_SERVICES_MAXTIME 0

ENV FTLCONF_LOCAL_IPV4 0.0.0.0
ENV FTL_CMD no-daemon
ENV DNSMASQ_USER pihole

ENV PATH /opt/pihole:${PATH}
HEALTHCHECK CMD dig +short +norecurse +retry=0 @127.0.0.1 pi.hole || exit 1
