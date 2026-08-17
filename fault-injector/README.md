# Fault Injector API

REST API for injecting storage faults and receiving Alertmanager webhooks.

## Endpoints

| Method | Path | Description |
|--------|------|-------------|
| GET | `/health` | Liveness probe |
| GET | `/status` | All mounted PVCs, usage, active faults |
| GET | `/metrics` | Prometheus metrics (includes `pvc_canary_write_success`) |
| POST | `/fault/fill-disk` | Write data until target fill percentage |
| POST | `/fault/read-only` | Simulate read-only I/O failure (canary returns 0) |
| POST | `/fault/inode-flood` | Create many empty files |
| POST | `/fault/corrupt` | Write random bytes to a file |
| GET | `/chaos/status` | Detect Chaos Mesh / list active IOChaos experiments |
| POST | `/chaos/io-fault` | Apply IOChaos write EIO on `/data/fault` |
| POST | `/chaos/io-latency` | Apply IOChaos write latency on `/data/fault` |
| POST | `/chaos/reset` | Delete POC IOChaos experiments |
| DELETE | `/fault/reset/:pvc` | Remove injected faults (also clears IOChaos on `pvc-fault`) |
| POST | `/alerts` | Alertmanager webhook receiver |
| GET | `/alerts/history` | JSON history of received alerts |

## Request examples

```bash
curl -X POST http://localhost:8080/fault/fill-disk \
  -H 'Content-Type: application/json' \
  -d '{"pvc":"pvc-filling","mountPath":"/data/filling","targetPercent":92}'

curl -X POST http://localhost:8080/fault/read-only \
  -H 'Content-Type: application/json' \
  -d '{"pvc":"pvc-fault","mountPath":"/data/fault"}'

curl -X DELETE http://localhost:8080/fault/reset/pvc-fault

# Chaos Mesh (in-cluster only, requires make deploy-chaos + RBAC)
curl http://localhost:8080/chaos/status
curl -X POST http://localhost:8080/chaos/io-fault
curl -X POST http://localhost:8080/chaos/reset
```

## Chaos Mesh UI

When the app runs **inside the cluster** and Chaos Mesh is installed (`make deploy-chaos`), the web UI shows a **Chaos Mesh IOChaos** panel with buttons equivalent to `make demo-io-fault`, `make demo-io-latency`, and `make demo-io-reset`.

Discovery calls the Kubernetes API (IOChaos CRD) using the pod ServiceAccount - apply `fault-injector/k8s/rbac.yaml` via `make deploy-app`.

## Environment variables

| Variable | Description |
|----------|-------------|
| `PVC_MOUNTS` | Comma-separated `name:mountPath` pairs |
| `POD_NAMESPACE` | Namespace for metric labels (default: `default`) |
| `PORT` | HTTP port (default: `8080`) |
