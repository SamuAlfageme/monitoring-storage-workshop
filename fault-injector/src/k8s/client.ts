import * as fs from "fs";
import * as https from "https";

const TOKEN_PATH = "/var/run/secrets/kubernetes.io/serviceaccount/token";
const CA_PATH = "/var/run/secrets/kubernetes.io/serviceaccount/ca.crt";

export interface ClusterCredentials {
  inCluster: boolean;
  tokenMounted: boolean;
  caMounted: boolean;
  serviceHost?: string;
  namespace?: string;
}

/** True when the pod has Kubernetes-injected env (runs in-cluster). */
export function isInCluster(): boolean {
  return Boolean(process.env.KUBERNETES_SERVICE_HOST);
}

export function getClusterCredentials(): ClusterCredentials {
  const tokenMounted = fs.existsSync(TOKEN_PATH);
  const caMounted = fs.existsSync(CA_PATH);
  let namespace: string | undefined;
  const nsPath = "/var/run/secrets/kubernetes.io/serviceaccount/namespace";
  if (fs.existsSync(nsPath)) {
    namespace = fs.readFileSync(nsPath, "utf8").trim();
  }
  return {
    inCluster: isInCluster(),
    tokenMounted,
    caMounted,
    serviceHost: process.env.KUBERNETES_SERVICE_HOST,
    namespace,
  };
}

export function hasApiCredentials(): boolean {
  const creds = getClusterCredentials();
  return creds.inCluster && creds.tokenMounted && creds.caMounted;
}

export class K8sApiError extends Error {
  constructor(
    message: string,
    readonly statusCode: number,
    readonly body?: unknown
  ) {
    super(message);
    this.name = "K8sApiError";
  }
}

export async function k8sRequest<T = unknown>(
  method: string,
  apiPath: string,
  body?: unknown
): Promise<T> {
  if (!hasApiCredentials()) {
    const creds = getClusterCredentials();
    if (creds.inCluster && !creds.tokenMounted) {
      throw new K8sApiError(
        "Service account token not mounted - redeploy with automountServiceAccountToken or run make deploy-app-rbac",
        0
      );
    }
    throw new K8sApiError("Not running inside a Kubernetes cluster", 0);
  }

  const host = process.env.KUBERNETES_SERVICE_HOST!;
  const port = process.env.KUBERNETES_SERVICE_PORT || "443";
  const token = fs.readFileSync(TOKEN_PATH, "utf8").trim();
  const ca = fs.readFileSync(CA_PATH);
  const payload = body !== undefined ? JSON.stringify(body) : undefined;

  return new Promise((resolve, reject) => {
    const req = https.request(
      {
        hostname: host,
        port: Number(port),
        path: apiPath,
        method,
        ca,
        headers: {
          Authorization: `Bearer ${token}`,
          Accept: "application/json",
          ...(payload
            ? {
                "Content-Type": "application/json",
                "Content-Length": Buffer.byteLength(payload),
              }
            : {}),
        },
      },
      (res) => {
        let chunks = "";
        res.on("data", (chunk) => {
          chunks += chunk;
        });
        res.on("end", () => {
          let parsed: unknown = null;
          if (chunks) {
            try {
              parsed = JSON.parse(chunks);
            } catch {
              parsed = chunks;
            }
          }
          const status = res.statusCode ?? 0;
          if (status >= 200 && status < 300) {
            resolve(parsed as T);
            return;
          }
          const reason =
            typeof parsed === "object" &&
            parsed !== null &&
            "message" in parsed &&
            typeof (parsed as { message: string }).message === "string"
              ? (parsed as { message: string }).message
              : `HTTP ${status}`;
          reject(new K8sApiError(reason, status, parsed));
        });
      }
    );
    req.on("error", reject);
    if (payload) {
      req.write(payload);
    }
    req.end();
  });
}
