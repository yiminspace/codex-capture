const TOKEN_KEY = 'codex-capture.session-token';
let token = '';

export function readLaunchState() {
  const hash = new URLSearchParams(location.hash.replace(/^#/, ''));
  const supplied = hash.get('token');
  try {
    token = supplied || sessionStorage.getItem(TOKEN_KEY) || '';
    if (supplied) sessionStorage.setItem(TOKEN_KEY, supplied);
  } catch { token = supplied || token; }
  const job = hash.get('job') || '';
  if (supplied) {
    hash.delete('token');
    history.replaceState(null, '', location.pathname + location.search + (hash.size ? '#' + hash.toString() : ''));
  }
  return { tokenPresent: !!token, job };
}

export function selectJobInURL(job: string) {
  const hash = new URLSearchParams();
  if (job) hash.set('job', job);
  history.replaceState(null, '', location.pathname + location.search + (job ? '#' + hash.toString() : ''));
}

export async function response(path: string, init: RequestInit = {}) {
  const res = await fetch(path, { ...init, cache: 'no-store', headers: { ...init.headers, Authorization: `Bearer ${token}` } });
  if (!res.ok) {
    let message = `请求失败（${res.status}）`;
    try {
      const body = await res.json();
      message = typeof body.error === 'string' ? body.error : body.message || message;
    } catch { /* Keep status-based error. */ }
    if (res.status === 401) message = '连接凭据已失效。请从菜单栏重新打开任务工作台。';
    throw new Error(message);
  }
  return res;
}

export async function api<T>(path: string, init: RequestInit = {}): Promise<T> {
  return (await response(path, init)).json() as Promise<T>;
}

export async function action(job: string, name: 'cancel' | 'open-chat') {
  return api(`/api/jobs/${encodeURIComponent(job)}/${name}`, { method: 'POST', headers: { 'Content-Type': 'application/json' }, body: '{}' });
}

export async function downloadDiagnostic(job: string) {
  const blob = await (await response(`/api/jobs/${encodeURIComponent(job)}/export`)).blob();
  const url = URL.createObjectURL(blob);
  const anchor = document.createElement('a'); anchor.href = url;
  anchor.download = `codex-capture-${job}-diagnostic.json`; anchor.click();
  setTimeout(() => URL.revokeObjectURL(url), 1000);
}

/** A response is useful only while it belongs to the latest requested selection. */
export class RequestGate {
  private revision = 0;
  next() { return ++this.revision; }
  current(revision: number) { return revision === this.revision; }
  invalidate() { this.revision++; }
}
