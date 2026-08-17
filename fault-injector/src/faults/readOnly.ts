import { recordFault } from "../metrics";

export interface ReadOnlyRequest {
  pvc: string;
  mountPath: string;
}

export function makeReadOnly(req: ReadOnlyRequest): void {
  // Simulated read-only fault: remounting bind mounts on kind can mark the
  // entire node filesystem read-only. For real I/O errors use Chaos Mesh IOChaos
  // (make demo-io-fault). The canary loop checks activeFaults for this path.
  recordFault(req.pvc, "read-only");
}

export function restorePermissions(_mountPath: string): void {
  // Permissions restored via clearFaults in reset handler.
}
