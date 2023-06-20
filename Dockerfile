# parameters
ARG REPO_NAME="dt-device-dashboard"
ARG DESCRIPTION="Provides the on-board Dashboard for Duckietown robots"
ARG MAINTAINER="Andrea F. Daniele (afdaniele@duckietown.com)"
# pick an icon from: https://fontawesome.com/v4.7.0/icons/
ARG ICON="dashboard"

# ==================================================>
# ==> Do not change this code
ARG ARCH
ARG COMPOSE_VERSION=v1.2.0
ARG BASE_IMAGE=compose
ARG BASE_TAG=${COMPOSE_VERSION}-${ARCH}
ARG LAUNCHER=default

# extend dt-commons
ARG SUPER_IMAGE=dt-commons
ARG DISTRO=daffy
ARG SUPER_IMAGE_TAG=${DISTRO}-${ARCH}
ARG DOCKER_REGISTRY=docker.io
FROM ${DOCKER_REGISTRY}/duckietown/${SUPER_IMAGE}:${SUPER_IMAGE_TAG} as dt-commons

# define base image
FROM afdaniele/${BASE_IMAGE}:${BASE_TAG}

# move compose entrypoint
RUN cp /entrypoint.sh /compose-entrypoint.sh

# copy stuff from the super image
COPY --from=dt-commons /entrypoint.sh /entrypoint.sh
COPY --from=dt-commons /environment.sh /environment.sh
COPY --from=dt-commons /usr/local/bin/dt-* /usr/local/bin/
COPY --from=dt-commons /code/dt-commons /code/dt-commons

# recall all arguments
ARG ARCH
ARG DISTRO
ARG REPO_NAME
ARG DESCRIPTION
ARG MAINTAINER
ARG ICON
ARG BASE_TAG
ARG BASE_IMAGE
ARG LAUNCHER

# check build arguments
RUN dt-build-env-check "${REPO_NAME}" "${MAINTAINER}" "${DESCRIPTION}"

# code environment
ENV SOURCE_DIR=/code \
    LAUNCH_DIR=/launch

# define/create repository path
ARG REPO_PATH="${SOURCE_DIR}/${REPO_NAME}"
ARG LAUNCH_PATH="${LAUNCH_DIR}/${REPO_NAME}"
RUN mkdir -p "${REPO_PATH}" "${LAUNCH_PATH}"

# keep some arguments as environment variables
ENV DT_MODULE_TYPE="${REPO_NAME}" \
    DT_MODULE_DESCRIPTION="${DESCRIPTION}" \
    DT_MODULE_ICON="${ICON}" \
    DT_MAINTAINER="${MAINTAINER}" \
    DT_REPO_PATH="${REPO_PATH}" \
    DT_LAUNCH_PATH="${LAUNCH_PATH}" \
    DT_LAUNCHER="${LAUNCHER}"

# duckie user
ENV DT_USER_NAME="duckie" \
    DT_USER_UID=2222 \
    DT_GROUP_NAME="duckie" \
    DT_GROUP_GID=2222

# configure HTTP port
ENV HTTP_PORT 8080

# install apt dependencies
COPY ./dependencies-apt.txt "${REPO_PATH}/"
RUN dt-apt-install ${REPO_PATH}/dependencies-apt.txt

# install python3 dependencies
ARG PIP_INDEX_URL="https://pypi.org/simple/"
ENV PIP_INDEX_URL=${PIP_INDEX_URL}
COPY ./dependencies-py3.* "${REPO_PATH}/"
RUN dt-pip3-install "${REPO_PATH}/dependencies-py3.*"

# copy dependencies files only
COPY ./dependencies-compose.txt "${REPO_PATH}/"

# switch to simple user
USER www-data

# install compose dependencies
RUN python3 ${COMPOSE_DIR}/public_html/system/lib/python/compose/package_manager.py \
  --install $(awk -F: '/^[^#]/ { print $1 }' ${REPO_PATH}/dependencies-compose.txt | uniq)

# switch back to root
USER root

# install launcher scripts
COPY ./launchers/. "${LAUNCH_PATH}/"
RUN dt-install-launchers "${LAUNCH_PATH}"

# reset the entrypoint
ENTRYPOINT ["/entrypoint.sh"]

# define default command
CMD ["bash", "-c", "dt-launcher-${DT_LAUNCHER}"]

# store module metadata
LABEL org.duckietown.label.module.type="${REPO_NAME}" \
    org.duckietown.label.module.description="${DESCRIPTION}" \
    org.duckietown.label.module.icon="${ICON}" \
    org.duckietown.label.architecture="${ARCH}" \
    org.duckietown.label.code.location="/var/www/html" \
    org.duckietown.label.code.version.distro="${DISTRO}" \
    org.duckietown.label.base.image="${BASE_IMAGE}" \
    org.duckietown.label.base.tag="${BASE_TAG}" \
    org.duckietown.label.maintainer="${MAINTAINER}"
# <== Do not change this code
# <==================================================

# create health file
RUN echo ND > /health &&  \
    chmod 777 /health
