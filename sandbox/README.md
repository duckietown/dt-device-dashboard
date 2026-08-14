# Dashboard sandbox

Local UI sandbox for `dt-device-dashboard` (typically `http://localhost:8888`).

## Editable compose (DTSW-8250)

To exercise chrome/theme changes from a sibling `compose` checkout without committing
machine-absolute paths:

```text
.../repos/
  compose/                 # e.g. feature/DTSW-8241-dashboard-modern-chrome
  dt-device-dashboard/
    sandbox/compose  -> ../../compose
```

```bash
cd sandbox
make link-local-compose
make run-mount-local-compose ARCH=arm64v8   # Apple Silicon / OrbStack
```

Restore the tracked submodule pin:

```bash
make restore-compose-submodule
```

Do **not** commit a host-absolute symlink such as `/home/ubuntu/repos/compose`.
