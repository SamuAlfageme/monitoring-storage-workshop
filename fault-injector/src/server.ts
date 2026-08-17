import express, { Request, Response } from "express";
import * as path from "path";
import { parseMounts, findMountByPvc } from "./mounts";
import {
  registerMetrics,
  startCanaryLoop,
  getMetricsRegistry,
  getDiskUsage,
  getActiveFaults,
  clearFaults,
} from "./metrics";
import { getInodeUsage, inodeFlood, resetInodeFlood, InodeFloodRequest } from "./faults/inodeFlood";
import { ingestWebhook, getGroupedAlertHistory, AlertmanagerWebhookPayload } from "./alerts";
import { fillDisk, resetFillDisk, FillDiskRequest } from "./faults/fillDisk";
import { assertFaultNotActive } from "./faults/guard";
import { makeReadOnly, restorePermissions, ReadOnlyRequest } from "./faults/readOnly";
import { corruptBlock, resetCorrupt, CorruptBlockRequest } from "./faults/corruptBlock";
import {
  applyWriteFaultExperiment,
  applyWriteLatencyExperiment,
  getChaosMeshStatus,
  resetIOChaosExperiments,
} from "./chaos/iochaos";

const PORT = parseInt(process.env.PORT || "8080", 10);
const mounts = parseMounts(process.env.PVC_MOUNTS);

registerMetrics();
startCanaryLoop(mounts);

const app = express();
app.use(express.json());

const uiPath = path.join(__dirname, "ui");
app.use("/static", express.static(uiPath));

app.get("/", (_req: Request, res: Response) => {
  res.set("Cache-Control", "no-store");
  res.sendFile(path.join(uiPath, "index.html"));
});

app.get("/health", (_req: Request, res: Response) => {
  res.json({ status: "ok" });
});

app.get("/status", (_req: Request, res: Response) => {
  const pvcs = mounts.map((m) => {
    const usage = getDiskUsage(m.mountPath);
    const inodes = getInodeUsage(m.mountPath);
    return {
      name: m.name,
      pvc: m.pvc,
      mountPath: m.mountPath,
      usedPercent: Math.round(usage.usedPercent * 100) / 100,
      usedBytes: usage.usedBytes,
      totalBytes: usage.totalBytes,
      inodeUsedPercent: Math.round(inodes.usedPercent * 100) / 100,
      usedInodes: inodes.usedInodes,
      totalInodes: inodes.totalInodes,
      activeFaults: getActiveFaults(m.pvc),
    };
  });
  res.json({ pvcs });
});

app.get("/metrics", async (_req: Request, res: Response) => {
  res.set("Content-Type", getMetricsRegistry().contentType);
  res.end(await getMetricsRegistry().metrics());
});

app.post("/alerts", (req: Request, res: Response) => {
  ingestWebhook(req.body as AlertmanagerWebhookPayload);
  res.json({ status: "ok" });
});

app.get("/alerts/history", (_req: Request, res: Response) => {
  res.json(getGroupedAlertHistory());
});

app.get("/chaos/status", async (_req: Request, res: Response) => {
  try {
    res.json(await getChaosMeshStatus());
  } catch (err) {
    res.status(500).json({ error: String(err) });
  }
});

app.post("/chaos/io-fault", async (_req: Request, res: Response) => {
  try {
    const mount = findMountByPvc(mounts, "pvc-fault");
    if (mount) {
      restorePermissions(mount.mountPath);
      clearFaults("pvc-fault");
    }
    await applyWriteFaultExperiment();
    res.json({ status: "ok", experiment: "pvc-fault-write-eio" });
  } catch (err) {
    res.status(500).json({ error: String(err) });
  }
});

app.post("/chaos/io-latency", async (_req: Request, res: Response) => {
  try {
    const mount = findMountByPvc(mounts, "pvc-fault");
    if (mount) {
      restorePermissions(mount.mountPath);
      clearFaults("pvc-fault");
    }
    await applyWriteLatencyExperiment();
    res.json({ status: "ok", experiment: "pvc-fault-write-latency" });
  } catch (err) {
    res.status(500).json({ error: String(err) });
  }
});

app.post("/chaos/reset", async (_req: Request, res: Response) => {
  try {
    const removed = await resetIOChaosExperiments();
    res.json({ status: "ok", removed });
  } catch (err) {
    res.status(500).json({ error: String(err) });
  }
});

app.delete("/chaos/reset", async (_req: Request, res: Response) => {
  try {
    const removed = await resetIOChaosExperiments();
    res.json({ status: "ok", removed });
  } catch (err) {
    res.status(500).json({ error: String(err) });
  }
});

app.post("/fault/fill-disk", async (req: Request, res: Response) => {
  try {
    const body = req.body as FillDiskRequest;
    const result = await fillDisk(body);
    res.json({ status: "ok", ...result });
  } catch (err) {
    const status = String(err).includes("already at") ? 409 : 500;
    res.status(status).json({ error: String(err) });
  }
});

app.post("/fault/clear-fill", (req: Request, res: Response) => {
  try {
    const body = req.body as { pvc: string; mountPath: string };
    resetFillDisk(body.mountPath, body.pvc);
    const usage = getDiskUsage(body.mountPath);
    res.json({ status: "ok", ...usage });
  } catch (err) {
    res.status(500).json({ error: String(err) });
  }
});

app.post("/fault/read-only", (req: Request, res: Response) => {
  try {
    const body = req.body as ReadOnlyRequest;
    assertFaultNotActive(body.pvc, "read-only");
    makeReadOnly(body);
    res.json({ status: "ok" });
  } catch (err) {
    const status = String(err).includes("already active") ? 409 : 500;
    res.status(status).json({ error: String(err) });
  }
});

app.post("/fault/inode-flood", async (req: Request, res: Response) => {
  try {
    const body = req.body as InodeFloodRequest;
    assertFaultNotActive(body.pvc, "inode-flood");
    const result = await inodeFlood(body);
    res.json({ status: "ok", ...result });
  } catch (err) {
    const status = String(err).includes("already active") ? 409 : 500;
    res.status(status).json({ error: String(err) });
  }
});

app.post("/fault/corrupt", (req: Request, res: Response) => {
  try {
    const body = req.body as CorruptBlockRequest;
    assertFaultNotActive(body.pvc, "corrupt");
    const result = corruptBlock(body);
    res.json({ status: "ok", ...result });
  } catch (err) {
    const status = String(err).includes("already active") ? 409 : 500;
    res.status(status).json({ error: String(err) });
  }
});

app.delete("/fault/reset/:pvc", resetHandler);
app.post("/fault/reset/:pvc", resetHandler);

function resetHandler(req: Request, res: Response): void {
  const pvc = req.params.pvc;
  const mount = findMountByPvc(mounts, pvc);
  if (!mount) {
    res.status(404).json({ error: `PVC not found: ${pvc}` });
    return;
  }

  try {
    restorePermissions(mount.mountPath);
    resetFillDisk(mount.mountPath, pvc);
    resetInodeFlood(mount.mountPath);
    resetCorrupt(mount.mountPath);
    clearFaults(pvc);
    if (pvc === "pvc-fault") {
      resetIOChaosExperiments().catch(() => undefined);
    }
    res.json({ status: "ok", pvc });
  } catch (err) {
    res.status(500).json({ error: String(err) });
  }
}

app.listen(PORT, () => {
  console.log(`fault-injector listening on :${PORT}`);
  console.log(`PVC mounts: ${mounts.map((m) => m.pvc).join(", ")}`);
});
