# PVC Monitoring POC

An educational proof-of-concept for monitoring Kubernetes PVC health: binding failures, capacity exhaustion, inode exhaustion, and active I/O failures. Runs on a local [kind](https://kind.sigs.k8s.io/) cluster or any Kubernetes cluster with a StorageClass.

## What this teaches

| Failure mode | Detection signal | Alert |
|--------------|------------------|-------|
| PVC stuck Pending | `kube_persistentvolumeclaim_status_phase` | `PVCNotBound` |
| PVC Lost | phase = Lost | `PVCLost` |
| Disk filling up | `kubelet_volume_stats_*` | `PVCFillingUp`, `PVCAlmostFull` |
| Inode exhaustion | `kubelet_volume_stats_inodes_*` | `PVCInodesExhausted` |
| Write/I/O failure | Custom canary metric `pvc_canary_write_success` | `PVCWriteCanaryFailed` |
| PV lifecycle issues | `kube_persistentvolume_status_phase` | `PVFailed`, `PVReleased` |
| Disk I/O saturation | `node_disk_io_time_seconds_total` | `NodeDiskIOSaturation` |

The fault-injector webapp simulates most failures on local volumes; **Chaos Mesh IOChaos** injects real write I/O errors on `pvc-fault` so you can watch alerts fire and resolve in real time.

## Prerequisites

**kind (local):**

```bash
kind --version          # >= 0.20
kubectl version         # >= 1.28
helm version            # >= 3.12
docker info             # running
```

**Remote cluster:** `kubectl` + `helm` pointed at your cluster, a default or named `StorageClass`, and a container registry to push the fault-injector image.

## Quick start (kind)

`make deploy` creates the kind cluster and switches your kubectl context to `kind-pvc-monitoring-poc`. If you use a different context, pass `KUBE_CONTEXT=kind-pvc-monitoring-poc` on make targets.

```bash
make cluster-up
make deploy
make port-forward       # in a separate terminal
```

## Quick start (remote cluster)

Uses your **current kubectl context** by default. Override with `KUBE_CONTEXT=my-context` when needed.

```bash
# Private registry: create pull secret first (copy registry-credentials.env.example)
cp fault-injector/k8s/registry-credentials.env.example fault-injector/k8s/registry-credentials.env
# edit registry-credentials.env, then:
make create-pull-secret APP_NAMESPACE=default

# Build (linux/amd64), push, and deploy - cross-builds on Apple Silicon.
# The Dockerfile compiles on your native arch and copies into the amd64 image (no emulated apk/npm).
make push deploy-remote \
  STORAGE_CLASS=standard \
  REMOTE_IMAGE=ghcr.io/you/fault-injector:latest \
  IMAGE_PULL_SECRET=fault-injector-pull
```

Then port-forward (or use Ingress / `kubectl proxy`):

```bash
make port-forward
```

**Rollout timeout?** Check events - managed clusters often enforce Pod Security `baseline`, which blocks `privileged: true`. The remote deployment no longer requests privileged. If a previous attempt left a stuck Deployment, delete it and re-run `make deploy-app-remote`:

```bash
kubectl delete deployment fault-injector -n default
make deploy-app-remote REMOTE_IMAGE=... IMAGE_PULL_SECRET=...
```

**Alerts not reaching Alertmanager or the web UI?** The UI shows alerts only from Alertmanager webhooks (not live queries). The pipeline is:

```
fault → Prometheus metric → PrometheusRule → Alertmanager → POST /alerts → UI history
```

Re-apply monitoring with your app namespace (fixes webhook URL + ServiceMonitor scrape):

```bash
make deploy-monitoring deploy-monitoring-cr APP_NAMESPACE=default
make diagnose-alerts APP_NAMESPACE=default
```

Common causes: Prometheus not scraping `/metrics` (missing ServiceMonitor), Alertmanager webhook pointing at wrong namespace, or alert `for:` duration not elapsed yet (1–2 minutes after injecting a fault).

**What changes on a real cluster:**

| kind-only | Remote equivalent |
|-----------|-------------------|
| `make cluster-up` | Your existing cluster |
| `storage/` local PVs + node paths | `storage/remote/pvcs.yaml` (dynamic PVCs) |
| `kind load` + `imagePullPolicy: Never` | `make push` + `REMOTE_IMAGE` (builds `linux/amd64` via buildx) |
| `make setup-storage-paths` (tmpfs vol3) | Not available - inode demo may not fire |
| `make teardown` (deletes kind) | `make teardown-remote` |

Optional Chaos Mesh on a real cluster (often works better than on arm64 Mac kind):

```bash
make deploy-chaos
```

Open:

- **Fault injector UI**: http://localhost:8080
- **Grafana**: http://localhost:3000 (admin / `poc-admin`)
- **Prometheus**: http://localhost:9090
- **Alertmanager**: http://localhost:9093

## Architecture

```
┌─────────────┐     metrics      ┌────────────┐
│ fault-      │ ───────────────► │ Prometheus │
│ injector    │                  └─────┬──────┘
│ (canary +   │                        │ rules
│  faults)    │ ◄── webhook ──── ┌─────▼──────┐
└──────┬──────┘                  │ Alertmanager│
       │ mounts                  └────────────┘
       ▼
┌─────────────┐     stats        ┌────────────┐
│ Local PVs   │ ◄─────────────── │ kubelet +  │
│ (vol1-3)    │                  │ kube-state │
└─────────────┘                  └────────────┘
       ▲
       │ IOChaos (FUSE overlay on /data/fault)
┌──────┴──────┐
│ Chaos Mesh  │
│ chaos-daemon│
└─────────────┘
```

## Methodology

This POC separates **how faults are provoked** from **how they are observed**. Most demos deliberately stress a single PVC and a single signal so you can correlate cause and alert.

### PVC roles

The fault-injector pod mounts three PVCs. Each is reserved for different failure classes:

| PVC | Mount path | Size (kind) | Used for |
|-----|------------|-------------|----------|
| `pvc-healthy` | `/data/healthy` | 100Mi | Baseline - canary should stay `1` |
| `pvc-filling` | `/data/filling` | **10Mi** | Capacity demos (`demo-fill`) |
| `pvc-fault` | `/data/fault` | 100Mi (tmpfs, 2048 inodes on kind) | I/O and inode demos |

A fourth PVC, `pvc-unbound`, is created only for Scenario D and is not mounted by the app.

### Two ways to provoke failures

```
┌─────────────────────────────────────────────────────────────────────────┐
│                        FAULT INJECTION LAYERS                           │
├──────────────────────────────┬──────────────────────────────────────────┤
│  fault-injector (in-pod)     │  Cluster / storage layer                 │
│  HTTP API or UI              │                                          │
├──────────────────────────────┼──────────────────────────────────────────┤
│  • fill-disk                 │  • pvc-unbound (no matching PV)          │
│  • read-only (simulated)     │  • IOChaos write EIO / latency           │
│  • inode-flood               │    (Chaos Mesh FUSE on /data/fault)      │
│  • corrupt-block             │                                          │
│  • canary loop (continuous)  │                                          │
└──────────────────────────────┴──────────────────────────────────────────┘
```

**In-pod injection** - You call `POST /fault/*` on the fault-injector (via `make demo-*`, the web UI, or `curl`). The app writes directly to its mounted volumes. Changes are visible to the kubelet volume stats and to the canary loop in the same pod.

**Cluster-layer injection** - `demo-unbound` applies a PVC that cannot bind. `demo-io-fault` applies a Chaos Mesh `IOChaos` CR; chaos-daemon overlays `/data/fault` with FUSE (`toda`) so real `write()` syscalls fail with errno 5 (EIO).

### How each fault is injected

| Demo | Trigger | Mechanism | What actually happens |
|------|---------|-----------|------------------------|
| **A - Fill-up** | `make demo-fill` | App writes `.fault-fill/fill.bin` on `pvc-filling` | Appends 256KiB chunks until ~92% of PVC capacity. Kubelet reports higher `kubelet_volume_stats_used_bytes`. |
| **B - Read-only I/O** | `make demo-readonly` | In-memory fault flag | No filesystem change. Canary loop sees `read-only` in `activeFaults` and reports `pvc_canary_write_success=0` without writing. Safe on kind (no remount). |
| **B2 - Real I/O error** | `make demo-io-fault` | Chaos Mesh `IOChaos` | FUSE intercepts `WRITE` on `/data/fault/**/*` → EIO. Canary `fs.writeFileSync` fails → metric `0`. |
| **B2 - Write latency** | `make demo-io-latency` | Chaos Mesh `IOChaos` | Adds 2s delay to writes; canary still succeeds unless timeouts occur. |
| **C - Inodes** | `make demo-inodes` | App creates many empty files in `.fault-inodes/` | Floods inodes on `pvc-fault`. On kind, vol3 is tmpfs with 2048 inodes so 85% is reachable. |
| **D - Not bound** | `make demo-unbound` | `monitoring/scenarios/pvc-unbound.yaml` | PVC requests 10Gi on `local-storage` with no free PV → stays `Pending`. |

**Reset** (`make demo-reset`) clears app faults (deletes `.fault-fill`, `.fault-inodes`, fault flags), deletes IOChaos CRs, and removes `pvc-unbound`.

### Canary probe (active I/O health)

Every **15 seconds** the fault-injector writes a timestamp file on each mount, reads it back, and deletes it. The result is exported as `pvc_canary_write_success` (1 = ok, 0 = fail).

```
every 15s per PVC mount:
  write  →  read back  →  delete  →  gauge 1 or 0
                │
                └── fails on: IOChaos EIO, simulated read-only, real permission/I/O errors
```

This is an **application-level** probe: it answers “can a pod using this PVC perform a basic write?” - often more actionable than node-level disk error counters.

Prometheus scrapes `/metrics` on the fault-injector (`ServiceMonitor`). Alert rule `PVCWriteCanaryFailed` fires when the gauge is `0` for 1 minute.

### Passive metrics (no injection required)

These signals come from cluster components already installed by `deploy-monitoring`:

| Signal | Source | Alerts |
|--------|--------|--------|
| PVC phase (`Bound`, `Pending`, `Lost`) | kube-state-metrics | `PVCNotBound`, `PVCLost` |
| Volume capacity / inodes | kubelet → Prometheus | `PVCFillingUp`, `PVCAlmostFull`, `PVCInodesExhausted` |
| PV phase | kube-state-metrics | `PVFailed`, `PVReleased` |
| Node disk I/O busy time | node-exporter | `NodeDiskIOSaturation` |

Fill and inode demos rely on kubelet stats updating after the fault-injector changes filesystem usage. Binding demos rely only on API-reported PVC phase.

### End-to-end alert path

```
  fault injected
        │
        ▼
  metric changes          PrometheusRule (monitoring/pvc-alert-rules.yaml)
  (kubelet stats,              │
   canary gauge,                ▼
   kube-state-metrics)    Alertmanager
                                │
                    ┌───────────┴───────────┐
                    ▼                       ▼
              Grafana dashboards     webhook → fault-injector /alerts
              (PVC + Chaos events)     (UI alert history)
```

Alertmanager is configured to POST PVC alerts to `fault-injector.default.svc:8080/alerts`, so fired and resolved alerts appear in the web UI history.

### Choosing a demo for your cluster

| Environment | Fill-up | I/O failure | Inodes | Unbound | Real I/O (IOChaos) |
|-------------|---------|-------------|--------|---------|-------------------|
| kind (local) | ✓ | ✓ simulated (`demo-readonly`) | ✓ (tmpfs vol3) | ✓ | Optional (`deploy-chaos`; amd64/toda limits on arm64 Mac) |
| Remote / managed | ✓ (needs small `pvc-filling`) | ✓ simulated | Unlikely (large FS) | ✓ if StorageClass has no capacity | ✓ (often best on amd64 nodes) |

## Demo scenarios

Run `make port-forward` first so demo commands can reach the fault injector.

### Scenario A - PVC fill-up

```bash
make demo-fill
```

**Expected**: `PVCFillingUp` within ~1 minute; `PVCAlmostFull` if usage exceeds 95%.

**Verify**: Prometheus http://localhost:9090/alerts, Grafana dashboard "PVC Monitoring POC", webapp alert history.

### Scenario B - I/O failure (simulated read-only)

```bash
make demo-readonly
```

**Expected**: `pvc_canary_write_success{pvc="pvc-fault"} 0` → `PVCWriteCanaryFailed` within ~1 minute.

This uses an in-app fault flag (no real remount). On kind, remounting bind mounts read-only can mark the entire node filesystem read-only, so this scenario stays simulated.

### Scenario B2 - I/O failure (real write errors via Chaos Mesh)

**CLI:**

```bash
make deploy-chaos          # once per cluster
make demo-io-fault
```

**Web UI:** After `deploy-chaos`, open the fault-injector UI - a **Chaos Mesh IOChaos** panel appears automatically when the CRD is detected. Use **Write EIO** / **Write latency** / **Reset IOChaos** (same as `demo-io-fault`, `make demo-io-latency`, and `make demo-io-reset`).

**Chaos Dashboard:** `make deploy-chaos` installs the [Chaos Mesh web UI](https://chaos-mesh.org/docs/run-a-chaos-experiment/) (experiment status, IOChaos builder, event timeline). With `make port-forward`, open http://localhost:2333 (auth disabled for POC in `helm/chaos-mesh-values.yaml`).

**Grafana + Chaos Mesh:** `make deploy-monitoring` installs the official [Chaos Mesh Grafana datasource plugin](https://chaos-mesh.org/docs/use-grafana-data-source/) (`chaosmeshorg-datasource`) and points it at the chaos-dashboard API. After `make deploy-chaos` and `make deploy-monitoring-cr`:

- **PVC Monitoring POC** dashboard - IOChaos event annotations on the canary panel + events table row
- **Chaos Mesh Events** dashboard - IOChaos and all chaos events as tables

Open Grafana at http://localhost:3000 (admin / `poc-admin`) via `make port-forward`. The datasource reads **chaos events** (inject/recover timeline), not Prometheus metrics - use it to correlate `demo-io-fault` with canary/alert drops on the same timeline.

Requires the fault-injector ServiceAccount RBAC (`fault-injector/k8s/rbac.yaml`, applied by `make deploy-app`).

**Expected**: same alert as Scenario B, but caused by **real** write failures (errno 5 / EIO) injected by [IOChaos](https://chaos-mesh.org/docs/simulate-io-chaos-on-kubernetes/) on `/data/fault`.

Chaos Mesh overlays the volume with FUSE (`toda`); the canary's `fs.writeFileSync` calls fail naturally and `pvc_canary_write_success` drops to 0.

**Reset**:

```bash
make demo-io-reset
```

Optional latency injection (writes succeed but are slow):

```bash
make demo-io-latency
make demo-io-reset
```

### Scenario C - Inode exhaustion

```bash
make demo-inodes
```

**Expected**: `PVCInodesExhausted` when inode usage exceeds 85% (may take 1–2 minutes).

### Scenario D - PVC not bound

```bash
make demo-unbound
```

**Expected**: `PVCNotBound` after 2 minutes for `pvc-unbound` (requests 10Gi, no PV available).

### Reset faults

```bash
make demo-reset
```

Removes injected faults (app + IOChaos) and deletes the unbound PVC. Alerts should resolve in Alertmanager and appear as `resolved` in the webapp.

## Alert reference

| Alert | Severity | Metric / condition | User action |
|-------|----------|-------------------|-------------|
| `PVCNotBound` | warning | PVC phase ≠ Bound for 2m | Check PV availability, StorageClass, capacity |
| `PVCLost` | critical | PVC phase = Lost | Investigate PV deletion; data may be gone |
| `PVCFillingUp` | warning | Used > 80% for 1m | Expand PVC or clean up data |
| `PVCAlmostFull` | critical | Used > 95% | Urgent cleanup or expansion |
| `PVCInodesExhausted` | warning | Inodes > 85% for 2m | Remove small files or expand |
| `PVFailed` | critical | PV phase = Failed | Check storage backend |
| `PVReleased` | warning | PV Released for 5m | Reclaim or delete PV |
| `PVCWriteCanaryFailed` | critical | Canary write = 0 for 1m | Check mount permissions, I/O errors |
| `NodeDiskIOSaturation` | warning | I/O time > 90% for 2m | Investigate disk performance |

## Limitations

- **Read-only I/O demo (`demo-readonly`)** uses a simulated fault flag that sets `pvc_canary_write_success` to 0. Use **`demo-io-fault`** for real write failures via Chaos Mesh IOChaos.
- **Chaos Mesh IOChaos** requires the `chaos-mesh` namespace (installed by `make deploy-chaos`). Experiments target `/data/fault` only; avoid running on `pvc-healthy`.
- **Apple Silicon (M1/M2/M3)**: `make deploy` uses a native arm64 kind cluster (reliable). IOChaos/toda is amd64-only - use `make demo-readonly` for I/O failure demos, or experimentally `make cluster-up-amd64` + `make build-amd64 load deploy-chaos` (needs ~8GiB Docker RAM; control plane may fail under emulation). If `cluster-up` fails with control-plane timeouts after trying amd64, run `docker pull kindest/node:v1.35.0` (no `--platform`) to restore the arm64 node image tag.
- **Inode demo on `pvc-fault`**: `vol3` is a tmpfs mount with only 2048 inodes (see `make setup-storage-paths`) so inode flooding can exceed 85%. Other PVCs share the node root filesystem with millions of inodes.
- **Hardware disk I/O error metrics** (`node_disk_read_errors_total`) are not included - standard node-exporter on kind does not expose them. Production clusters should use SMART/NVMe textfile collectors or application-level probes like the canary metric here.
- **kind local volumes** use node-local paths under `/var/local-pvc/` (created at cluster bootstrap). They behave differently from cloud CSI volumes (EBS, PD, etc.). Binding and lifecycle alerts translate well; backend-specific failures do not.
- **Canary writes** detect permission and I/O failures from a pod's perspective, which is often more actionable than node-level disk counters for stateful workloads.

## Project layout

```
├── kind-config.yaml          # kind cluster with volume mounts
├── storage/                  # kind: StorageClass, local PVs, PVCs
│   └── remote/               # dynamic PVCs for real clusters
├── helm/                     # kube-prometheus-stack + chaos-mesh values
├── monitoring/               # Alert rules, ServiceMonitor, Grafana dashboard
├── chaos/                    # IOChaos experiments (write fault, latency)
├── fault-injector/           # TypeScript fault injection webapp
├── Makefile                  # Automation targets
└── pvc-monitoring-poc-plan.md
```

## Teardown

**kind:**

```bash
make teardown
```

Removes Helm releases, Kubernetes resources, the kind cluster, and `/tmp/pvc-poc` host directories.

**Remote cluster:**

```bash
make teardown-remote STORAGE_CLASS=standard
```

Removes workloads only; does not delete the cluster.

## PromQL cheatsheet

```promql
# Non-bound PVCs
kube_persistentvolumeclaim_status_phase{phase!="Bound"} == 1

# Fill percentage
kubelet_volume_stats_used_bytes / kubelet_volume_stats_capacity_bytes

# Inode percentage
kubelet_volume_stats_inodes_used / kubelet_volume_stats_inodes

# Canary write health
pvc_canary_write_success

# I/O saturation
rate(node_disk_io_time_seconds_total[2m])
```

## License

This project is licensed under the [MIT License](LICENSE).
