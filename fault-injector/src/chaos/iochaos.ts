import { K8sApiError, getClusterCredentials, hasApiCredentials, k8sRequest } from "../k8s/client";

const POC_LABEL = "app.kubernetes.io/part-of";
const POC_LABEL_VALUE = "pvc-monitoring-poc";
const FAULT_MOUNT = "/data/fault";

export interface ChaosExperiment {
  name: string;
  action: string;
  duration?: string;
}

export interface ChaosMeshStatus {
  inCluster: boolean;
  available: boolean;
  crdInstalled: boolean;
  rbacOk: boolean;
  experiments: ChaosExperiment[];
  reason?: string;
  credentials?: ReturnType<typeof getClusterCredentials>;
}

interface IOChaosList {
  items?: Array<{
    metadata?: { name?: string };
    spec?: { action?: string; duration?: string };
  }>;
}

function namespace(): string {
  return process.env.POD_NAMESPACE || "default";
}

function ioChaosBasePath(): string {
  return `/apis/chaos-mesh.org/v1alpha1/namespaces/${namespace()}/iochaos`;
}

function buildIOChaos(
  name: string,
  action: "fault" | "latency",
  extra: Record<string, unknown>
): Record<string, unknown> {
  return {
    apiVersion: "chaos-mesh.org/v1alpha1",
    kind: "IOChaos",
    metadata: {
      name,
      namespace: namespace(),
      labels: { [POC_LABEL]: POC_LABEL_VALUE },
    },
    spec: {
      action,
      mode: "all",
      selector: {
        labelSelectors: { app: "fault-injector" },
        namespaces: [namespace()],
      },
      containerNames: ["fault-injector"],
      volumePath: FAULT_MOUNT,
      path: `${FAULT_MOUNT}/**/*`,
      methods: ["WRITE"],
      percent: 100,
      duration: "1h",
      ...extra,
    },
  };
}

export async function getChaosMeshStatus(): Promise<ChaosMeshStatus> {
  const credentials = getClusterCredentials();

  if (!credentials.inCluster) {
    return {
      inCluster: false,
      available: false,
      crdInstalled: false,
      rbacOk: false,
      experiments: [],
      credentials,
      reason:
        "Not running inside Kubernetes - Chaos Mesh controls require the app to run as a pod in the cluster",
    };
  }

  if (!hasApiCredentials()) {
    return {
      inCluster: true,
      available: false,
      crdInstalled: false,
      rbacOk: false,
      experiments: [],
      credentials,
      reason:
        "Service account token not mounted in this pod - run: make deploy-app-rbac && make deploy-app-remote (needs automountServiceAccountToken)",
    };
  }

  try {
    const list = await k8sRequest<IOChaosList>(
      "GET",
      `${ioChaosBasePath()}?labelSelector=${encodeURIComponent(`${POC_LABEL}=${POC_LABEL_VALUE}`)}`
    );
    const experiments: ChaosExperiment[] = (list.items ?? []).map((item) => ({
      name: item.metadata?.name ?? "unknown",
      action: item.spec?.action ?? "unknown",
      duration: item.spec?.duration,
    }));
    return {
      inCluster: true,
      available: true,
      crdInstalled: true,
      rbacOk: true,
      experiments,
      credentials,
    };
  } catch (err) {
    if (err instanceof K8sApiError) {
      if (err.statusCode === 404) {
        return {
          inCluster: true,
          available: false,
          crdInstalled: false,
          rbacOk: true,
          experiments: [],
          credentials,
          reason: "Chaos Mesh IOChaos CRD not found - install with: make deploy-chaos",
        };
      }
      if (err.statusCode === 403) {
        return {
          inCluster: true,
          available: false,
          crdInstalled: true,
          rbacOk: false,
          experiments: [],
          credentials,
          reason: "Missing RBAC to manage IOChaos - apply fault-injector/k8s/rbac.yaml",
        };
      }
      return {
        inCluster: true,
        available: false,
        crdInstalled: false,
        rbacOk: false,
        experiments: [],
        credentials,
        reason: err.message,
      };
    }
    throw err;
  }
}

async function deleteExperiment(name: string): Promise<void> {
  try {
    await k8sRequest("DELETE", `${ioChaosBasePath()}/${name}`);
  } catch (err) {
    if (err instanceof K8sApiError && err.statusCode === 404) {
      return;
    }
    throw err;
  }
}

export async function applyWriteFaultExperiment(): Promise<void> {
  await deleteExperiment("pvc-fault-write-latency");
  await k8sRequest(
    "POST",
    ioChaosBasePath(),
    buildIOChaos("pvc-fault-write-eio", "fault", { errno: 5 })
  );
}

export async function applyWriteLatencyExperiment(): Promise<void> {
  await deleteExperiment("pvc-fault-write-eio");
  await k8sRequest(
    "POST",
    ioChaosBasePath(),
    buildIOChaos("pvc-fault-write-latency", "latency", { delay: "2s" })
  );
}

export async function resetIOChaosExperiments(): Promise<string[]> {
  const removed: string[] = [];
  for (const name of ["pvc-fault-write-eio", "pvc-fault-write-latency"]) {
    try {
      await deleteExperiment(name);
      removed.push(name);
    } catch {
      // ignore individual delete failures
    }
  }
  return removed;
}

export function isExperimentActive(status: ChaosMeshStatus, name: string): boolean {
  return status.experiments.some((e) => e.name === name);
}
