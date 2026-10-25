# Dashboard sandbox

Local UI sandbox for `dt-device-dashboard` (typically `http://localhost:8888`).

## Editable compose (DTSW-8250)

`sandbox/compose` is a **relative symlink** to a sibling `compose` checkout:

```text
.../repos/
  compose/                 # e.g. feature/DTSW-8241-dashboard-modern-chrome
  dt-device-dashboard/
    sandbox/compose  -> ../../compose
```

```bash
cd sandbox
# recreate the relative link if needed
make link-local-compose
make run-mount-local-compose ARCH=arm64v8   # Apple Silicon / OrbStack
```

To use a pinned compose clone instead of the sibling symlink:

```bash
make restore-compose-clone
```

Do **not** replace the committed relative link with a host-absolute path such as `/home/ubuntu/repos/compose`.
