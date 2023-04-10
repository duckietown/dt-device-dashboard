# Created by Andrea F. Daniele
# ----------------------------------------

DEFAULT_ARCH=amd64
ARCH=${DEFAULT_ARCH}
IMAGE=${DOCKER_REGISTRY}/duckietown/dt-device-dashboard
VERSION=ente-staging
H=unix:///var/run/docker.sock
CONTAINER_NAME=device-dashboard-sandbox
MKFILE_FPATH=$(abspath $(lastword $(MAKEFILE_LIST)))
DIR=$(patsubst %/,%,$(dir $(MKFILE_FPATH)))
EXTRA_ARGS=-v "/var/run/avahi-daemon/socket:/var/run/avahi-daemon/socket"

init:
	docker -H=${H} run \
		-it \
		--rm \
		-u $(shell id -u):$(shell id -g) \
		-v "${DIR}/user-data:/user-data" \
		"${IMAGE}:${VERSION}-${ARCH}" \
			dt-launcher-install-compose-packages

_clone_compose:
	test -d ${DIR}/compose || git clone git@github.com:afdaniele/compose ${DIR}/compose


run:
	docker -H=${H} run \
		-it \
		--rm \
		-p 8888:8080/tcp \
		-v "${DIR}/user-data:/user-data" \
		${EXTRA_ARGS} \
		--name "${CONTAINER_NAME}" \
		"${IMAGE}:${VERSION}-${ARCH}"


run-mount-compose: _clone_compose
	make run EXTRA_ARGS='${EXTRA_ARGS} -v "${DIR}/compose/:/var/www/html:rw"'

stop:
	docker stop "${CONTAINER_NAME}"

enter:
	docker exec -it "${CONTAINER_NAME}" bash
