---
name: bump-talos-version
description: "Bump the Talos/kernel version for the RK3588 NPU extensions and roll it out safely. Use when: a new Talos release is out, syncing the fork with Talos, updating scripts/common.sh, changing TALOS_VERSION / KERNEL_VERSION / PKGS_COMMIT, rebuilding the signed rknpu.ko + installer, or upgrading RK1 nodes to a new NPU build. Handles version derivation, the module-signing/kernel coupling gotchas, build triggering, and canary rollout."
---

# Bump Talos version (RK3588 NPU stack)

Keep the vendor `rknpu` extensions + custom installer in lockstep with a Talos release.
Because `rknpu.ko` is welded to the exact kernel (vermagic) **and** signed by that
kernel's key, every Talos bump requires a coordinated rebuild + re-image. Do it in this
order.

## 0. Preconditions

- Know the **target Talos version** (e.g. from the `check-talos` issue, Renovate PR, or
  `siderolabs/talos` releases). Match your cluster's actual node version, not the latest
  `talosctl` CLI version.
- All edits go in [`scripts/common.sh`](../../../scripts/common.sh) — the single source of truth.

## 1. Derive the coupled versions (do NOT guess these)

For the chosen `TALOS_VERSION` (e.g. `v1.13.6`):

1. **`PKGS_COMMIT`** — the `siderolabs/pkgs` commit that release pins:
   ```
   https://github.com/siderolabs/talos/blob/<TALOS_VERSION>/pkg/machinery/gendata/data/pkgs
   ```
   Use the commit/tag referenced there (the `pkgs` image ref).
2. **`KERNEL_VERSION`** — the kernel that `siderolabs/pkgs` builds at that commit
   (`kernel/pkg.yaml`), formatted `X.Y.Z-talos` (e.g. `6.18.34-talos`). This is **not**
   the latest mainline tag — it must match what Talos actually ships.

> ⚠️ If `PKGS_COMMIT` / `KERNEL_VERSION` drift from `TALOS_VERSION`, the module builds
> against the wrong headers/config and fails to load — often silently. They are derived,
> not free choices.

## 2. Check for breaking changes

Skim the [Talos release notes](https://github.com/siderolabs/talos/releases) for kernel
config, module-signing, containerd/CDI, or `sbc-rockchip` overlay changes. Note anything
that could affect the module build or `/dev/rknpu` injection.

## 3. Edit `scripts/common.sh`

Update the three coupled pins together:

```bash
TALOS_VERSION="${TALOS_VERSION:-v1.13.6}"
KERNEL_VERSION="${KERNEL_VERSION:-6.18.34-talos}"
PKGS_COMMIT="${PKGS_COMMIT:-<derived-commit>}"
```

Leave `RKNPU_VERSION` / `RKNN_RUNTIME_VERSION` unless intentionally bumping the SDK.

## 4. Validate before trusting automerge

CI (`ci.yaml`) only lints — it does **not** compile the module. So a broken kernel bump
can pass CI. Before rolling out, trigger the real build and confirm `rknpu.ko` compiles:

```bash
gh workflow run "Build Extensions" --repo <owner>/talos-rk3588-npu --ref <branch>
gh workflow run "Build Installer"  --repo <owner>/talos-rk3588-npu --ref <branch>
```

Watch the runs; a kernel-API break shows up here, not in CI.

## 5. Release

Push to `main` → `auto-tag.yaml` tags `v<talos>-rknpu<rknpu>` → `release.yaml` builds and
publishes extensions + installer + device-plugin + bench images to GHCR.

## 6. Roll out via a CANARY node (never fleet-wide unattended)

1. Upgrade **one** RK1 node to the new installer:
   ```bash
   talosctl upgrade --nodes <CANARY_IP> \
     --image ghcr.io/<owner>/talos-rk3588-npu-installer-base:installer-<TALOS_VERSION> \
     --preserve
   ```
2. Ensure machine config references the matching extensions
   (`ghcr.io/<owner>/rockchip-rknpu:<rknpu>-<kernel>`, `rockchip-rknn-libs:<rknn>-<kernel>`).
3. Verify:
   ```bash
   talosctl get extensions --nodes <CANARY_IP>          # rockchip-rknpu, rockchip-rknn-libs
   talosctl dmesg --nodes <CANARY_IP> | grep rknpu       # driver initialized
   kubectl get node <canary> -o json | jq '.status.allocatable | with_entries(select(.key|startswith("rockchip")))'
   ```
4. Run the on-hardware smoke/bench: apply a Job from [`test/rknn-bench/`](../../../test/rknn-bench/)
   and confirm `init_runtime` succeeds and throughput is sane. This is the only real
   functional test — GitHub CI can't touch the NPU.
5. **Only if the canary passes**, upgrade the remaining RK1 nodes the same way.

## 7. Record anything surprising

Add new failure modes to [`BUGS.md`](../../../BUGS.md) (symptom → root cause → solution).
