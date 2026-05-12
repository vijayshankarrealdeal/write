import { useEffect, useMemo, useState } from "react";
import {
  ShieldCheck,
  Database,
  Bug,
  BarChart3,
  UserPlus,
  KeyRound,
  Search,
  CheckCircle,
  AlertCircle,
  ChevronDown,
  ChevronUp,
  Smartphone,
  TrendingUp,
  Globe,
} from "lucide-react";
import {
  BarChart,
  Bar,
  PieChart,
  Pie,
  Cell,
  LineChart,
  Line,
  XAxis,
  YAxis,
  CartesianGrid,
  Tooltip,
  Legend,
  ResponsiveContainer,
} from "recharts";
import { api } from "../api/client";
import PageHeader from "../components/PageHeader";
import Pagination from "../components/Pagination";

const TABS = [
  { id: "auth", label: "Auth", icon: ShieldCheck },
  { id: "db", label: "Database", icon: Database },
  { id: "crashes", label: "App Crashes", icon: Bug },
  { id: "analytics", label: "Analytics", icon: BarChart3 },
];

export default function Console() {
  const [tab, setTab] = useState("auth");

  return (
    <div className="p-8">
      <PageHeader
        title="Admin Console"
        description="One-stop view: users, database, crashes, analytics"
      />

      <div className="flex bg-gray-900 border border-gray-800 rounded-xl p-1 mb-6 w-fit">
        {TABS.map(({ id, label, icon: Icon }) => (
          <button
            key={id}
            onClick={() => setTab(id)}
            className={`flex items-center gap-2 px-4 py-2 rounded-lg text-sm font-medium transition-colors ${
              tab === id
                ? "bg-indigo-500/15 text-indigo-300"
                : "text-gray-400 hover:text-gray-200"
            }`}
          >
            <Icon className="w-4 h-4" />
            {label}
          </button>
        ))}
      </div>

      {tab === "auth" && <AuthTab />}
      {tab === "db" && <DatabaseTab />}
      {tab === "crashes" && <CrashesTab />}
      {tab === "analytics" && <AnalyticsTab />}
    </div>
  );
}

/* ──────────────────────────────────────────────────────────── Auth tab */

