# dt-device-dashboard

The web dashboard that ships on every Duckiebot and Duckiedrone. It is a [`\compose\`](https://github.com/afdaniele/compose) application (PHP-FPM + nginx) running inside a Duckietown container.

On a robot it serves:

- `http://ROBOT_NAME.local/dashboard/setup` — first-boot setup wizard
- `http://ROBOT_NAME.local/dashboard/robot` — robot info page
- `http://ROBOT_NAME.local/dashboard/robot/mission_control` — live widget grid (the **mission** — default is defined by the `compose-pkg-duckietown-duckiedrone` or `compose-pkg-duckietown-duckiebot` package depending on the device class)
- `http://ROBOT_NAME.local/files` — elFinder file browser

This repo does **not** define the widgets — those live in sibling `\compose\` packages, pulled in via [`dependencies-compose.txt`](dependencies-compose.txt). Widget development is documented in [`compose/compose-pkg-duckietown-duckiedrone/README.md`](../../compose/compose-pkg-duckietown-duckiedrone/README.md).

---

## Repo layout (what matters)

```
dt-device-dashboard/
├── Dockerfile                      # Built on dt-ros-commons
├── dependencies-apt.txt            # System packages
├── dependencies-py3.txt            # Python packages
├── dependencies-py3.dt.txt         # Duckietown Python packages
├── dependencies-compose.txt        # \compose\ packages pulled into the image
├── launchers/
│   └── default.sh                  # Container entrypoint — sets up compose, nginx, php-fpm
├── sandbox/
│   ├── Makefile                    # Local-run helpers (make run, make run-mount-compose)
│   └── ...
├── html/, css/, js/, pdf/, images/ # Served static assets
├── packages/                       # Python / ROS packages (minimal — most logic is in compose pkgs)
├── tests/                          # Selenium-based dashboard tests
└── docs/                           # Dashboard-specific documentation
```

### Key file: `dependencies-compose.txt`

Pins the `\compose\` packages installed into the image. Example:

```
duckietown_duckiedrone==v2.2.2
ros==v1.0.5
...
```

To ship a new widget or update the default mission for Duckiedrones, bump the `duckietown_duckiedrone` version here, commit, rebuild.

### Key file: `launchers/default.sh`

Runs on container start. It:

1. Generates the compose configuration file.
2. Creates the `www-data`/`duckie` user groups.
3. Conditionally installs the elFinder composer dependencies if they're missing (see **Known issues** below).
4. Hands off to `/compose-entrypoint.sh`, which starts `php-fpm` and `nginx`.

---

## Development workflow

There are three ways to work on the dashboard, depending on what you're changing:

### A) Iterate on a widget (PHP) — use sandbox + mount

Most common loop. You have a widget you want to edit in a local `compose-pkg-*` checkout and you want to see changes on page reload.

```bash
# 1) Build the dashboard image once (pulls dependencies-compose.txt at build time)
DASHBOARD_REPO=/path/to/dt-device-dashboard

cd "${DASHBOARD_REPO}"
dts devel build

# 2) Run the sandbox with your local compose package mounted
COMPOSE_PACKAGE_NAME=duckietown_duckiedrone
LOCAL_PACKAGE_PATH=/path/to/compose-pkg-duckietown-duckiedrone

cd sandbox
make run EXTRA_ARGS="-v ${LOCAL_PACKAGE_PATH}:/user-data/packages/${COMPOSE_PACKAGE_NAME}:rw"
```

For Duckiebots, use `COMPOSE_PACKAGE_NAME=duckietown_duckiebot` and point `LOCAL_PACKAGE_PATH` at your `compose-pkg-duckietown-duckiebot` checkout instead.

The dashboard is now at `http://localhost:8888`. Changes to PHP files are picked up on page reload. Changes to `post_update` or default missions require a container restart (or run `docker exec <container> /user-data/packages/${COMPOSE_PACKAGE_NAME}/post_update`).

You still need to complete the setup wizard on first visit (see **Setup wizard** below).

### B) Iterate on the dashboard itself (layout, nginx, launcher) — rebuild + sandbox

If you're touching `launchers/default.sh`, the Dockerfile, or `dependencies-compose.txt`:

```bash
DASHBOARD_REPO=/path/to/dt-device-dashboard

cd "${DASHBOARD_REPO}"
dts devel build -f
cd sandbox && make run
```

### C) Deploy to a real or virtual robot

```bash
dts devel build -f -H ROBOT_NAME
dts devel run -H ROBOT_NAME --rm -- -e HTTP_PORT=8080 -v /data/ramdisk/dtps:/dtps -v /secrets:/secrets
```

To test a local compose package with `dts devel run -H ROBOT_NAME`, first copy that package onto the same host that `ROBOT_NAME` resolves to, then mount that remote path into `/user-data/packages/...`, then rerun `post_update` so the mission database picks up the mounted package. Choose the copy and `post_update` variant that matches the kind of target host behind `ROBOT_NAME`.

```bash
COMPOSE_PACKAGE_NAME=duckietown_duckiedrone
LOCAL_PACKAGE_PATH=/path/to/compose-pkg-duckietown-duckiedrone
REMOTE_PACKAGE_PATH=/path/on/ROBOT_NAME/compose-pkg-duckietown-duckiedrone

# if ROBOT_NAME is SSH-reachable, rsync is the simplest option:
rsync -a --delete "${LOCAL_PACKAGE_PATH}/" "ROBOT_NAME:${REMOTE_PACKAGE_PATH}/"

# if ROBOT_NAME is a virtual robot, copy into its host container instead:
VIRTUAL_HOST_CONTAINER=dts-virtual-ROBOT_NAME
docker exec "${VIRTUAL_HOST_CONTAINER}" rm -rf "${REMOTE_PACKAGE_PATH}"
docker exec "${VIRTUAL_HOST_CONTAINER}" mkdir -p "${REMOTE_PACKAGE_PATH}"
tar --exclude=.git --exclude=__pycache__ --exclude=.DS_Store -C "${LOCAL_PACKAGE_PATH}" -cf - . | \
  docker exec -i "${VIRTUAL_HOST_CONTAINER}" tar -xf - -C "${REMOTE_PACKAGE_PATH}"

# if a previous dashboard container is still running on the target host,
# remove it before rerunning dts devel run
# use this form for SSH-reachable targets:
docker rm -f dts-run-dt-device-dashboard || true

# use this form for virtual robots:
docker exec "${VIRTUAL_HOST_CONTAINER}" docker rm -f dts-run-dt-device-dashboard || true

dts devel run -H ROBOT_NAME --rm -- \
  -e HTTP_PORT=8080 \
  -v /data/ramdisk/dtps:/dtps \
  -v /secrets:/secrets \
  -v compose-data:/user-data/databases \
  -v "${REMOTE_PACKAGE_PATH}:/user-data/packages/${COMPOSE_PACKAGE_NAME}:rw" \
  -d

# then run post_update on the same target host
# use this form for SSH-reachable targets:
docker exec dts-run-dt-device-dashboard \
  /user-data/packages/${COMPOSE_PACKAGE_NAME}/post_update

# use this form for virtual robots:
docker exec "${VIRTUAL_HOST_CONTAINER}" \
  docker exec dts-run-dt-device-dashboard \
  /user-data/packages/${COMPOSE_PACKAGE_NAME}/post_update
```

For Duckiebots, use `COMPOSE_PACKAGE_NAME=duckietown_duckiebot` and set the local/remote paths to your `compose-pkg-duckietown-duckiebot` checkout instead.

In production, the dashboard is published via Docker Hub as `duckietown/dt-device-dashboard:<distro>` and pulled onto robots by `dts duckiebot update ROBOT_NAME`.

---

## Testing with a virtual Duckiedrone

The dashboard is reachable at `http://<robot>.local/` for any virtual robot started via `dts duckiebot virtual`. For the arming/flight widgets to have a live backend, the Duckiematrix simulator must also be running with the `sandbox_drone` map and the drone must be attached.

Full sequence:

```bash
# 1) Create and start the virtual drone
dts duckiebot virtual create --type duckiedrone --configuration DD24 testdrone
dts duckiebot virtual start testdrone

# 2) Start the Duckiematrix engine with the drone sandbox map
docker rm -f dts-matrix-engine 2>/dev/null || true
dts matrix engine run -m sandbox_drone --embedded --expose-ports

# 3) Attach the virtual drone to the matrix (maps the drone to map_0/vehicle_0)
dts matrix attach -m testdrone map_0/vehicle_0

# 4) Open the dashboard
xdg-open http://testdrone.local/
```

First visit needs the setup wizard; see below.

### Setup wizard

On a fresh dashboard, `/dashboard/setup` walks through four steps. In a dev environment you can auto-complete it with curl:

```bash
# step 3 & 4 confirmations — performs the first-boot setup
curl -sSL -b cookies.txt -c cookies.txt "http://testdrone.local/dashboard/setup?step=3&confirm=1" -o /dev/null
curl -sSL -b cookies.txt -c cookies.txt "http://testdrone.local/dashboard/setup?step=4&confirm=1" -o /dev/null
```

### Automated dashboard test (Selenium)

A reference selenium script lives at [`../../docs/dashboard-test-report/`](../../docs/dashboard-test-report/) — it opens the dashboard, screenshots each page, and calls the arming services via rosbridge. Run it with:

```bash
pip3 install selenium
# geckodriver must be on PATH — see docs/dashboard-test-report/README.md for install notes
python3 /tmp/dashboard_test.py
```

It dumps screenshots, a log, and a JSON result file to `docs/dashboard-test-report/`.

---

## Build and run reference

### Run against a robot

```bash
dts devel run -H ROBOT_NAME --rm -- -e HTTP_PORT=8080 -v /data/ramdisk/dtps:/dtps -v /secrets:/secrets
```

### Run locally (sandbox)

```bash
cd sandbox && make run
```

Binds PHP-FPM to `/run/php/php7.4-fpm.sock`, starts nginx, maps container port 80 → host 8888.

### Run locally with a mounted compose package

```bash
COMPOSE_PACKAGE_NAME=duckietown_duckiedrone
LOCAL_PACKAGE_PATH=/path/to/compose-pkg-duckietown-duckiedrone

cd sandbox
make run EXTRA_ARGS="-v ${LOCAL_PACKAGE_PATH}:/user-data/packages/${COMPOSE_PACKAGE_NAME}:rw"
```

The mounted package must have been baked into the image at least once (via `dependencies-compose.txt`); the package manager does not install on mount.

### Run against a robot with a mounted compose package

```bash
COMPOSE_PACKAGE_NAME=duckietown_duckiedrone
REMOTE_PACKAGE_PATH=/path/on/ROBOT_NAME/compose-pkg-duckietown-duckiedrone

dts devel run -H ROBOT_NAME --rm -- \
  -e HTTP_PORT=8080 \
  -v /data/ramdisk/dtps:/dtps \
  -v /secrets:/secrets \
  -v compose-data:/user-data/databases \
  -v "${REMOTE_PACKAGE_PATH}:/user-data/packages/${COMPOSE_PACKAGE_NAME}:rw" \
  -d
```

The `REMOTE_PACKAGE_PATH` part is evaluated on the target host, not in your dev container. If that path is empty on the target host, it hides the baked package inside the image.

---

## Known issues / gotchas

### 1. elFinder composer autoload missing → dashboard 500 on first run

Symptom: blank page / 500 on `/files` or widgets that use file-browser features. The error message (check `docker logs`) is typically:

```
E_COMPILE_ERROR: require(...)/vendor/autoload.php: Failed to open stream
```

This happens because the elFinder package isn't installed in the user-data composer project. Fix, inside the dashboard container:

```bash
docker exec -it <dashboard_container> bash -lc '
  cd /user-data/packages/elfinder/data/private/composer/ && \
  composer require --no-audit studio-42/elfinder:^2.1.66 && \
  ln -sf vendor/studio-42/elfinder/js   ../public/js && \
  ln -sf vendor/studio-42/elfinder/css  ../public/css && \
  ln -sf vendor/studio-42/elfinder/img  ../public/img && \
  ln -sf vendor/studio-42/elfinder/sounds ../public/sounds
'
```

`launchers/default.sh` attempts this conditionally, but the check can false-negative on some environments — this is the workaround.

### 2. `dts devel run -H ROBOT_NAME` compose-package mounts use the target host filesystem

Symptom: `dts devel run -H ROBOT_NAME ... -v /some/path:/user-data/packages/<package>:rw` starts, but the package inside the dashboard looks empty or renderer files disappear.

Cause: `/some/path` is resolved on the Docker host behind `ROBOT_NAME`, not in your local dev container. Copy the compose package onto that target host first, then mount that remote path. Also, `ROBOT_NAME` is not always an SSH hostname. Virtual robots can work with `dts devel run -H ROBOT_NAME` but still require file-copy and follow-up `docker exec` commands to go through `dts-virtual-ROBOT_NAME`.

Required sequence:

```bash
COMPOSE_PACKAGE_NAME=duckietown_duckiedrone
LOCAL_PACKAGE_PATH=/path/to/compose-pkg-duckietown-duckiedrone
REMOTE_PACKAGE_PATH=/path/on/ROBOT_NAME/compose-pkg-duckietown-duckiedrone
VIRTUAL_HOST_CONTAINER=dts-virtual-ROBOT_NAME

# use this when ROBOT_NAME is SSH-reachable:
rsync -a --delete "${LOCAL_PACKAGE_PATH}/" "ROBOT_NAME:${REMOTE_PACKAGE_PATH}/"

# use this instead when ROBOT_NAME is a virtual robot:
tar --exclude=.git --exclude=__pycache__ --exclude=.DS_Store -C "${LOCAL_PACKAGE_PATH}" -cf - . | docker exec -i "${VIRTUAL_HOST_CONTAINER}" tar -xf - -C "${REMOTE_PACKAGE_PATH}"

# if a previous dashboard container is still running on the target host,
# remove it before rerunning dts devel run
# use this form for SSH-reachable targets:
docker rm -f dts-run-dt-device-dashboard || true

# use this form for virtual robots:
docker exec "${VIRTUAL_HOST_CONTAINER}" docker rm -f dts-run-dt-device-dashboard || true

dts devel run -H ROBOT_NAME --rm -- -e HTTP_PORT=8080 -v /data/ramdisk/dtps:/dtps -v /secrets:/secrets -v compose-data:/user-data/databases -v "${REMOTE_PACKAGE_PATH}:/user-data/packages/${COMPOSE_PACKAGE_NAME}:rw" -d

# use this when ROBOT_NAME is SSH-reachable:
docker exec dts-run-dt-device-dashboard /user-data/packages/${COMPOSE_PACKAGE_NAME}/post_update

# use this instead when ROBOT_NAME is a virtual robot:
docker exec "${VIRTUAL_HOST_CONTAINER}" docker exec dts-run-dt-device-dashboard /user-data/packages/${COMPOSE_PACKAGE_NAME}/post_update
```

### 3. `~/` paths in default mission don't resolve on virtual drones

Default missions ship with topic/service paths like `~/mavros/cmd/arming`. Rosbridge on a virtual drone resolves `~` to the rosbridge node's own namespace (`/testdrone/rosbridge_websocket`), not to the robot's top-level namespace (`/`). As a result, widgets silently fail to find `/mavros/...` services.

Workaround for now: edit the mission in the UI and replace `~/mavros/...` with `/mavros/...` (absolute paths).

Upstream fix: [`compose-pkg-duckietown-duckiedrone`](../../compose/compose-pkg-duckietown-duckiedrone) default mission should be updated to use absolute paths. See [`docs/dashboard-test-report/README.md`](../../docs/dashboard-test-report/README.md).

### 4. Arming a virtual drone requires the Duckiematrix sensor stack

Arming via `/mavros/cmd/arming` returns `{result: 1, success: false}` when PX4's preflight checks fail. On a virtual drone connected to `sandbox_drone`, you can see the rejection reason in the container logs of the drone's `pid-controller` / PX4 service (e.g. "High Accelerometer Bias", "BARO #0 failed: TIMEOUT!"). To work around in test environments, matrix must be running and attached **before** arming — see the sequence under **Testing with a virtual Duckiedrone**.

---

## Updating the dashboard's compose packages

This is the typical "I added a widget" flow, end-to-end:

1. Make PHP changes in `compose/compose-pkg-duckietown-duckiedrone/` (see that README for widget conventions).
2. Test locally via **Dev workflow A** above (sandbox + mount).
3. Bump `VERSION` + `CHANGELOG.md` in the compose package; tag and push.
4. Bump the pin in this repo's `dependencies-compose.txt` to the new tag.
5. Commit here, rebuild (`dts devel build -f`), verify in sandbox.
6. Push to `ente` branch. CI builds and publishes the `duckietown/dt-device-dashboard:ente` image.
7. On robots, `dts duckiebot update ROBOT_NAME` pulls the new image.

---

## Legacy template notes

This repo was scaffolded from `template-compose`. If you're starting a brand-new dashboard from scratch:

1. Fork `template-compose` on GitHub.
2. Fill dependencies files.
3. Build with `dts devel build` and run with `cd sandbox && make run`.

For an ordinary edit of the Duckietown dashboard, you do **not** need to fork — work on this repo directly.
