FROM traefik:v2.11

ARG PLUTO_DOMAIN

COPY traefik.yml /etc/traefik/traefik.yml
COPY dynamic.yml.template /etc/traefik/dynamic.yml.template

RUN if [ -z "$PLUTO_DOMAIN" ]; then echo "PLUTO_DOMAIN build arg required" && exit 1; fi \
  && sed "s/__PLUTO_DOMAIN__/${PLUTO_DOMAIN}/g" /etc/traefik/dynamic.yml.template > /etc/traefik/dynamic.yml \
  && rm /etc/traefik/dynamic.yml.template
