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

# configure nginx log
if [ "${ACCESS_LOG:-}" != "1" ]; then
    # disable nginx logging to stdout
    sudo sed -i "s/access_log\ \/dev\/stdout\;/access_log\ \/dev\/null\;/g" /etc/nginx/sites-available/default
    # make nginx error log less verbose
    sudo sed -i "s/error_log\ \/dev\/stdout\ info;/error_log\ \/dev\/stdout\ warn;/g" /etc/nginx/sites-available/default
fi

# ----------------------------------------------------------------------------
# YOUR CODE ABOVE THIS LINE

# run compose entrypoint
dt-exec /compose-entrypoint.sh

# wait for app to end
dt-launchfile-join
