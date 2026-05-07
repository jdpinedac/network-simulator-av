FROM ubuntu:26.04

LABEL maintainer="Juan David Pineda-Cárdenas <juan.pineda@pyxis.tech>"
LABEL description="Receiver container: FFplay display para demo de jitter/latencia"

ENV DEBIAN_FRONTEND=noninteractive

RUN apt-get update && apt-get install -y \
    ffmpeg \
    pulseaudio-utils \
    iputils-ping \
    net-tools \
    tcpdump \
    iproute2 \
    iperf3 \
    && rm -rf /var/lib/apt/lists/*

WORKDIR /demo

COPY receive.sh /demo/receive.sh
COPY receive-stats.sh /demo/receive-stats.sh

RUN chmod +x /demo/*.sh

# Puerto UDP de entrada
EXPOSE 5004/udp

CMD ["/bin/bash"]
