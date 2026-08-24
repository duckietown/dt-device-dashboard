# Created by Andrea F. Daniele
# ----------------------------------------

DEFAULT_ARCH=amd64
ARCH=${DEFAULT_ARCH}
IMAGE=${DOCKER_REGISTRY}/duckietown/dt-device-dashboard
VERSION=ente
H=unix:///var/run/docker.sock
CONTAINER_NAME=device-dashboard-sandbox
MKFILE_FPATH=$(abspath $(lastword $(MAKEFILE_LIST)))
DIR=$(patsubst %/,%,$(dir $(MKFILE_FPATH)))
EXTRA_ARGS=-v "/var/run/avahi-daemon/socket:/var/run/avahi-daemon/socket"
# Sibling checkout when repos live next to each other, e.g. .../repos/{compose,dt-device-dashboard}
LOCAL_COMPOSE_REL=../../compose


init:
	docker -H=${H} run \
		-it \
		--rm \
		-v "${DIR}/user-data:/user-data" \
		-e IMPERSONATE_UID=$(shell id -u) \
		"${IMAGE}:${VERSION}-${ARCH}" \
			dt-launcher-install-compose-packages

	find ${DIR}/user-data/packages/*/.git/config -exec sed -i "s/https:\/\/github.com\/duckietown/git@github.com:duckietown/g" {} \;

_clone_compose:
	test -d ${DIR}/compose || git clone git@github.com:duckietown/compose ${DIR}/compose

# DTSW-8250: use editable sibling compose without committing host-absolute paths.
# Creates sandbox/compose -> ../../compose (portable across machines with the same layout).
link-local-compose:
	@test -d "${DIR}/${LOCAL_COMPOSE_REL}" || (echo "Missing ${DIR}/${LOCAL_COMPOSE_REL}; clone compose as a sibling of dt-device-dashboard first."; exit 1)
	rm -rf "${DIR}/compose"
	ln -sfn "${LOCAL_COMPOSE_REL}" "${DIR}/compose"
	@ls -la "${DIR}/compose"

# Optional: replace the sibling symlink with a pinned compose clone (former submodule SHA)
COMPOSE_PIN=1fc223c03b0c0ae57837314c747b11ca4ffec8bb
restore-compose-clone:
	rm -rf "${DIR}/compose"
	git clone git@github.com:afdaniele/compose "${DIR}/compose"
	git -C "${DIR}/compose" checkout "${COMPOSE_PIN}"
	@ls -la "${DIR}/compose"


run:
	docker -H=${H} run \
		-it \
		--rm \
		-p 8888:80/tcp \
		-e DT_SUPERUSER=1 \
		-v "${DIR}/user-data:/user-data" \
		-v "${DIR}/data:/data" \
		${EXTRA_ARGS} \
		--name "${CONTAINER_NAME}" \
		"${IMAGE}:${VERSION}-${ARCH}"


run-mount-compose: _clone_compose
	make run EXTRA_ARGS='${EXTRA_ARGS} -v "${DIR}/compose/:/var/www/html:rw"'

# Mount sibling editable compose (after `make link-local-compose`, or any compose at LOCAL_COMPOSE_REL)
run-mount-local-compose:
	@test -e "${DIR}/compose" || $(MAKE) link-local-compose
	make run EXTRA_ARGS='${EXTRA_ARGS} -v "${DIR}/compose/:/var/www/html:rw"'

stop:
	docker stop "${CONTAINER_NAME}"

enter:
	docker exec -it "${CONTAINER_NAME}" bash
