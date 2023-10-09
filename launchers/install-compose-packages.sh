#!/bin/bash

source /environment.sh

# initialize launch file
dt-launchfile-init

# YOUR CODE BELOW THIS LINE
# ----------------------------------------------------------------------------

# constants
PACKAGE_MANAGER=${COMPOSE_DIR}/public_html/system/lib/python/compose/package_manager.py

# install compose dependencies
PACKAGES=$(awk -F: '/^[^#]/ { print $1 }' ${DT_PROJECT_PATH}/dependencies-compose.txt | uniq)
python3 \
    ${PACKAGE_MANAGER} \
    --install ${PACKAGES}


# ----------------------------------------------------------------------------
# YOUR CODE ABOVE THIS LINE

# wait for app to end
dt-launchfile-join
