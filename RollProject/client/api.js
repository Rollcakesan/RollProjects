export async function api(path, options = {}) {
  const method = String(options.method || "GET").toUpperCase();
  const headers = { ...(options.body ? { "Content-Type": "application/json" } : {}), ...(options.headers || {}) };
  if (!['GET', 'HEAD'].includes(method)) headers["X-RollProject-Request"] = "1";
  const response = await fetch(path, { ...options, method, headers, credentials: "same-origin" });
  const data = response.status === 204 ? null : await response.json().catch(() => ({}));
  if (!response.ok) { const error = new Error(data?.message || "通信に失敗しました。"); error.code = data?.error; error.status = response.status; throw error; }
  return data;
}
