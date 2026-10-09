#!/bin/bash

source /environment.sh

# initialize launch file
dt-launchfile-init

# YOUR CODE BELOW THIS LINE
# ----------------------------------------------------------------------------

# constants
HOSTNAME=$(hostname)
DATA_DIR=/data

# make sure the data directory exists
if [ ! -d ${DATA_DIR} ]; then
    echo "WARNING: Data directory '${DATA_DIR}' not found. This was not expected."
    sudo mkdir -p ${DATA_DIR}
    sudo chown ${DT_USER_NAME}:${DT_USER_NAME} ${DATA_DIR}
fi

# get GID of the data dir
GID=$(stat -c %g "${DATA_DIR}")
GNAME=dataers
# check if we have a group with that ID already
if [ ! "$(getent group "${GID}")" ]; then
    echo "Creating a group '${GNAME}' with GID:${GID} for the directory '${DATA_DIR}'"
    # create group
    sudo groupadd --gid ${GID} ${GNAME}
else
    GROUP_STR=$(getent group ${GID})
    readarray -d : -t strarr <<< "$GROUP_STR"
    GNAME="${strarr[0]}"
    echo "A group with GID:${GID} (i.e., ${GNAME}) already exists. Reusing it."
fi

# add user to group
echo "Adding user '${DT_USER_NAME}' to the group '${GNAME}' (GID:${GID})."
sudo usermod -aG ${GNAME} ${DT_USER_NAME}

# configure \compose\
echo "Configuring \\compose\\ ..."
compose configuration/set --package core \
    navbar_title=${HOSTNAME} \
    logo_white=http://${HOSTNAME}.local/d/data/duckietown/images/logo.png \
    logo_black=http://${HOSTNAME}.local/d/data/duckietown/images/logo.png \
    logo_white_small=http://${HOSTNAME}.local/d/data/duckietown/images/logo.png \
    logo_black_small=http://${HOSTNAME}.local/d/data/duckietown/images/logo.png \
    "navbar_subtitle=(${ROBOT_TYPE})" \
    "website_name=${ROBOT_TYPE^} Dashboard"

# configure \compose\
compose configuration/set --package core \
    guest_default_page=robot \
    user_default_page=profile \
    supervisor_default_page=profile \
    administrator_default_page=profile \
    login_enabled=1 \
    cache_enabled=1 \
    check_updates=0 \
    theme=core:modern \
    favicon=duckietown

# the shared duckietown_duckiebot pages resolve the robot name and expand
# `~` topics using these settings, including on forwarded localhost sessions
compose configuration/set --package duckietown_duckiebot \
    duckiebot_name=${HOSTNAME} \
    duckiebot_hostname=${HOSTNAME}.local

# configure theme
compose theme/set \
    colors/primary/background=#2c5686 \
    colors/primary/foreground=#bceaff \
    colors/secondary/background=#ffc611 \
    colors/secondary/foreground=#1e1e1e \
    colors/tertiary=#646464

# disable unused pages
compose page/disable --package core \
    --page api
compose page/disable --package data \
    --page data-viewer
compose page/disable --package vscode \
    --page vscode
compose page/disable --package duckietown_duckiebot \
    --page desktop

# configure 'elfinder' package
compose configuration/set --package elfinder \
    mounts/mount0/driver=LocalFileSystem \
    mounts/mount0/enabled=1 \
    mounts/mount0/alias=data \
    mounts/mount0/path=/data

# fix elfinder dependencies (install secure version and create symlinks)
ELFINDER_PKG_DIR=/user-data/packages/elfinder
ELFINDER_COMPOSER_DIR=${ELFINDER_PKG_DIR}/data/private/composer
ELFINDER_PUBLIC_DIR=${ELFINDER_PKG_DIR}/data/public
ELFINDER_PRIVATE_DIR=${ELFINDER_COMPOSER_DIR}/vendor/studio-42/elfinder

if [ ! -f "${ELFINDER_COMPOSER_DIR}/vendor/autoload.php" ]; then
    echo "Installing elfinder dependencies..."
    mkdir -p "${ELFINDER_COMPOSER_DIR}"
    # Install latest secure version of elfinder (2.1.66 or newer)
    composer require --no-audit -d ${ELFINDER_COMPOSER_DIR} -- studio-42/elfinder:^2.1.66
    
    # Create symbolic links for static assets
    mkdir -p "${ELFINDER_PUBLIC_DIR}"
    for dir in js css img sounds; do
        [ -L "${ELFINDER_PUBLIC_DIR}/${dir}" ] && rm "${ELFINDER_PUBLIC_DIR}/${dir}"
        [ -d "${ELFINDER_PRIVATE_DIR}/${dir}" ] && ln -sf "${ELFINDER_PRIVATE_DIR}/${dir}" "${ELFINDER_PUBLIC_DIR}/${dir}"
    done
    echo "elfinder dependencies installed successfully."
fi

