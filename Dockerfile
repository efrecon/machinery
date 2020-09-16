#####
# To run this, you will have to mount the local docker socket and your working directory onto /cluster, e.g.
# docker run -it --rm -v /var/run/docker.sock:/var/run/docker.sock -v `pwd`:/cluster efrecon/machinery help
FROM docker:stable

# Lock in versions of compose and machine, will change at the pace of stable
# releases.
ARG DOCKER_COMPOSE_VERSION=1.27.2
ARG DOCKER_MACHINE_VERSION=0.16.2
ARG TCLLIB_VERSION=1-20

# Install glibc so compose can run. Also make sure wget can properly handle
# https and arrange for an ssh client to be present for use from docker-machine
ARG GLIBC=2.32-r0
ARG GLIBC_SHA256=2a3cd1111d2b42563e90a1ace54c3e000adf3a5a422880e7baf628c671b430c5
RUN apk update && apk add --no-cache openssh-client ca-certificates && \
    wget -q -O /etc/apk/keys/sgerrand.rsa.pub https://alpine-pkgs.sgerrand.com/sgerrand.rsa.pub && \
    wget -q https://github.com/sgerrand/alpine-pkg-glibc/releases/download/${GLIBC}/glibc-${GLIBC}.apk && \
    echo "${GLIBC_SHA256}  glibc-${GLIBC}.apk" | sha256sum -c - && \
    apk add --no-cache glibc-${GLIBC}.apk && rm glibc-${GLIBC}.apk && \
    ln -s /lib/libz.so.1 /usr/glibc-compat/lib/ && \
    ln -s /lib/libc.musl-x86_64.so.1 /usr/glibc-compat/lib

# Install compose and machine
RUN wget -q -O /usr/local/bin/docker-compose https://github.com/docker/compose/releases/download/$DOCKER_COMPOSE_VERSION/docker-compose-Linux-x86_64 && \
    chmod +x /usr/local/bin/docker-compose && \
    wget -q -O /usr/local/bin/docker-machine https://github.com/docker/machine/releases/download/v$DOCKER_MACHINE_VERSION/docker-machine-Linux-x86_64 && \
    chmod +x /usr/local/bin/docker-machine

# Install TCL, TLS, tcllib and other tcl/machinery dependencies
RUN apk add --no-cache tcl tcl-tls tclx archivemount && \
    wget -q -O /tmp/tcllib-${TCLLIB_VERSION}.tar.gz https://github.com/tcltk/tcllib/archive/tcllib-${TCLLIB_VERSION}.tar.gz && \
    tar -zx -C /tmp -f /tmp/tcllib-${TCLLIB_VERSION}.tar.gz && \
    tclsh /tmp/tcllib-tcllib-${TCLLIB_VERSION}/installer.tcl -no-html -no-nroff -no-examples -no-gui -no-apps -no-wait -pkg-path /usr/lib/tcllib$(echo ${TCLLIB_VERSION}|sed s/-/./g) && \
    rm -rf /tmp/tcllib*

# Install our main script and implementation
RUN mkdir -p /opt/machinery/lib
COPY machinery /opt/machinery/
COPY lib /opt/machinery/lib
RUN ln -s /opt/machinery/machinery /usr/local/bin/machinery

# Install til library, the only remaining dependency we have
RUN wget -q -O /tmp/til.zip https://github.com/efrecon/til/archive/master.zip && \
    unzip -q /tmp/til.zip -d /opt/machinery/lib && \
    mv /opt/machinery/lib/til-master /opt/machinery/lib/til && \
    rm -rf /tmp/til.zip

# Expose for running as a service
EXPOSE 8070

# Mount your main working directory onto /cluster
RUN mkdir -p /cluster
WORKDIR /cluster
VOLUME /cluster

ENTRYPOINT [ "/usr/local/bin/machinery" ]