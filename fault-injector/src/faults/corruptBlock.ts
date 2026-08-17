import * as fs from "fs";
import * as path from "path";
import { recordFault } from "../metrics";

export interface CorruptBlockRequest {
  pvc: string;
  mountPath: string;
  targetFile: string;
}

export function corruptBlock(req: CorruptBlockRequest): { targetPath: string } {
  const targetPath = path.join(req.mountPath, req.targetFile);
  if (!fs.existsSync(targetPath)) {
    fs.writeFileSync(targetPath, "initial-data-for-corruption-test");
  }

  const fileSize = fs.statSync(targetPath).size || 1024;
  const offset = Math.floor(Math.random() * Math.max(fileSize - 512, 1));
  const block = Buffer.alloc(512);
  for (let i = 0; i < block.length; i++) {
    block[i] = Math.floor(Math.random() * 256);
  }

  const fd = fs.openSync(targetPath, "r+");
  try {
    fs.writeSync(fd, block, 0, block.length, offset);
  } finally {
    fs.closeSync(fd);
  }

  recordFault(req.pvc, "corrupt");
  return { targetPath };
}

export function resetCorrupt(mountPath: string, targetFile?: string): void {
  if (targetFile) {
    const targetPath = path.join(mountPath, targetFile);
    if (fs.existsSync(targetPath)) {
      fs.unlinkSync(targetPath);
    }
  }
}