function AuthTab() {
  const [data, setData] = useState(null);
  const [page, setPage] = useState(1);
  const [search, setSearch] = useState("");
  const [loading, setLoading] = useState(true);
  const [showCreate, setShowCreate] = useState(false);
  const [resetFor, setResetFor] = useState(null);

  const load = (p = page, s = search) => {
    setLoading(true);
    api.users(p, 25, s).then(setData).finally(() => setLoading(false));
  };

  useEffect(() => {
    load(1, search);
  }, [search]);

  return (
    <div className="space-y-4">
      <div className="flex flex-wrap items-center justify-between gap-3">
        <div className="relative flex-1 min-w-64 max-w-md">
          <Search className="w-4 h-4 absolute left-3 top-1/2 -translate-y-1/2 text-gray-500" />
          <input
            type="text"
            placeholder="Search by email or name"
            value={search}
            onChange={(e) => {
              setSearch(e.target.value);
              setPage(1);
            }}
            className="w-full bg-gray-900 border border-gray-800 rounded-lg pl-9 pr-3 py-2 text-sm text-gray-200 placeholder-gray-500 focus:outline-none focus:border-indigo-500"
          />
        </div>
        <button
          onClick={() => setShowCreate(true)}
          className="flex items-center gap-2 bg-indigo-600 hover:bg-indigo-500 text-white text-sm font-medium rounded-lg px-4 py-2"
        >
          <UserPlus className="w-4 h-4" /> Register user
        </button>
      </div>

      <div className="bg-gray-900 border border-gray-800 rounded-xl overflow-hidden">
        {loading ? (
          <div className="p-8 animate-pulse text-gray-500">Loading users…</div>
        ) : (
          <div className="overflow-x-auto">
            <table className="w-full text-sm">
              <thead>
                <tr className="border-b border-gray-800 text-xs text-gray-400 uppercase">
                  <th className="text-left px-5 py-3">Email</th>
                  <th className="text-left px-5 py-3">Name</th>
                  <th className="text-left px-5 py-3">Auth</th>
                  <th className="text-left px-5 py-3">Onboarded</th>
                  <th className="text-left px-5 py-3">Joined</th>
                  <th className="text-right px-5 py-3">Actions</th>
                </tr>
              </thead>
              <tbody>
                {data?.users?.map((u) => (
                  <tr key={u.id} className="border-b border-gray-800/50 hover:bg-gray-800/30">
                    <td className="px-5 py-3 text-gray-200 font-mono text-xs">{u.email}</td>
                    <td className="px-5 py-3 text-gray-300">{u.name || "—"}</td>
                    <td className="px-5 py-3">
                      <span className={`text-xs px-2 py-0.5 rounded ${
                        u.has_password
                          ? "bg-emerald-500/10 text-emerald-300"
                          : "bg-amber-500/10 text-amber-300"
                      }`}>
                        {u.has_password ? "password" : "oauth-only"}
                      </span>
                    </td>
                    <td className="px-5 py-3">
                      {u.onboarding_complete ? (
                        <CheckCircle className="w-4 h-4 text-emerald-400" />
                      ) : (
                        <span className="text-gray-500">—</span>
                      )}
                    </td>
                    <td className="px-5 py-3 text-gray-400 text-xs">
                      {u.created_at ? new Date(u.created_at).toLocaleDateString() : "—"}
                    </td>
                    <td className="px-5 py-3 text-right">
                      <button
                        onClick={() => setResetFor(u)}
                        className="inline-flex items-center gap-1 text-xs text-indigo-300 hover:text-indigo-200"
                      >
                        <KeyRound className="w-3.5 h-3.5" /> Reset password
                      </button>
                    </td>
                  </tr>
                ))}
                {data?.users?.length === 0 && (
                  <tr>
                    <td colSpan={6} className="px-5 py-10 text-center text-gray-500">
                      No users found
                    </td>
                  </tr>
                )}
              </tbody>
            </table>
          </div>
        )}
      </div>

      <Pagination
        page={page}
        totalPages={data?.total_pages || 0}
        onPageChange={(p) => {
          setPage(p);
          load(p, search);
        }}
      />

      {showCreate && (
        <CreateUserModal
          onClose={() => setShowCreate(false)}
          onCreated={() => {
            setShowCreate(false);
            load(1, search);
          }}
        />
      )}

      {resetFor && (
        <ResetPasswordModal
          user={resetFor}
          onClose={() => setResetFor(null)}
          onDone={() => setResetFor(null)}
        />
      )}
    </div>
  );
}

function CreateUserModal({ onClose, onCreated }) {
  const [email, setEmail] = useState("");
  const [name, setName] = useState("");
  const [password, setPassword] = useState("");
  const [error, setError] = useState("");
  const [busy, setBusy] = useState(false);

  const submit = async (e) => {
    e.preventDefault();
    setError("");
    setBusy(true);
    try {
      await api.createUser({ email, name, password });
      onCreated();
    } catch (err) {
      setError(err.message || "Failed to create user");
    } finally {
      setBusy(false);
    }
  };

  return (
    <Modal onClose={onClose} title="Register new user">
      <form onSubmit={submit} className="space-y-4">
        {error && (
          <div className="flex items-center gap-2 text-sm text-red-400 bg-red-500/10 border border-red-500/20 rounded-lg px-3 py-2">
            <AlertCircle className="w-4 h-4" />
            {error}
          </div>
        )}
        <Field label="Email">
          <input
            type="email"
            required
            autoFocus
            value={email}
            onChange={(e) => setEmail(e.target.value)}
            className={inputCls}
          />
        </Field>
        <Field label="Name (optional)">
          <input
            type="text"
            value={name}
            onChange={(e) => setName(e.target.value)}
            className={inputCls}
          />
        </Field>
        <Field label="Password (≥ 8 chars)">
          <input
            type="password"
            required
            minLength={8}
            value={password}
            onChange={(e) => setPassword(e.target.value)}
            className={inputCls}
          />
        </Field>
        <div className="flex justify-end gap-2 pt-2">
          <button
            type="button"
            onClick={onClose}
            className="px-4 py-2 rounded-lg text-sm text-gray-300 hover:bg-gray-800"
          >
            Cancel
          </button>
          <button
            type="submit"
            disabled={busy}
            className="px-4 py-2 rounded-lg text-sm font-medium bg-indigo-600 hover:bg-indigo-500 disabled:opacity-50 text-white"
          >
            {busy ? "Creating…" : "Create user"}
          </button>
        </div>
      </form>
    </Modal>
  );
}