# configure nginx log
if [ "${ACCESS_LOG:-}" != "1" ]; then
    # disable nginx logging to stdout
    sudo sed -i "s/access_log\ \/dev\/stdout\;/access_log\ \/dev\/null\;/g" /etc/nginx/sites-available/default
    # make nginx error log less verbose
    sudo sed -i "s/error_log\ \/dev\/stdout\ info;/error_log\ \/dev\/stdout\ warn;/g" /etc/nginx/sites-available/default
fi

# DTSW-7779: route /api/ros-config (GET/HEAD only) to the duckietown_duckiedrone
# package's runtime ROS config endpoint. Cross-package coupling, but keeps the
# change local to the dashboard image. If more endpoints appear, generalise to
# /api/<package>/<endpoint> upstream in dt-compose-commons.
if ! sudo grep -q 'location = /api/ros-config' /etc/nginx/sites-available/default; then
    sudo sed -i '/^[[:space:]]*location[[:space:]]*\/[[:space:]]*{$/i \
    location = /api/ros-config {\
        limit_except GET HEAD { deny all; }\
        fastcgi_pass unix:/run/php/php7.4-fpm.sock;\
        fastcgi_param SCRIPT_FILENAME /user-data/packages/duckietown_duckiedrone/modules/renderers/endpoints/ros-config.php;\
        fastcgi_param QUERY_STRING $query_string;\
        include fastcgi_params;\
    }\
' /etc/nginx/sites-available/default
    # Verify the block was successfully inserted
    if ! sudo grep -q 'location = /api/ros-config' /etc/nginx/sites-available/default; then
        echo "ERROR: Failed to insert /api/ros-config nginx location block — nginx config pattern may have changed." >&2
        exit 1
    fi
    # Validate the resulting nginx configuration
    sudo nginx -t || exit 1
fi

# Keyboard controller is published only on the docker bridge. Proxy it on the
# dashboard origin and require a logged-in PHP session.
if ! sudo grep -q 'location /keyboard-controller/' /etc/nginx/sites-available/default; then
    KC_UPSTREAM_HOST=$(ip route show default 2>/dev/null | awk '{print $3; exit}')
    KC_UPSTREAM_HOST=${KC_UPSTREAM_HOST:-172.17.0.1}
    sudo sed -i '/^[[:space:]]*location[[:space:]]*\/[[:space:]]*{$/i \
    location = /internal/keyboard-controller-auth {\
        internal;\
        include fastcgi_params;\
        fastcgi_pass unix:/run/php/php7.4-fpm.sock;\
        fastcgi_param SCRIPT_FILENAME /user-data/packages/duckietown_duckiebot/tools/keyboard_controller_auth.php;\
    }\
    location /keyboard-controller/ {\
        auth_request /internal/keyboard-controller-auth;\
        proxy_http_version 1.1;\
        proxy_set_header Host $host;\
        proxy_set_header Upgrade $http_upgrade;\
        proxy_set_header Connection $http_connection;\
        rewrite ^/keyboard-controller/(.*)$ /$1 break;\
        proxy_pass http://'"${KC_UPSTREAM_HOST}"':8090;\
    }\
' /etc/nginx/sites-available/default
    if ! sudo grep -q 'location /keyboard-controller/' /etc/nginx/sites-available/default; then
        echo "ERROR: Failed to insert /keyboard-controller/ nginx location." >&2
        exit 1
    fi
    sudo nginx -t || exit 1
fi

# wpa_supplicant control sockets are root-only unless created with GROUP=netdev.
# PHP runs as ${DT_USER_NAME}, so put that user in the socket group. If the
# sockets are still root:root, retarget them at the usual Duckiebot netdev GID.
WPA_DIR=/var/run/wpa_supplicant
if [ -d "${WPA_DIR}" ]; then
    WPA_GID="$(stat -c %g "${WPA_DIR}/wlan0" 2>/dev/null || stat -c %g "${WPA_DIR}")"
    if [ -z "${WPA_GID}" ] || [ "${WPA_GID}" = "0" ]; then
        WPA_GID=106
        chgrp "${WPA_GID}" "${WPA_DIR}" "${WPA_DIR}"/* 2>/dev/null || true
        chmod 770 "${WPA_DIR}" 2>/dev/null || true
        chmod 770 "${WPA_DIR}"/wlan0 "${WPA_DIR}"/p2p-dev-wlan0 2>/dev/null || true
    fi
    if ! getent group "${WPA_GID}" >/dev/null; then
        groupadd -g "${WPA_GID}" netdev || true
    fi
    WPA_GROUP="$(getent group "${WPA_GID}" | cut -d: -f1)"
    if [ -n "${WPA_GROUP}" ]; then
        usermod -aG "${WPA_GROUP}" "${DT_USER_NAME}" || true
    fi
fi

# make sure all databases belong to ${DT_USER_NAME}
if [ -d /user-data/databases ]; then
    chown -R ${DT_USER_NAME}:${GNAME} /user-data/databases
fi

# ----------------------------------------------------------------------------
# YOUR CODE ABOVE THIS LINE

# run compose entrypoint (https://github.com/duckietown/compose/blob/stable/assets/entrypoint.sh)
dt-exec /compose-entrypoint.sh

# wait for app to end
dt-launchfile-join
