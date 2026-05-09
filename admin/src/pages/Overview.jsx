import { useEffect, useState } from "react";
import {
  Users,
  FileText,
  Rss,
  Bug,
  Eye,
  AlertTriangle,
  UserPlus,
  TrendingUp,
  CheckCircle2,
  XCircle,
  MinusCircle,
} from "lucide-react";
import {
  AreaChart,
  Area,
  XAxis,
  YAxis,
  CartesianGrid,
  Tooltip,
  ResponsiveContainer,
} from "recharts";
import { api } from "../api/client";
import StatCard from "../components/StatCard";
import PageHeader from "../components/PageHeader";

export default function Overview() {
  const [stats, setStats] = useState(null);
  const [activity, setActivity] = useState(null);
  const [health, setHealth] = useState(null);
  const [error, setError] = useState(null);
  const [loading, setLoading] = useState(true);

  useEffect(() => {
    // Health is checked live on every mount — a stale "OK" here would
    // defeat the point, so we don't memoise it. Each call swallows its
    // own failure so one bad endpoint doesn't blank the whole dashboard.
    Promise.all([
      api.overview().catch((e) => { setError(e?.message || String(e)); return null; }),
      api.userActivity(14).catch(() => null),
      api.health().catch(() => null),
    ])
      .then(([s, a, h]) => {
        setStats(s);
        setActivity(a);
        setHealth(h);
      })
      .finally(() => setLoading(false));
  }, []);

  if (loading) return <Loading />;

  const s = stats || {};
  const dash = (v) => (v == null ? "—" : v);

  return (
    <div className="p-8">
      <PageHeader
        title="Dashboard Overview"
        description="Real-time metrics for InkSpaceX"
      />

      {error && (
        <div className="mb-6 rounded-lg border border-red-900/60 bg-red-950/40 px-4 py-3 text-sm text-red-300">
          Some stats failed to load: {error}
        </div>
      )}

      <div className="grid grid-cols-1 sm:grid-cols-2 lg:grid-cols-4 gap-4 mb-8">
        <StatCard
          label="Total Users"
          value={dash(s.total_users)}
          sub={s.new_users_week != null ? `+${s.new_users_week} this week` : undefined}
          icon={Users}
          color="indigo"
        />
        <StatCard
          label="Writings"
          value={dash(s.total_writings)}
          icon={FileText}
          color="blue"
        />
        <StatCard
          label="Published Posts"
          value={dash(s.total_feed_items)}
          icon={Rss}
          color="green"
        />
        <StatCard
          label="Visits Today"
          value={dash(s.visits_today)}
          sub={s.visits_week != null ? `${s.visits_week} this week` : undefined}
          icon={Eye}
          color="purple"
        />
      </div>

      <div className="grid grid-cols-1 sm:grid-cols-2 lg:grid-cols-4 gap-4 mb-8">
        <StatCard
          label="Unresolved Crashes"
          value={dash(s.unresolved_crashes)}
          sub={s.total_crashes != null ? `${s.total_crashes} total` : undefined}
          icon={Bug}
          color="red"
        />
        <StatCard
          label="Errors Today"
          value={dash(s.errors_today)}
          icon={AlertTriangle}
          color="amber"
        />
        <StatCard
          label="New Users (7d)"
          value={dash(s.new_users_week)}
          icon={UserPlus}
          color="green"
        />
        <StatCard
          label="Weekly Visits"
          value={dash(s.visits_week)}
          icon={TrendingUp}
          color="blue"
        />
      </div>

      <ServiceHealth data={health} />

      {/* Activity chart */}
      {activity?.daily_active_users?.length > 0 && (
        <div className="bg-gray-900 border border-gray-800 rounded-xl p-6">
          <h2 className="text-lg font-semibold mb-4">Daily Active Users & Visits</h2>
          <ResponsiveContainer width="100%" height={300}>
            <AreaChart data={activity.daily_active_users}>
              <defs>
                <linearGradient id="colorUsers" x1="0" y1="0" x2="0" y2="1">
                  <stop offset="5%" stopColor="#818cf8" stopOpacity={0.3} />
                  <stop offset="95%" stopColor="#818cf8" stopOpacity={0} />
                </linearGradient>
                <linearGradient id="colorVisits" x1="0" y1="0" x2="0" y2="1">
                  <stop offset="5%" stopColor="#34d399" stopOpacity={0.3} />
                  <stop offset="95%" stopColor="#34d399" stopOpacity={0} />
                </linearGradient>
              </defs>
              <CartesianGrid strokeDasharray="3 3" stroke="#374151" />
              <XAxis
                dataKey="day"
                tickFormatter={(v) => new Date(v).toLocaleDateString("en", { month: "short", day: "numeric" })}
                stroke="#6b7280"
                fontSize={12}
              />
              <YAxis stroke="#6b7280" fontSize={12} />
              <Tooltip
                contentStyle={{ backgroundColor: "#1f2937", border: "1px solid #374151", borderRadius: 8 }}
                labelFormatter={(v) => new Date(v).toLocaleDateString()}
              />
              <Area
                type="monotone"
                dataKey="active_users"
                stroke="#818cf8"
                fillOpacity={1}
                fill="url(#colorUsers)"
                name="Active Users"
              />
              <Area
                type="monotone"
                dataKey="total_visits"
                stroke="#34d399"
                fillOpacity={1}
                fill="url(#colorVisits)"
                name="Total Visits"
              />
            </AreaChart>
          </ResponsiveContainer>
        </div>
      )}
    </div>
  );
}

