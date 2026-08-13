export async function api(path, options = {}) {
  const headers = { ...options.headers };
  if (options.body) headers["Content-Type"] = "application/json";
  if (options.auth && !["GET", "HEAD"].includes(options.method || "GET")) headers["X-URLPort-Request"] = "1";
  const { auth: _auth, ...fetchOptions } = options;
  const response = await fetch(path, { credentials: "same-origin", ...fetchOptions, headers });
  if (response.status === 204) return {};
  const payload = await response.json().catch(() => ({}));
  if (!response.ok) {
    if (response.status === 401 && options.auth) window.dispatchEvent(new Event("port:unauthorized"));
    const error = new Error(payload.message || "通信に失敗しました。");
    error.code = payload.error || "REQUEST_FAILED";
    error.status = response.status;
    throw error;
  }
  return payload;
}
