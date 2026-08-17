import * as fs from "fs";
import * as path from "path";
import client from "prom-client";
import { PvcMount } from "./mounts";

const NAMESPACE = process.env.POD_NAMESPACE || "default";
const CANARY_INTERVAL_MS = 15000;

const canaryGauge = new client.Gauge({
  name: "pvc_canary_write_success",
  help: "Whether the last canary write to the PVC succeeded (1=ok, 0=fail)",
  labelNames: ["pvc", "namespace"],
});

const activeFaultsGauge = new client.Gauge({
  name: "pvc_active_faults",
  help: "Number of active injected faults per PVC",
  labelNames: ["pvc"],
});

const activeFaults = new Map<string, Set<string>>();

export function registerMetrics(): void {
  client.register.registerMetric(canaryGauge);
  client.register.registerMetric(activeFaultsGauge);
}

export function getMetricsRegistry(): client.Registry {
  return client.register;
}

export function recordFault(pvc: string, faultType: string): void {
  if (!activeFaults.has(pvc)) {
    activeFaults.set(pvc, new Set());
  }
  activeFaults.get(pvc)!.add(faultType);
  activeFaultsGauge.set({ pvc }, activeFaults.get(pvc)!.size);
}

export function clearFaults(pvc: string): void {
  activeFaults.delete(pvc);
  activeFaultsGauge.set({ pvc }, 0);
}

export function removeFault(pvc: string, faultType: string): void {
  const faults = activeFaults.get(pvc);
  if (!faults) {
    return;
  }
  faults.delete(faultType);
  if (faults.size === 0) {
    activeFaults.delete(pvc);
  }
  activeFaultsGauge.set({ pvc }, activeFaults.get(pvc)?.size || 0);
}

export function getActiveFaults(pvc: string): string[] {
  return Array.from(activeFaults.get(pvc) || []);
}

function runCanaryWrite(mount: PvcMount): number {
  if (getActiveFaults(mount.pvc).includes("read-only")) {
    return 0;
  }

  const canaryPath = path.join(mount.mountPath, `canary-${Date.now()}.tmp`);
  try {
    const ts = String(Date.now());
    fs.writeFileSync(canaryPath, ts, "utf8");
    const readBack = fs.readFileSync(canaryPath, "utf8");
    fs.unlinkSync(canaryPath);
    return readBack === ts ? 1 : 0;
  } catch {
    try {
      if (fs.existsSync(canaryPath)) {
        fs.unlinkSync(canaryPath);
      }
    } catch {
      // ignore cleanup errors
    }
    return 0;
  }
}

export function startCanaryLoop(mounts: PvcMount[]): void {
  const tick = () => {
    for (const mount of mounts) {
      const success = runCanaryWrite(mount);
      canaryGauge.set({ pvc: mount.pvc, namespace: NAMESPACE }, success);
    }
  };

  tick();
  setInterval(tick, CANARY_INTERVAL_MS);
}

export function getDiskUsage(
  mountPath: string
): { usedPercent: number; usedBytes: number; totalBytes: number } {
  try {
    const stats = fs.statfsSync(mountPath);
    const totalBytes = stats.bsize * stats.blocks;
    const freeBytes = stats.bsize * stats.bavail;
    const usedBytes = totalBytes - freeBytes;
    const usedPercent = totalBytes > 0 ? (usedBytes / totalBytes) * 100 : 0;
    return { usedPercent, usedBytes, totalBytes };
  } catch {
    return { usedPercent: 0, usedBytes: 0, totalBytes: 0 };
  }
}
