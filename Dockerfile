FROM alpine:edge


RUN cat /etc/apk/repositories
ENV WEBPASSWORD=changeme


RUN cat /etc/apk/repositories


RUN apk --no-cache update && apk upgrade \
        && apk --no-cache add bash git openrc libcap curl shadow libcap busybox-openrc busybox-mdev-openrc busybox-extras-openrc dnsmasq \
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
