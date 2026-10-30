ARG DJM_TAG=stable-11248-2
FROM ghcr.io/jitsi/web:${DJM_TAG}
USER root
COPY branding/ /tmp/branding/
COPY brand.sh /tmp/brand.sh
RUN bash /tmp/brand.sh /usr/share/jitsi-meet /tmp/branding && rm -rf /tmp/branding /tmp/brand.sh
LABEL org.opencontainers.image.title="TalkChief Cowork Meetings web"
USER s6
