FROM ubuntu:22.04

LABEL maintainer="Juan David Pineda-Cárdenas <juan.pineda@pyxis.tech>"
LABEL description="Sender container: FFmpeg streamer con tc netem para simulación de red"

ENV DEBIAN_FRONTEND=noninteractive

RUN apt-get update && apt-get install -y \
    ffmpeg \
    iproute2 \
    iputils-ping \
    net-tools \
    tcpdump \
    fonts-dejavu-core \
    fonts-dejavu-extra \
    bc \
    curl \
    && rm -rf /var/lib/apt/lists/*

WORKDIR /demo

COPY stream.sh /demo/stream.sh
COPY apply-netem.sh /demo/apply-netem.sh

RUN chmod +x /demo/*.sh

# Puerto UDP para el stream de salida
EXPOSE 5004/udp

CMD ["/bin/bash"]