function ResetPasswordModal({ user, onClose, onDone }) {
  const [password, setPassword] = useState("");
  const [error, setError] = useState("");
  const [busy, setBusy] = useState(false);
  const [done, setDone] = useState(false);

  const submit = async (e) => {
    e.preventDefault();
    setError("");
    setBusy(true);
    try {
      await api.resetUserPassword(user.id, password);
      setDone(true);
      setTimeout(onDone, 1200);
    } catch (err) {
      setError(err.message || "Failed");
    } finally {
      setBusy(false);
    }
  };

  return (
    <Modal onClose={onClose} title={`Reset password — ${user.email}`}>
      {done ? (
        <div className="flex items-center gap-2 text-emerald-300 text-sm">
          <CheckCircle className="w-4 h-4" /> Password updated
        </div>
      ) : (
        <form onSubmit={submit} className="space-y-4">
          {error && (
            <div className="text-sm text-red-400 bg-red-500/10 border border-red-500/20 rounded-lg px-3 py-2">
              {error}
            </div>
          )}
          <Field label="New password (≥ 8 chars)">
            <input
              type="password"
              required
              minLength={8}
              autoFocus
              value={password}
              onChange={(e) => setPassword(e.target.value)}
              className={inputCls}
            />
          </Field>
          <div className="flex justify-end gap-2 pt-2">
            <button
              type="button"
              onClick={onClose}
              className="px-4 py-2 rounded-lg text-sm text-gray-300 hover:bg-gray-800"
            >
              Cancel
            </button>
            <button
              type="submit"
              disabled={busy}
              className="px-4 py-2 rounded-lg text-sm font-medium bg-indigo-600 hover:bg-indigo-500 disabled:opacity-50 text-white"
            >
              {busy ? "Saving…" : "Update password"}
            </button>
          </div>
        </form>
      )}
    </Modal>
  );
}

/* ─────────────────────────────────────────────────────── Database tab */

