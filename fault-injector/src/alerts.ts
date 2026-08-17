export interface AlertmanagerAlert {
  status: string;
  labels: Record<string, string>;
  annotations: Record<string, string>;
  startsAt: string;
  endsAt: string;
  generatorURL?: string;
  fingerprint?: string;
}

export interface AlertmanagerWebhookPayload {
  version: string;
  groupKey: string;
  status: string;
  receiver: string;
  groupLabels: Record<string, string>;
  commonLabels: Record<string, string>;
  commonAnnotations: Record<string, string>;
  externalURL: string;
  alerts: AlertmanagerAlert[];
}

export interface StoredAlert {
  id: string;
  receivedAt: string;
  status: string;
  alertname: string;
  severity: string;
  summary: string;
  description: string;
  labels: Record<string, string>;
  groupKey: string;
}

export interface GroupedAlert {
  groupKey: string;
  alertname: string;
  severity: string;
  status: string;
  summary: string;
  description: string;
  receivedAt: string;
  count: number;
  webhooks: StoredAlert[];
}

const MAX_HISTORY = 200;
const history: StoredAlert[] = [];
let nextId = 1;

function groupKeyForAlert(alert: AlertmanagerAlert): string {
  const alertname = alert.labels.alertname || "unknown";
  const severity = alert.labels.severity || "unknown";
  const pvc = alert.labels.persistentvolumeclaim || alert.labels.pvc || "";
  const namespace = alert.labels.namespace || "";
  return [alertname, severity, pvc, namespace].join("|");
}

export function ingestWebhook(payload: AlertmanagerWebhookPayload): void {
  const receivedAt = new Date().toISOString();

  for (const alert of payload.alerts || []) {
    history.unshift({
      id: String(nextId++),
      receivedAt,
      status: alert.status,
      alertname: alert.labels.alertname || "unknown",
      severity: alert.labels.severity || "unknown",
      summary: alert.annotations.summary || "",
      description: alert.annotations.description || "",
      labels: alert.labels,
      groupKey: groupKeyForAlert(alert),
    });
  }

  if (history.length > MAX_HISTORY) {
    history.length = MAX_HISTORY;
  }
}

export function getAlertHistory(): StoredAlert[] {
  return [...history];
}

export function getGroupedAlertHistory(): GroupedAlert[] {
  const groups = new Map<string, StoredAlert[]>();

  for (const alert of history) {
    const existing = groups.get(alert.groupKey);
    if (existing) {
      existing.push(alert);
    } else {
      groups.set(alert.groupKey, [alert]);
    }
  }

  const grouped: GroupedAlert[] = [];
  for (const [groupKey, webhooks] of groups) {
    webhooks.sort((a, b) => b.receivedAt.localeCompare(a.receivedAt));
    const latest = webhooks[0];
    grouped.push({
      groupKey,
      alertname: latest.alertname,
      severity: latest.severity,
      status: latest.status,
      summary: latest.summary,
      description: latest.description,
      receivedAt: latest.receivedAt,
      count: webhooks.length,
      webhooks,
    });
  }

  grouped.sort((a, b) => b.receivedAt.localeCompare(a.receivedAt));
  return grouped;
}
