#!/bin/bash

source /environment.sh

# initialize launch file
dt-launchfile-init

# YOUR CODE BELOW THIS LINE
# ----------------------------------------------------------------------------

# constants
HOSTNAME=$(hostname)

# add user www-data to group duckie[1000]
groupadd --gid 1000 duckie
usermod -aG duckie www-data

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
