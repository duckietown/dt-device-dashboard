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

Most common loop. You have a widget you want to edit (a PHP file under [`compose/compose-pkg-duckietown-duckiedrone/modules/renderers/blocks/`](../../compose/compose-pkg-duckietown-duckiedrone/modules/renderers/blocks/)) and you want to see changes on page reload.

```bash
# 1) Build the dashboard image once (pulls dependencies-compose.txt at build time)
cd /workspaces/dt-env-developer/robot/dt-device-dashboard
dts devel build

# 2) Run the sandbox with your local compose package mounted
cd sandbox
make run EXTRA_ARGS='-v "/workspaces/dt-env-developer/compose/compose-pkg-duckietown-duckiedrone:/user-data/packages/duckietown_duckiedrone:rw"'
```

The dashboard is now at `http://localhost:8888`. Changes to PHP files are picked up on page reload. Changes to `post_update` or default missions require a container restart (or run `docker exec <container> /user-data/packages/duckietown_duckiedrone/post_update`).

You still need to complete the setup wizard on first visit (see **Setup wizard** below).

### B) Iterate on the dashboard itself (layout, nginx, launcher) — rebuild + sandbox

If you're touching `launchers/default.sh`, the Dockerfile, or `dependencies-compose.txt`:

```bash
cd /workspaces/dt-env-developer/robot/dt-device-dashboard
dts devel build -f
cd sandbox && make run
```

### C) Deploy to a real or virtual robot

```bash
dts devel build -f -H ROBOT_NAME
dts devel run -H ROBOT_NAME --rm -- -e HTTP_PORT=8080 -v /data/ramdisk/dtps:/dtps -v /secrets:/secrets
```

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

# 3) Attach the virtual drone to the matrix (maps the drone to map_0/vehicle_1)
dts matrix attach -m testdrone map_0/vehicle_1

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
cd sandbox
make run EXTRA_ARGS='-v "${HOME}/Duckietown/ente/compose/compose-pkg-duckietown-duckiedrone:/user-data/packages/duckietown_duckiedrone:rw"'
```

The mounted package must have been baked into the image at least once (via `dependencies-compose.txt`); the package manager does not install on mount.

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

### 2. `~/` paths in default mission don't resolve on virtual drones

Default missions ship with topic/service paths like `~/mavros/cmd/arming`. Rosbridge on a virtual drone resolves `~` to the rosbridge node's own namespace (`/testdrone/rosbridge_websocket`), not to the robot's top-level namespace (`/`). As a result, widgets silently fail to find `/mavros/...` services.

Workaround for now: edit the mission in the UI and replace `~/mavros/...` with `/mavros/...` (absolute paths).

Upstream fix: [`compose-pkg-duckietown-duckiedrone`](../../compose/compose-pkg-duckietown-duckiedrone) default mission should be updated to use absolute paths. See [`docs/dashboard-test-report/README.md`](../../docs/dashboard-test-report/README.md).

### 3. Arming a virtual drone requires the Duckiematrix sensor stack

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
