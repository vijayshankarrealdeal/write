const BASE = "/api/admin";

function getToken() {
  return localStorage.getItem("admin_token") || "";
}

async function request(path, options = {}) {
  const token = getToken();
  const sep = path.includes("?") ? "&" : "?";
  const url = `${BASE}${path}${sep}token=${encodeURIComponent(token)}`;
  const res = await fetch(url, {
    headers: { "Content-Type": "application/json", ...options.headers },
    ...options,
  });
  if (res.status === 401) {
    localStorage.removeItem("admin_token");
    window.location.href = "/admin/login";
    throw new Error("Session expired");
  }
  if (!res.ok) {
    const text = await res.text();
    throw new Error(`${res.status}: ${text}`);
  }
  return res.json();
}

export const api = {
  // Auth
  login: async (username, password) => {
    const res = await fetch(`${BASE}/login`, {
      method: "POST",
      headers: { "Content-Type": "application/json" },
      body: JSON.stringify({ username, password }),
    });
    if (!res.ok) {
      const data = await res.json().catch(() => ({}));
      throw new Error(data.detail || "Login failed");
    }
    const data = await res.json();
    localStorage.setItem("admin_token", data.token);
    return data;
  },

  logout: () => {
    localStorage.removeItem("admin_token");
    window.location.href = "/admin/login";
  },

  isAuthenticated: () => !!localStorage.getItem("admin_token"),

  // Overview
  overview: () => request("/overview"),
  health: () => request("/health"),

  // Database
  tables: () => request("/database/tables"),
  tableSchema: (name) => request(`/database/tables/${name}/schema`),
  tableData: (name, page = 1, perPage = 50) =>
    request(`/database/tables/${name}/data?page=${page}&per_page=${perPage}`),
  updateRow: (name, pk, updates) =>
    request(`/database/tables/${name}/rows/${encodeURIComponent(pk)}`, {
      method: "PATCH",
      body: JSON.stringify({ updates }),
    }),
  deleteRow: (name, pk) =>
    request(`/database/tables/${name}/rows/${encodeURIComponent(pk)}`, {
      method: "DELETE",
    }),
  clearTable: (name, { cascade = false, restartIdentity = true } = {}) =>
    request(
      `/database/tables/${name}/clear?cascade=${cascade}&restart_identity=${restartIdentity}`,
      { method: "POST" }
    ),

  // Storage
  buckets: () => request("/storage/buckets"),
  browse: (bucket, prefix = "") =>
    request(`/storage/browse/${bucket}?prefix=${encodeURIComponent(prefix)}`),
  storageStats: () => request("/storage/stats"),
  deleteObject: (bucket, key) =>
    request(`/storage/objects/${bucket}?key=${encodeURIComponent(key)}`, {
      method: "DELETE",
    }),
  clearBucket: (bucket, prefix = "") =>
    request(`/storage/clear/${bucket}?prefix=${encodeURIComponent(prefix)}`, {
      method: "POST",
    }),

  // Analytics
  pageVisits: (days = 7) => request(`/analytics/page-visits?days=${days}`),
  topPages: (days = 7) => request(`/analytics/top-pages?days=${days}`),
  userActivity: (days = 7) => request(`/analytics/user-activity?days=${days}`),
  deviceBreakdown: (days = 30) => request(`/analytics/devices?days=${days}`),
  funnel: (days = 30) => request(`/analytics/funnel?days=${days}`),

  // Writings (read-only)
  writings: (page = 1, perPage = 25, search = "") => {
    const params = new URLSearchParams({ page, per_page: perPage });
    if (search) params.set("search", search);
    return request(`/writings?${params}`);
  },
  writing: (id) => request(`/writings/${id}`),

  // Users (admin-managed)
  users: (page = 1, perPage = 25, search = "") => {
    const params = new URLSearchParams({ page, per_page: perPage });
    if (search) params.set("search", search);
    return request(`/users?${params}`);
  },
  createUser: (payload) =>
    request(`/users`, { method: "POST", body: JSON.stringify(payload) }),
  resetUserPassword: (id, password) =>
    request(`/users/${id}/reset-password`, {
      method: "POST",
      body: JSON.stringify({ password }),
    }),

  // Crashes
  crashes: (page = 1, perPage = 20, resolved = null) => {
    let q = `/crashes?page=${page}&per_page=${perPage}`;
    if (resolved !== null) q += `&resolved=${resolved}`;
    return request(q);
  },
  resolveCrash: (id) => request(`/crashes/${id}/resolve`, { method: "PATCH" }),

  // Reports (UGC moderation queue)
  reports: (page = 1, perPage = 25, filters = {}) => {
    const params = new URLSearchParams({ page, per_page: perPage });
    if (filters.status) params.set("status", filters.status);
    if (filters.target_type) params.set("target_type", filters.target_type);
    if (filters.source) params.set("source", filters.source);
    return request(`/reports?${params}`);
  },
  reportStats: () => request("/reports/stats"),
  updateReport: (id, status) =>
    request(`/reports/${id}`, {
      method: "PATCH",
      body: JSON.stringify({ status }),
    }),

  // Feedback (user-submitted product feedback)
  feedback: (page = 1, perPage = 25, filters = {}) => {
    const params = new URLSearchParams({ page, per_page: perPage });
    if (filters.status) params.set("status", filters.status);
    if (filters.category) params.set("category", filters.category);
    return request(`/feedback?${params}`);
  },
  feedbackStats: () => request("/feedback/stats"),
  updateFeedback: (id, status) =>
    request(`/feedback/${id}`, {
      method: "PATCH",
      body: JSON.stringify({ status }),
    }),

  // Logs
  logs: (page = 1, perPage = 50, filters = {}) => {
    const params = new URLSearchParams({ page, per_page: perPage });
    if (filters.level) params.set("level", filters.level);
    if (filters.source) params.set("source", filters.source);
    if (filters.env) params.set("env", filters.env);
    if (filters.search) params.set("search", filters.search);
    return request(`/logs?${params}`);
  },
  logStats: (days = 7, filters = {}) => {
    const params = new URLSearchParams({ days });
    if (filters.source) params.set("source", filters.source);
    if (filters.env) params.set("env", filters.env);
    return request(`/logs/stats?${params}`);
  },

  // Dictionary
  dictionaryStats: () => request("/dictionary/stats"),
  dictionarySubmissions: (page = 1, perPage = 50, status = "pending") => {
    const params = new URLSearchParams({ page, per_page: perPage });
    if (status) params.set("status", status);
    return request(`/dictionary/submissions?${params}`);
  },
  dictionaryWords: (page = 1, perPage = 100, search = "") => {
    const params = new URLSearchParams({ page, per_page: perPage });
    if (search) params.set("search", search);
    return request(`/dictionary/words?${params}`);
  },
  dictionaryMerge: () =>
    request(`/dictionary/merge`, { method: "POST" }),
  dictionaryDeleteWord: (word, language = "en") =>
    request(
      `/dictionary/words/${encodeURIComponent(word)}?language=${encodeURIComponent(language)}`,
      { method: "DELETE" }
    ),
};
