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

NGINX_SITE=/etc/nginx/sites-available/default

# Match both "location /path" and "location ^~ /path".
nginx_has_location() {
    local path="$1"
    local escaped="${path//\//\\/}"
    sudo grep -Eq "location[[:space:]]+(\\^~[[:space:]]+)?${escaped}([[:space:]]|\\{)" "${NGINX_SITE}"
}

insert_before_root_location() {
    local block="$1"
    local tmp
    tmp="$(mktemp)"
    printf '%s\n' "${block}" > "${tmp}"
    sudo python3 - "${NGINX_SITE}" "${tmp}" <<'PY'
import sys
conf_path, block_path = sys.argv[1], sys.argv[2]
with open(conf_path, "r", encoding="utf-8") as fh:
    lines = fh.readlines()
block = open(block_path, "r", encoding="utf-8").read()
if not block.endswith("\n"):
    block += "\n"
out = []
inserted = False
for line in lines:
    stripped = line.strip()
    if not inserted and stripped.startswith("location /") and stripped.endswith("{") and stripped[len("location /"):-1].strip() == "":
        out.append(block)
        inserted = True
    out.append(line)
if not inserted:
    sys.exit(2)
with open(conf_path, "w", encoding="utf-8") as fh:
    fh.writelines(out)
PY
    local status=$?
    rm -f "${tmp}"
    if [ "${status}" -ne 0 ]; then
        echo "ERROR: Failed to insert an nginx location before location /." >&2
        exit 1
    fi
}

# Rosbridge listens on :9001. Browsers that block a cross-port websocket use
# this origin instead. Guests may subscribe; publish and service calls are
# dropped unless the dashboard session is logged in. Autobahn still sees
# Host: 127.0.0.1:9001 on the upstream hop.
ROS_FILTER="${DT_PROJECT_PATH}/assets/rosbridge_guest_filter.py"
ROS_AUTH="${DT_PROJECT_PATH}/assets/rosbridge_auth.php"
if [ ! -f "${ROS_FILTER}" ] || [ ! -f "${ROS_AUTH}" ]; then
    echo "ERROR: rosbridge guest filter assets are missing (${ROS_FILTER})." >&2
    exit 1
fi
python3 "${ROS_FILTER}" &
ros_filter_ready=0
for _ in $(seq 1 50); do
    if (echo >/dev/tcp/127.0.0.1/9002) >/dev/null 2>&1; then
        ros_filter_ready=1
        break
    fi
    sleep 0.1
done
if [ "${ros_filter_ready}" != "1" ]; then
    echo "ERROR: rosbridge guest filter did not start on 127.0.0.1:9002." >&2
    exit 1
fi

if ! nginx_has_location "/rosbridge"; then
    insert_before_root_location "    location = /internal/rosbridge-auth {
        internal;
        include fastcgi_params;
        fastcgi_pass unix:/run/php/php7.4-fpm.sock;
        fastcgi_param SCRIPT_FILENAME ${ROS_AUTH};
    }
    location /rosbridge {
        auth_request /internal/rosbridge-auth;
        auth_request_set \$ros_writer \$upstream_http_x_robot_writer;
        proxy_pass http://127.0.0.1:9002/;
        proxy_http_version 1.1;
        proxy_set_header Host \$host;
        proxy_set_header Upgrade \$http_upgrade;
        proxy_set_header Connection \"upgrade\";
        proxy_set_header X-Robot-Writer \$ros_writer;
        proxy_read_timeout 3600s;
        proxy_send_timeout 3600s;
        proxy_buffering off;
    }"
    if ! nginx_has_location "/rosbridge"; then
        echo "ERROR: Failed to insert /rosbridge nginx location." >&2
        exit 1
    fi
    sudo nginx -t || exit 1
fi