function DatabaseTab() {
  const [tables, setTables] = useState([]);
  const [active, setActive] = useState(null);
  const [data, setData] = useState(null);
  const [page, setPage] = useState(1);
  const [loading, setLoading] = useState(true);
  const [drillLoading, setDrillLoading] = useState(false);

  useEffect(() => {
    api.tables().then((rows) => {
      setTables(rows);
      const usersRow = rows.find((r) => r.name === "users") || rows[0];
      if (usersRow) openTable(usersRow.name);
    }).finally(() => setLoading(false));
  }, []);

  const openTable = (name, p = 1) => {
    setActive(name);
    setPage(p);
    setDrillLoading(true);
    api.tableData(name, p).then(setData).finally(() => setDrillLoading(false));
  };

  if (loading) return <div className="animate-pulse text-gray-500">Loading tables…</div>;

  return (
    <div className="grid grid-cols-12 gap-4">
      <aside className="col-span-12 md:col-span-3 bg-gray-900 border border-gray-800 rounded-xl p-2 max-h-[70vh] overflow-y-auto">
        {tables.map((t) => (
          <button
            key={t.name}
            onClick={() => openTable(t.name)}
            className={`w-full text-left px-3 py-2 rounded-lg text-sm flex items-center justify-between ${
              active === t.name
                ? "bg-indigo-500/10 text-indigo-300"
                : "text-gray-300 hover:bg-gray-800"
            }`}
          >
            <span className="font-mono">{t.name}</span>
            <span className="text-xs text-gray-500">{t.row_count}</span>
          </button>
        ))}
      </aside>

      <section className="col-span-12 md:col-span-9 bg-gray-900 border border-gray-800 rounded-xl overflow-hidden">
        <div className="px-5 py-3 border-b border-gray-800 flex items-center justify-between">
          <div>
            <div className="text-sm font-semibold">{active || "—"}</div>
            <div className="text-xs text-gray-500">
              {data?.total ?? 0} rows · page {page} of {data?.total_pages || 0}
            </div>
          </div>
        </div>
        {drillLoading ? (
          <div className="p-8 animate-pulse text-gray-500">Loading rows…</div>
        ) : (
          <>
            <div className="overflow-x-auto max-h-[60vh]">
              <table className="w-full text-sm">
                <thead className="sticky top-0 bg-gray-900">
                  <tr className="border-b border-gray-800">
                    {data?.columns?.map((col) => (
                      <th
                        key={col}
                        className="text-left px-4 py-2.5 text-xs font-medium text-gray-400 uppercase tracking-wider whitespace-nowrap"
                      >
                        {col}
                      </th>
                    ))}
                  </tr>
                </thead>
                <tbody>
                  {data?.rows?.map((row, i) => (
                    <tr key={i} className="border-b border-gray-800/50 hover:bg-gray-800/30">
                      {data.columns.map((col) => (
                        <td
                          key={col}
                          className="px-4 py-2 whitespace-nowrap max-w-xs truncate font-mono text-xs"
                          title={row[col] == null ? "null" : String(row[col])}
                        >
                          {row[col] == null ? (
                            <span className="text-gray-600 italic">null</span>
                          ) : typeof row[col] === "boolean" ? (
                            <span className={row[col] ? "text-emerald-400" : "text-red-400"}>
                              {String(row[col])}
                            </span>
                          ) : (
                            String(row[col])
                          )}
                        </td>
                      ))}
                    </tr>
                  ))}
                  {data?.rows?.length === 0 && (
                    <tr>
                      <td colSpan={data.columns.length} className="px-4 py-8 text-center text-gray-500">
                        No data
                      </td>
                    </tr>
                  )}
                </tbody>
              </table>
            </div>
            <div className="px-4 pb-4">
              <Pagination
                page={page}
                totalPages={data?.total_pages || 0}
                onPageChange={(p) => openTable(active, p)}
              />
            </div>
          </>
        )}
      </section>
    </div>
  );
}

/* ─────────────────────────────────────────────────────── Crashes tab */

