# parameters
ARG REPO_NAME="device-dashboard"
ARG MAINTAINER="Andrea F. Daniele (afdaniele@ttic.edu)"

# ==================================================>
# ==> Do not change this code
ARG ARCH=arm32v7
ARG COMPOSE_VERSION=v1.0.1
ARG BASE_IMAGE=compose
ARG BASE_TAG=${COMPOSE_VERSION}-${ARCH}

# extend dt-commons
ARG SUPER_IMAGE=dt-commons
ARG MAJOR=daffy
ARG SUPER_IMAGE_TAG=${MAJOR}-${ARCH}
FROM duckietown/${SUPER_IMAGE}:${SUPER_IMAGE_TAG} as dt-commons

# define base image
FROM afdaniele/${BASE_IMAGE}:${BASE_TAG}

# copy stuff from the super image
COPY --from=dt-commons /environment.sh /environment.sh
COPY --from=dt-commons /usr/local/bin/dt-* /usr/local/bin/
COPY --from=dt-commons /code/dt-commons /code/dt-commons

# copy dependencies files only
COPY ./dependencies-apt.txt /tmp/

# install apt dependencies
RUN apt-get update \
  && apt-get install -y --no-install-recommends \
    $(awk -F: '/^[^#]/ { print $1 }' /tmp/dependencies-apt.txt | uniq) \
  && rm -rf /var/lib/apt/lists/*

# copy dependencies files only
COPY ./dependencies-py3.txt /tmp/

# install python dependencies
RUN pip3 install -r /tmp/dependencies-py3.txt

# copy dependencies files only
COPY ./dependencies-compose.txt /tmp/

# switch to simple user
USER www-data

# install compose dependencies
RUN python3 ${COMPOSE_DIR}/public_html/system/lib/python/compose/package_manager.py \
  --install $(awk -F: '/^[^#]/ { print $1 }' /tmp/dependencies-compose.txt | uniq)

# switch back to root
USER root

# copy launch script
COPY ./launch.sh /launch.sh

# define launch script
ENV LAUNCHFILE "/launch.sh"

# redefine entrypoint
ENTRYPOINT ["/bin/bash", "-c", "${LAUNCHFILE}"]

# store module name
ARG REPO_NAME
LABEL org.duckietown.label.module.type="${REPO_NAME}"
ENV DT_MODULE_TYPE "${REPO_NAME}"

# store module metadata
ARG ARCH
ARG COMPOSE_VERSION
ARG BASE_IMAGE
ARG BASE_TAG
ARG MAINTAINER
LABEL org.duckietown.label.architecture="${ARCH}" \
    org.duckietown.label.code.location="/var/www/html/" \
    org.duckietown.label.base.major="${COMPOSE_VERSION}" \
    org.duckietown.label.base.image="${BASE_IMAGE}" \
    org.duckietown.label.base.tag="${BASE_TAG}" \
    org.duckietown.label.maintainer="${MAINTAINER}"
# <== Do not change this code
# <==================================================

# switch to simple user
USER www-data

# configure \compose\
RUN compose configuration/set --package core \
    guest_default_page=robot \
    user_default_page=profile \
    supervisor_default_page=profile \
    administrator_default_page=profile \
    login_enabled=1 \
    cache_enabled=1 \
    theme=core:modern

# configure theme
RUN compose theme/set \
    colors/primary/background=#2c5686 \
    colors/primary/foreground=#bceaff \
    colors/secondary/background=#ffc611 \
    colors/secondary/foreground=#1e1e1e \
    colors/tertiary=#646464

# disable unused pages
RUN compose page/disable --package duckietown --page duckietown
RUN compose page/disable --package duckietown --page cloud_storage
RUN compose page/disable --package duckietown --page diagnostics
RUN compose page/disable --package data --page data-viewer

# configure HTTP
ENV HTTP_PORT 8080

# switch back to root
USER root