# On :8081 the page origin is the dashboard itself, so /health, /files and /code
# never reach device-proxy. Forward each path on its own. ^~ keeps /files/*.php
# on the file service instead of the dashboard PHP regex.
insert_device_proxy() {
    local path="$1"
    local upstream="$2"
    if nginx_has_location "${path}"; then
        return 0
    fi
    insert_before_root_location "    location ^~ ${path} {
        proxy_pass ${upstream};
        proxy_set_header Host \$host;
        proxy_read_timeout 60s;
    }"
    if ! nginx_has_location "${path}"; then
        echo "ERROR: Failed to insert ${path} nginx location." >&2
        exit 1
    fi
}
insert_device_proxy "/health/" "http://127.0.0.1:8085/"
insert_device_proxy "/files/" "http://127.0.0.1:8082/"
insert_device_proxy "/code/" "http://127.0.0.1:8086/"
insert_device_proxy "/ros/" "http://127.0.0.1:8084/"
sudo nginx -t || exit 1

# Keyboard controller is published only on the docker bridge. Proxy it on the
# dashboard origin and require a logged-in PHP session.
if ! sudo grep -q 'location /keyboard-controller/' /etc/nginx/sites-available/default; then
    # The controller is published on docker0 (see run_keyboard_controller.sh).
    # A host-networked dashboard sees the Wi-Fi router as its default gateway,
    # so that route must not be used as the proxy upstream.
    KC_UPSTREAM_HOST=""
    if ip -4 addr show docker0 >/dev/null 2>&1; then
        KC_UPSTREAM_HOST="$(ip -4 addr show docker0 | awk '/inet /{print $2}' | cut -d/ -f1 | head -1)"
    fi
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
# PHP runs as ${DT_USER_NAME}. Retarget only entries that are still GID 0, and
# join the resulting group. A sibling socket that already has a non-root group
# is left alone. The group name is per GID so an existing netdev group with a
# different id cannot hide a failed groupadd.
WPA_DIR=/var/run/wpa_supplicant
retarget_root_owned() {
    local path="$1"
    if [ ! -e "${path}" ]; then
        return 0
    fi
    if [ "$(stat -c %g "${path}")" != "0" ]; then
        return 0
    fi
    if ! sudo chgrp 106 "${path}"; then
        echo "ERROR: Failed to change ${path} from GID 0 to 106." >&2
        return 1
    fi
    if ! sudo chmod 770 "${path}"; then
        echo "ERROR: Failed to set mode 770 on ${path}." >&2
        return 1
    fi
}
grant_wpa_gid() {
    local gid="$1"
    local group_name=""
    if [ -z "${gid}" ] || [ "${gid}" = "0" ]; then
        echo "ERROR: wpa_supplicant entry is still GID 0; ${DT_USER_NAME} was not granted socket access." >&2
        return 1
    fi
    if ! getent group "${gid}" >/dev/null; then
        group_name="wpa${gid}"
        if ! sudo groupadd -g "${gid}" "${group_name}"; then
            echo "ERROR: Failed to create group ${group_name} for wpa_supplicant GID ${gid}. ${DT_USER_NAME} was not granted socket access." >&2
            return 1
        fi
    fi
    group_name="$(getent group "${gid}" | cut -d: -f1)"
    if [ -z "${group_name}" ]; then
        echo "ERROR: No group for wpa_supplicant GID ${gid}; ${DT_USER_NAME} was not granted socket access." >&2
        return 1
    fi
    if ! sudo usermod -aG "${group_name}" "${DT_USER_NAME}"; then
        echo "ERROR: Failed to add ${DT_USER_NAME} to ${group_name} (GID ${gid})." >&2
        return 1
    fi
}
if [ -d "${WPA_DIR}" ]; then
    retarget_root_owned "${WPA_DIR}"
    for wpa_entry in "${WPA_DIR}"/*; do
        retarget_root_owned "${wpa_entry}"
    done
    grant_wpa_gid "$(stat -c %g "${WPA_DIR}")"
    if [ -e "${WPA_DIR}/wlan0" ]; then
        grant_wpa_gid "$(stat -c %g "${WPA_DIR}/wlan0")"
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