function CrashesTab() {
  const [data, setData] = useState(null);
  const [page, setPage] = useState(1);
  const [filter, setFilter] = useState(null);
  const [expanded, setExpanded] = useState(null);
  const [loading, setLoading] = useState(true);

  const load = (p = page, f = filter) => {
    setLoading(true);
    api.crashes(p, 20, f).then(setData).finally(() => setLoading(false));
  };

  useEffect(() => {
    load(1, filter);
  }, [filter]);

  const handleResolve = async (id) => {
    await api.resolveCrash(id);
    load();
  };

  return (
    <div className="space-y-4">
      <div className="flex bg-gray-900 border border-gray-800 rounded-lg p-1 w-fit">
        {[
          { label: "All", value: null },
          { label: "Unresolved", value: false },
          { label: "Resolved", value: true },
        ].map((opt) => (
          <button
            key={String(opt.value)}
            onClick={() => {
              setFilter(opt.value);
              setPage(1);
            }}
            className={`px-3 py-1.5 rounded-md text-sm font-medium ${
              filter === opt.value ? "bg-gray-700 text-white" : "text-gray-400 hover:text-gray-200"
            }`}
          >
            {opt.label}
          </button>
        ))}
      </div>

      {loading ? (
        <div className="animate-pulse text-gray-500">Loading crashes…</div>
      ) : (
        <>
          <div className="space-y-3">
            {data?.crashes?.map((crash) => (
              <div key={crash.id} className="bg-gray-900 border border-gray-800 rounded-xl overflow-hidden">
                <div
                  className="flex items-center gap-4 px-5 py-4 cursor-pointer hover:bg-gray-800/30"
                  onClick={() => setExpanded(expanded === crash.id ? null : crash.id)}
                >
                  {crash.resolved ? (
                    <CheckCircle className="w-5 h-5 text-emerald-400 flex-shrink-0" />
                  ) : (
                    <AlertCircle className="w-5 h-5 text-red-400 flex-shrink-0" />
                  )}
                  <div className="flex-1 min-w-0">
                    <div className="font-medium truncate">{crash.error_type}</div>
                    <div className="text-sm text-gray-400 truncate">{crash.error_message}</div>
                  </div>
                  <div className="text-xs text-gray-500 flex-shrink-0">
                    {new Date(crash.created_at).toLocaleString()}
                  </div>
                  <div className="flex items-center gap-2 flex-shrink-0">
                    {crash.platform && (
                      <span className="text-xs bg-gray-800 px-2 py-1 rounded">{crash.platform}</span>
                    )}
                    {expanded === crash.id ? (
                      <ChevronUp className="w-4 h-4 text-gray-500" />
                    ) : (
                      <ChevronDown className="w-4 h-4 text-gray-500" />
                    )}
                  </div>
                </div>
                {expanded === crash.id && (
                  <div className="px-5 pb-5 border-t border-gray-800">
                    <div className="grid grid-cols-2 sm:grid-cols-4 gap-4 mt-4 mb-4">
                      <Detail label="Device" value={crash.device} />
                      <Detail label="Platform" value={crash.platform} />
                      <Detail label="App Version" value={crash.app_version} />
                      <Detail label="Page" value={crash.page} />
                    </div>
                    {crash.stack_trace && (
                      <div className="mt-3">
                        <div className="text-xs text-gray-400 mb-2">Stack Trace</div>
                        <pre className="bg-gray-950 border border-gray-800 rounded-lg p-4 text-xs text-gray-300 overflow-x-auto max-h-64 overflow-y-auto">
                          {crash.stack_trace}
                        </pre>
                      </div>
                    )}
                    {!crash.resolved && (
                      <button
                        onClick={(e) => {
                          e.stopPropagation();
                          handleResolve(crash.id);
                        }}
                        className="mt-4 px-4 py-2 bg-emerald-500/10 text-emerald-400 rounded-lg text-sm font-medium hover:bg-emerald-500/20"
                      >
                        Mark as Resolved
                      </button>
                    )}
                  </div>
                )}
              </div>
            ))}
            {data?.crashes?.length === 0 && (
              <div className="text-center py-12 text-gray-500 bg-gray-900 border border-gray-800 rounded-xl">
                <Bug className="w-8 h-8 mx-auto mb-3 text-gray-600" />
                No crash reports
              </div>
            )}
          </div>
          <Pagination
            page={page}
            totalPages={Math.ceil((data?.total || 0) / 20)}
            onPageChange={(p) => {
              setPage(p);
              load(p, filter);
            }}
          />
        </>
      )}
    </div>
  );
}

/* ─────────────────────────────────────────────────────── Analytics tab */

const PIE_COLORS = ["#818cf8", "#34d399", "#f472b6", "#fbbf24", "#60a5fa", "#a78bfa", "#fb7185"];