function ServiceHealth({ data }) {
  if (!data) {
    return (
      <div className="bg-gray-900 border border-gray-800 rounded-xl p-6 mb-8">
        <h2 className="text-lg font-semibold mb-2">Service Health</h2>
        <p className="text-sm text-gray-500">Health check unavailable.</p>
      </div>
    );
  }
  const checkedAt = new Date(data.checked_at).toLocaleTimeString();
  return (
    <div className="bg-gray-900 border border-gray-800 rounded-xl p-6 mb-8">
      <div className="flex items-center justify-between mb-4">
        <h2 className="text-lg font-semibold">Service Health</h2>
        <span className="text-xs text-gray-500">Checked {checkedAt}</span>
      </div>
      <div className="divide-y divide-gray-800">
        {data.services.map((svc) => (
          <ServiceRow key={svc.name} svc={svc} />
        ))}
      </div>
    </div>
  );
}

function ServiceRow({ svc }) {
  const variants = {
    ok: { Icon: CheckCircle2, color: "text-emerald-400", label: "OK" },
    down: { Icon: XCircle, color: "text-red-400", label: "Down" },
    unconfigured: { Icon: MinusCircle, color: "text-gray-500", label: "Unconfigured" },
  };
  const v = variants[svc.status] || { Icon: MinusCircle, color: "text-gray-500", label: svc.status };
  const { Icon, color, label } = v;
  return (
    <div className="flex items-center justify-between py-3">
      <div className="flex items-center gap-3 min-w-0">
        <Icon className={`w-4 h-4 shrink-0 ${color}`} />
        <span className="font-medium">{svc.name}</span>
        {svc.message && (
          <span
            className="text-xs text-gray-500 truncate"
            title={svc.message}
          >
            {svc.message}
          </span>
        )}
      </div>
      <div className="flex items-center gap-4 text-sm shrink-0">
        {svc.latency_ms != null && (
          <span className="text-gray-500 tabular-nums">{svc.latency_ms} ms</span>
        )}
        <span className={`${color} font-medium`}>{label}</span>
      </div>
    </div>
  );
}

function Loading() {
  return (
    <div className="p-8 flex items-center justify-center h-full">
      <div className="animate-pulse text-gray-500">Loading dashboard...</div>
    </div>
  );
}
