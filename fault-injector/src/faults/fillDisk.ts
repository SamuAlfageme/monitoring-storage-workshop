import * as fs from "fs";
import * as path from "path";
import { getDiskUsage, recordFault, removeFault } from "../metrics";

export interface FillDiskRequest {
  pvc: string;
  mountPath: string;
  targetPercent: number;
}

export async function fillDisk(req: FillDiskRequest): Promise<{ bytesWritten: number; usedPercent: number }> {
  const { pvc, mountPath, targetPercent } = req;
  const current = getDiskUsage(mountPath);
  if (current.usedPercent >= targetPercent) {
    throw new Error(`${pvc} is already at ${current.usedPercent.toFixed(1)}% (target ${targetPercent}%)`);
  }

  const fillDir = path.join(mountPath, ".fault-fill");
  await fs.promises.mkdir(fillDir, { recursive: true });

  recordFault(pvc, "fill-disk");

  const chunk = Buffer.alloc(256 * 1024, "x");
  const targetFile = path.join(fillDir, "fill.bin");
  let bytesWritten = fs.existsSync(targetFile) ? fs.statSync(targetFile).size : 0;

  while (getDiskUsage(mountPath).usedPercent < targetPercent) {
    await fs.promises.appendFile(targetFile, chunk);
    bytesWritten += chunk.length;
  }

  const { usedPercent } = getDiskUsage(mountPath);
  return { bytesWritten, usedPercent };
}

export function resetFillDisk(mountPath: string, pvc?: string): void {
  const fillDir = path.join(mountPath, ".fault-fill");
  if (fs.existsSync(fillDir)) {
    fs.rmSync(fillDir, { recursive: true, force: true });
  }
  if (pvc) {
    removeFault(pvc, "fill-disk");
  }
}