function AnalyticsTab() {
  const [days, setDays] = useState(30);
  const [breakdown, setBreakdown] = useState(null);
  const [activity, setActivity] = useState(null);
  const [topPages, setTopPages] = useState([]);
  const [loading, setLoading] = useState(true);

  useEffect(() => {
    setLoading(true);
    Promise.all([
      api.deviceBreakdown(days),
      api.userActivity(days),
      api.topPages(days),
    ])
      .then(([b, a, tp]) => {
        setBreakdown(b);
        setActivity(a);
        setTopPages(tp);
      })
      .finally(() => setLoading(false));
  }, [days]);

  const cumulativeSignups = useMemo(() => {
    if (!breakdown?.signups_per_day) return [];
    let total = 0;
    return breakdown.signups_per_day.map((d) => {
      total += d.count;
      return { day: d.day, new_users: d.count, cumulative: total };
    });
  }, [breakdown]);

  if (loading) return <div className="animate-pulse text-gray-500">Loading analytics…</div>;

  const totalReach =
    breakdown?.platforms?.reduce((s, p) => s + p.count, 0) || 0;

  return (
    <div className="space-y-6">
      <div className="flex items-center justify-end">
        <select
          value={days}
          onChange={(e) => setDays(Number(e.target.value))}
          className="bg-gray-900 border border-gray-800 rounded-lg px-3 py-2 text-sm text-gray-200"
        >
          <option value={7}>Last 7 days</option>
          <option value={14}>Last 14 days</option>
          <option value={30}>Last 30 days</option>
          <option value={90}>Last 90 days</option>
        </select>
      </div>

      <div className="grid grid-cols-1 lg:grid-cols-2 gap-6">
        <Card icon={Smartphone} title="Platform breakdown">
          {breakdown?.platforms?.length ? (
            <ResponsiveContainer width="100%" height={260}>
              <PieChart>
                <Pie
                  data={breakdown.platforms}
                  dataKey="count"
                  nameKey="label"
                  innerRadius={50}
                  outerRadius={90}
                  paddingAngle={2}
                >
                  {breakdown.platforms.map((_, i) => (
                    <Cell key={i} fill={PIE_COLORS[i % PIE_COLORS.length]} />
                  ))}
                </Pie>
                <Tooltip
                  contentStyle={{ backgroundColor: "#1f2937", border: "1px solid #374151", borderRadius: 8 }}
                />
                <Legend wrapperStyle={{ fontSize: 12 }} />
              </PieChart>
            </ResponsiveContainer>
          ) : (
            <Empty label="No platform data yet" />
          )}
          <div className="text-xs text-gray-500 mt-2">
            {totalReach.toLocaleString()} total visits across {breakdown?.platforms?.length || 0} platforms
          </div>
        </Card>

        <Card icon={BarChart3} title="Top devices">
          {breakdown?.devices?.length ? (
            <ResponsiveContainer width="100%" height={260}>
              <BarChart data={breakdown.devices} layout="vertical">
                <CartesianGrid strokeDasharray="3 3" stroke="#374151" />
                <XAxis type="number" stroke="#6b7280" fontSize={12} />
                <YAxis
                  type="category"
                  dataKey="label"
                  stroke="#6b7280"
                  fontSize={11}
                  width={140}
                  tickFormatter={(v) => (v.length > 22 ? v.slice(0, 22) + "…" : v)}
                />
                <Tooltip
                  contentStyle={{ backgroundColor: "#1f2937", border: "1px solid #374151", borderRadius: 8 }}
                />
                <Bar dataKey="count" fill="#34d399" radius={[0, 4, 4, 0]} />
              </BarChart>
            </ResponsiveContainer>
          ) : (
            <Empty label="No device data yet" />
          )}
        </Card>

        <Card icon={TrendingUp} title="New user signups">
          {cumulativeSignups.length ? (
            <ResponsiveContainer width="100%" height={260}>
              <LineChart data={cumulativeSignups}>
                <CartesianGrid strokeDasharray="3 3" stroke="#374151" />
                <XAxis
                  dataKey="day"
                  stroke="#6b7280"
                  fontSize={12}
                  tickFormatter={(v) =>
                    new Date(v).toLocaleDateString("en", { month: "short", day: "numeric" })
                  }
                />
                <YAxis stroke="#6b7280" fontSize={12} />
                <Tooltip
                  contentStyle={{ backgroundColor: "#1f2937", border: "1px solid #374151", borderRadius: 8 }}
                  labelFormatter={(v) => new Date(v).toLocaleDateString()}
                />
                <Legend wrapperStyle={{ fontSize: 12 }} />
                <Line type="monotone" dataKey="new_users" stroke="#818cf8" strokeWidth={2} dot={{ r: 3 }} name="New" />
                <Line type="monotone" dataKey="cumulative" stroke="#34d399" strokeWidth={2} dot={{ r: 3 }} name="Cumulative" />
              </LineChart>
            </ResponsiveContainer>
          ) : (
            <Empty label="No signups in this window" />
          )}
        </Card>

        <Card icon={BarChart3} title="Most visited app pages">
          {topPages?.length ? (
            <ResponsiveContainer width="100%" height={260}>
              <BarChart data={topPages} layout="vertical">
                <CartesianGrid strokeDasharray="3 3" stroke="#374151" />
                <XAxis type="number" stroke="#6b7280" fontSize={12} />
                <YAxis
                  type="category"
                  dataKey="page"
                  stroke="#6b7280"
                  fontSize={11}
                  width={150}
                  tickFormatter={(v) => (v.length > 24 ? v.slice(0, 24) + "…" : v)}
                />
                <Tooltip
                  contentStyle={{ backgroundColor: "#1f2937", border: "1px solid #374151", borderRadius: 8 }}
                />
                <Bar dataKey="visits" fill="#818cf8" radius={[0, 4, 4, 0]} />
              </BarChart>
            </ResponsiveContainer>
          ) : (
            <Empty label="No page-visit data yet" />
          )}
        </Card>

        <Card icon={Globe} title="User regions">
          {breakdown?.regions?.length ? (
            <ResponsiveContainer width="100%" height={260}>
              <BarChart data={breakdown.regions} layout="vertical">
                <CartesianGrid strokeDasharray="3 3" stroke="#374151" />
                <XAxis type="number" stroke="#6b7280" fontSize={12} />
                <YAxis
                  type="category"
                  dataKey="label"
                  stroke="#6b7280"
                  fontSize={11}
                  width={80}
                />
                <Tooltip
                  contentStyle={{ backgroundColor: "#1f2937", border: "1px solid #374151", borderRadius: 8 }}
                />
                <Bar dataKey="count" fill="#f472b6" radius={[0, 4, 4, 0]} />
              </BarChart>
            </ResponsiveContainer>
          ) : (
            <Empty label="No region data yet" />
          )}
          <div className="text-xs text-gray-500 mt-2">
            Derived from request IP (country only, cached for 30 days). Not GPS, not device locale.
          </div>
        </Card>

      </div>
    </div>
  );
}

