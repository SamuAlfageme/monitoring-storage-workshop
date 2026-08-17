import { getActiveFaults } from "../metrics";

export function assertFaultNotActive(pvc: string, faultType: string): void {
  if (getActiveFaults(pvc).includes(faultType)) {
    throw new Error(`Fault "${faultType}" is already active on ${pvc}`);
  }
}
