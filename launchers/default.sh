#!/bin/bash

source /environment.sh

# initialize launch file
dt-launchfile-init

# YOUR CODE BELOW THIS LINE
# ----------------------------------------------------------------------------

# constants
HOSTNAME=$(hostname)
DATA_DIR=/data

# get GID of the data dir
GID=$(stat -c %g "${DATA_DIR}")
GNAME=dataers
# check if we have a group with that ID already
if [ ! "$(getent group "${GID}")" ]; then
  echo "Creating a group '${GNAME}' with GID:${GID} for the directory '${DATA_DIR}'"
  # create group
  groupadd --gid ${GID} ${GNAME}
else
  GROUP_STR=$(getent group ${GID})
  readarray -d : -t strarr <<< "$GROUP_STR"
  GNAME="${strarr[0]}"
  echo "A group with GID:${GID} (i.e., ${GNAME}) already exists. Reusing it."
fi

# add user www-data to group
echo "Adding user 'www-data' to the group '${GNAME}' (GID:${GID})."
usermod -aG ${GNAME} www-data

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

# configure `elfinder` package
compose configuration/set --package elfinder \
    mounts/mount0/driver=LocalFileSystem \
    mounts/mount0/enabled=1 \
    mounts/mount0/alias=data \
    mounts/mount0/path=/data

# make sure all databases belong to www-data
chown -R www-data:www-data /user-data/databases

# disable apache logging to stdout
rm -f /var/log/apache2/access.log
ln -s /dev/null /var/log/apache2/access.log

# ----------------------------------------------------------------------------
# YOUR CODE ABOVE THIS LINE

# run compose entrypoint
dt-exec /compose-entrypoint.sh

# wait for app to end
dt-launchfile-join
