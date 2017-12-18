#####
# To run this, you will have to mount the local docker socket and your working directory onto /cluster, e.g.
# docker run -it --rm -v /var/run/docker.sock:/var/run/docker.sock -v `pwd`:/cluster efrecon/machinery help
FROM docker:stable

# Lock in versions of compose and machine, will change at the pace of stable
# releases.
ENV DOCKER_COMPOSE_VERSION 1.17.1
ENV DOCKER_MACHINE_VERSION 0.13.0
ENV TCLLIB_VERSION 1_18

# Install glibc so compose can run (also make sure wget can properly handle https)
ENV GLIBC 2.23-r3
RUN apk update && apk add --no-cache openssl ca-certificates && \
    wget -q -O /etc/apk/keys/sgerrand.rsa.pub https://raw.githubusercontent.com/sgerrand/alpine-pkg-glibc/master/sgerrand.rsa.pub && \
    wget -q https://github.com/sgerrand/alpine-pkg-glibc/releases/download/$GLIBC/glibc-$GLIBC.apk && \
    apk add --no-cache glibc-$GLIBC.apk && rm glibc-$GLIBC.apk && \
    ln -s /lib/libz.so.1 /usr/glibc-compat/lib/ && \
    ln -s /lib/libc.musl-x86_64.so.1 /usr/glibc-compat/lib

# Install compose and machine
RUN wget -q -O /usr/local/bin/docker-compose https://github.com/docker/compose/releases/download/$DOCKER_COMPOSE_VERSION/docker-compose-Linux-x86_64 && \
    chmod +x /usr/local/bin/docker-compose && \
    wget -q -O /usr/local/bin/docker-machine https://github.com/docker/machine/releases/download/v$DOCKER_MACHINE_VERSION/docker-machine-Linux-x86_64 && \
    chmod +x /usr/local/bin/docker-machine

# Install TCL, TLS and the tcllib.
RUN apk add --no-cache tcl tcl-tls && \
    wget -q -O /tmp/tcllib_${TCLLIB_VERSION}.tar.gz https://github.com/tcltk/tcllib/archive/tcllib_${TCLLIB_VERSION}.tar.gz && \
    tar -zx -C /tmp -f /tmp/tcllib_${TCLLIB_VERSION}.tar.gz && \
    tclsh /tmp/tcllib-tcllib_${TCLLIB_VERSION}/installer.tcl -no-html -no-nroff -no-examples -no-gui -no-apps -no-wait -pkg-path /usr/lib/tcllib$(echo ${TCLLIB_VERSION}|sed s/_/./g) && \
    rm -rf /tmp/tcllib*

# Install our main script and implementation
RUN mkdir -p /opt/machinery/lib
COPY machinery /opt/machinery/
COPY lib /opt/machinery/lib
RUN ln -s /opt/machinery/machinery /usr/local/bin/machinery

# Install til library, the only dependency we have
RUN wget -q -O /tmp/til.zip https://github.com/efrecon/til/archive/master.zip && \
    unzip -q /tmp/til.zip -d /opt/machinery/lib && \
    mv /opt/machinery/lib/til-master /opt/machinery/lib/til && \
    rm -rf /tmp/til.zip

# Expose for running as a service
EXPOSE 8080

# Mount your main working directory onto /cluster
RUN mkdir -p /cluster
WORKDIR /cluster
VOLUME /cluster

ENTRYPOINT [ "/usr/local/bin/machinery" ]