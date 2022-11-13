FROM ubuntu:latest as gitdownloader

RUN apt update -y && apt upgrade -y && apt install git -y

RUN git clone https://github.com/pi-hole/docker-pi-hole.git /docker-pihole



ARG PIHOLE_BASE
FROM ubuntu:latest

ENV TZ=Europe/Berlin
ENV WEBPASSWORD=changeme


RUN ln -snf /usr/share/zoneinfo/$TZ /etc/localtime && echo $TZ > /etc/timezone

RUN apt update -y && apt upgrade -y && apt install php curl -y



ARG PIHOLE_DOCKER_TAG
RUN echo "${PIHOLE_DOCKER_TAG}" > /pihole.docker.tag


ENTRYPOINT [ "/s6-init" ]

 # etc and usr are now in /

COPY --from=gitdownloader /docker-pihole/src/s6/debian-root/ /
# file is in /usr/local/bin/service
RUN ls /usr/local/bin
COPY --from=gitdownloader /docker-pihole/src/s6/service /usr/local/bin/service

WORKDIR /usr/local/bin

RUN bash -ex  /usr/local/bin/install.sh 2>&1 && \
    rm -rf /var/cache/apt/archives /var/lib/apt/lists/*

# php config start passes special ENVs into
ARG PHP_ENV_CONFIG
ENV PHP_ENV_CONFIG /etc/lighttpd/conf-enabled/15-fastcgi-php.conf
ARG PHP_ERROR_LOG
ENV PHP_ERROR_LOG /var/log/lighttpd/error-pihole.log

# IPv6 disable flag for networks/devices that do not support it
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

SHELL ["/bin/bash", "-c"]
