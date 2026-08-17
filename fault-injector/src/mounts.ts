export interface PvcMount {
  name: string;
  pvc: string;
  mountPath: string;
  capacityBytes: number;
}

function parseCapacity(name: string): number {
  const defaults: Record<string, number> = {
    healthy: 100 * 1024 * 1024,
    filling: 10 * 1024 * 1024,
    fault: 100 * 1024 * 1024,
  };
  return defaults[name] || 100 * 1024 * 1024;
}

export function parseMounts(envValue: string | undefined): PvcMount[] {
  if (!envValue) {
    throw new Error("PVC_MOUNTS environment variable is required");
  }

  return envValue.split(",").map((entry) => {
    const [name, mountPath] = entry.trim().split(":");
    if (!name || !mountPath) {
      throw new Error(`Invalid PVC_MOUNTS entry: ${entry}`);
    }
    return {
      name,
      pvc: `pvc-${name}`,
      mountPath,
      capacityBytes: parseCapacity(name),
    };
  });
}

export function findMountByPvc(mounts: PvcMount[], pvc: string): PvcMount | undefined {
  return mounts.find((m) => m.pvc === pvc);
}

export function findMountByPath(mounts: PvcMount[], mountPath: string): PvcMount | undefined {
  return mounts.find((m) => m.mountPath === mountPath);
}

export function getCapacityForPvc(pvc: string): number {
  const capacities: Record<string, number> = {
    "pvc-healthy": 100 * 1024 * 1024,
    "pvc-filling": 10 * 1024 * 1024,
    "pvc-fault": 100 * 1024 * 1024,
  };
  return capacities[pvc] || 100 * 1024 * 1024;
}
