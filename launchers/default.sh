#!/bin/bash

source /environment.sh

# initialize launch file
dt-launchfile-init

# YOUR CODE BELOW THIS LINE
# ----------------------------------------------------------------------------

# constants
HOSTNAME=$(hostname)

# add user www-data to group duckie[1000]
GID=1000
GNAME=duckie
if [ ! "$(getent group "${GID}")" ]; then
    echo "Creating a group '${GNAME}' with GID:${GID} for the user www-data"
    # create group
    groupadd --gid ${GID} ${GNAME}
    usermod -aG ${GNAME} www-data
else
    GROUP_STR=$(getent group ${GID})
    readarray -d : -t strarr <<< "$GROUP_STR"
    GNAME="${strarr[0]}"
    echo "A group with GID:${GID} (i.e., ${GNAME}) already exists. Reusing it."
fi

# configure \compose\
echo "Configuring \\compose\\ ..."
compose configuration/set --package core \
  "navbar_title=${HOSTNAME}" \
  "navbar_subtitle=(${ROBOT_TYPE})" \
  "website_name=${ROBOT_TYPE^} Dashboard" \
  "logo_white=http://${HOSTNAME}.local/d/data/duckietown/images/logo.png" \
  "logo_black=http://${HOSTNAME}.local/d/data/duckietown/images/logo.png"

dt-exec dt-advertise --name "DASHBOARD"

# ----------------------------------------------------------------------------
# YOUR CODE ABOVE THIS LINE

# run compose entrypoint
dt-exec /compose-entrypoint.sh

# wait for app to end
dt-launchfile-join
