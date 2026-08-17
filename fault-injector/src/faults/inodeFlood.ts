import * as fs from "fs";
import * as path from "path";
import { recordFault } from "../metrics";

export interface InodeFloodRequest {
  pvc: string;
  mountPath: string;
  targetPercent?: number;
  fileCount?: number;
}

export function getInodeUsage(mountPath: string): {
  usedPercent: number;
  usedInodes: number;
  totalInodes: number;
} {
  const stats = fs.statfsSync(mountPath);
  const totalInodes = stats.files;
  const freeInodes = stats.ffree;
  const usedInodes = totalInodes - freeInodes;
  const usedPercent = totalInodes > 0 ? (usedInodes / totalInodes) * 100 : 0;
  return { usedPercent, usedInodes, totalInodes };
}

export async function inodeFlood(
  req: InodeFloodRequest
): Promise<{ filesCreated: number; inodeUsedPercent: number; usedInodes: number; totalInodes: number }> {
  const targetPercent = req.targetPercent ?? 86;
  const floodDir = path.join(req.mountPath, ".fault-inodes");
  await fs.promises.mkdir(floodDir, { recursive: true });
  recordFault(req.pvc, "inode-flood");

  let filesCreated = 0;
  let index = 0;

  if (req.fileCount && req.fileCount > 0) {
    for (let i = 0; i < req.fileCount; i++) {
      try {
        await fs.promises.writeFile(path.join(floodDir, `inode-${index++}.tmp`), "");
        filesCreated++;
      } catch {
        break;
      }
    }
  } else {
    while (getInodeUsage(req.mountPath).usedPercent < targetPercent) {
      try {
        await fs.promises.writeFile(path.join(floodDir, `inode-${index++}.tmp`), "");
        filesCreated++;
      } catch {
        break;
      }
    }
  }

  const usage = getInodeUsage(req.mountPath);
  return {
    filesCreated,
    inodeUsedPercent: Math.round(usage.usedPercent * 100) / 100,
    usedInodes: usage.usedInodes,
    totalInodes: usage.totalInodes,
  };
}

export function resetInodeFlood(mountPath: string): void {
  const floodDir = path.join(mountPath, ".fault-inodes");
  if (fs.existsSync(floodDir)) {
    fs.rmSync(floodDir, { recursive: true, force: true });
  }
}
