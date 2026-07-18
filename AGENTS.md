# AGENTS.md

Orientation for AI agents working in this repo. **Read this first.** For deep detail,
follow the links rather than duplicating — see [README.md](README.md),
[BUGS.md](BUGS.md), and [CONTRIBUTING.md](CONTRIBUTING.md).

## What this repo is

Talos Linux **system extensions + a Kubernetes CDI device plugin** that run the
Rockchip **RK3588 NPU (vendor RKNN stack)** on Talos's **mainline** kernel, so pods
(e.g. Immich ML) get NPU inference **without `privileged: true`**. Validated on the
**Turing RK1 (RK3588)**.

## The one mental model you must have: two NPU stacks

The RK3588 NPU has two mutually-exclusive software stacks. Never conflate them.

| Stack           | Kernel driver                | Userspace   | Model format | This repo       |
| --------------- | ---------------------------- | ----------- | ------------ | --------------- |
| **Vendor RKNN** | `rknpu` (out-of-tree module) | `librknnrt` | `.rknn`      | ✅ what we ship |
| Mainline Rocket | `accel/rocket` (in-tree)     | Mesa Teflon | `.tflite`    | ❌ not us       |

We build the **vendor `rknpu`** driver (ported to mainline by
[w568w/rknpu-module](https://github.com/w568w/rknpu-module)) as an out-of-tree module,
plus `librknnrt.so`. This exposes `/dev/rknpu` (a misc device) — **not**
`/dev/dri/renderD*` and **not** `/dev/accel`.

## Absolute constraints (non-negotiable)

1. **Kernel module ⇄ kernel version coupling.** `rknpu.ko` is stamped with an exact
   kernel vermagic (`6.18.x-talos`). It loads **only** on that exact kernel. A module
   built for one Talos release will not load on another.
2. **Module signing.** Talos boots with `module.sig_enforce=1`. `rknpu.ko` must be
   signed by the **same key** baked into the running kernel. That is why we ship a
   **custom Talos installer** (our kernel build) alongside the extensions — you cannot
   load our module on a stock siderolabs kernel. Installer + extensions + node kernel
   must all come from the **same build**.
3. **`scripts/common.sh` is the single source of truth** for every version
   (`TALOS_VERSION`, `KERNEL_VERSION`, `PKGS_COMMIT`, `RKNPU_VERSION`,
   `RKNN_RUNTIME_VERSION`). Change versions **only** there.
4. **`KERNEL_VERSION` and `PKGS_COMMIT` are derived from `TALOS_VERSION`**, not chosen
   freely. `PKGS_COMMIT` is the `siderolabs/pkgs` commit pinned by the Talos release
   (see `pkg/machinery/gendata/data/pkgs` at that tag). If they drift, the build is
   silently wrong. See the `bump-talos-version` skill.

## Build & test

Primary builds run in **GitHub Actions** on native `ubuntu-24.04-arm` runners.
Locally, `make help` lists targets. Key ones:

```bash
make lint          # shellcheck + go vet + yaml validate (what CI runs today)
make extensions    # build rknpu.ko + librknnrt.so extensions -> REGISTRY
make plugin        # build the CDI device plugin image -> REGISTRY
make dtbo          # compile the Turing RK1 device-tree overlay
make deploy        # kubectl apply the device-plugin DaemonSet
```

**Pitfall — CI does not build the kernel module.** `ci.yaml` (which gates Renovate
automerge) runs only shellcheck / go vet / YAML validation. The actual `rknpu.ko`
compile happens later in `release.yaml` on the tag. So a Talos bump that breaks the
module build can pass CI and auto-merge. Treat "green CI" as "lint passed", not
"it builds".

**Real functional testing needs hardware.** GitHub runners have no NPU. NPU inference
is validated by deploying the bench Jobs in [test/rknn-bench/](test/rknn-bench/) to a
real RK1 node. Prefer a **canary node**: upgrade one RK1, run the bench, verify, then
roll the rest.

## Repository map

| Path                                                | What                                                                   |
| --------------------------------------------------- | ---------------------------------------------------------------------- |
| `scripts/common.sh`                                 | version pins (single source of truth)                                  |
| `scripts/build-extensions.sh`, `build-installer.sh` | build entry points                                                     |
| `rockchip-rknpu/`                                   | extension: `rknpu.ko` (Kbuild, udev rule, `rknpu_mem.c` fix, CDI spec) |
| `rockchip-rknn-libs/`                               | extension: `librknnrt.so`                                              |
| `plugins/rk3588-npu-device-plugin/`                 | Go CDI device plugin (advertises `rockchip.com/npu`)                   |
| `boards/turing-rk1/overlays/rknpu.dts`              | device-tree overlay (adds the NPU node + `iommus`)                     |
| `kernel/config-arm64-rk3588-npu.fragment`           | kernel config fragment                                                 |
| `deploy/`                                           | device-plugin DaemonSet + example pods                                 |
| `test/rknn-bench/`                                  | on-hardware NPU vs CPU benchmark (Jobs + C/Python harness)             |
| `.github/workflows/`                                | `check-talos`, `ci`, `auto-tag`, `release`, `build-*`                  |

## How a node consumes the NPU

Pod requests `resources.limits: rockchip.com/npu: "1"`; the device plugin's CDI spec
injects `/dev/rknpu` + `/dev/dma_heap/system` + `librknnrt.so`. No `privileged`. The
plugin advertises **3 units** (one per NPU core). See
[README §8](README.md#8-running-npu-pods).

## Conventions

- **Conventional Commits** ([spec](https://www.conventionalcommits.org/)).
- Test changes with **a full boot cycle on real hardware**; for module changes verify
  the module loads and `init_runtime()` succeeds ([CONTRIBUTING.md](CONTRIBUTING.md)).
- Record non-obvious fixes in [BUGS.md](BUGS.md) (symptom → root cause → solution).
- MIT licensed.

## Downstream consumer

This stack exists to give **Immich ML** (and similar) NPU acceleration on the homelab
Talos cluster. The consumer wiring (Immich `-rknn` image + `rockchip.com/npu` resource)
lives in the separate `taloskubecluster` repo, not here.