/* ──────────────────────────────────────────────────── small primitives */

function Card({ icon: Icon, title, children }) {
  return (
    <div className="bg-gray-900 border border-gray-800 rounded-xl p-5">
      <h3 className="text-sm font-medium text-gray-400 flex items-center gap-2 mb-4">
        <Icon className="w-4 h-4" /> {title}
      </h3>
      {children}
    </div>
  );
}

function Empty({ label }) {
  return (
    <div className="h-[220px] flex items-center justify-center text-sm text-gray-500 text-center px-4">
      {label}
    </div>
  );
}

function Detail({ label, value }) {
  return (
    <div>
      <div className="text-xs text-gray-500">{label}</div>
      <div className="text-sm text-gray-300">{value || "—"}</div>
    </div>
  );
}

function Modal({ title, onClose, children }) {
  return (
    <div className="fixed inset-0 z-50 flex items-center justify-center bg-black/60 p-4" onClick={onClose}>
      <div
        className="bg-gray-900 border border-gray-800 rounded-xl w-full max-w-md p-6 shadow-2xl"
        onClick={(e) => e.stopPropagation()}
      >
        <h3 className="text-lg font-semibold mb-4">{title}</h3>
        {children}
      </div>
    </div>
  );
}

function Field({ label, children }) {
  return (
    <div>
      <label className="block text-sm font-medium text-gray-300 mb-1.5">{label}</label>
      {children}
    </div>
  );
}

const inputCls =
  "w-full bg-gray-800 border border-gray-700 rounded-lg px-3 py-2 text-sm text-gray-200 placeholder-gray-500 focus:outline-none focus:border-indigo-500 focus:ring-1 focus:ring-indigo-500";
