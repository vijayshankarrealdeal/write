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
  const [loading, setLoading] = useState(true);

  useEffect(() => {
    Promise.all([api.overview(), api.userActivity(14)])
      .then(([s, a]) => {
        setStats(s);
        setActivity(a);
      })
      .finally(() => setLoading(false));
  }, []);

  if (loading) return <Loading />;

  return (
    <div className="p-8">
      <PageHeader
        title="Dashboard Overview"
        description="Real-time metrics for InkSpaceX"
      />

      <div className="grid grid-cols-1 sm:grid-cols-2 lg:grid-cols-4 gap-4 mb-8">
        <StatCard
          label="Total Users"
          value={stats.total_users}
          sub={`+${stats.new_users_week} this week`}
          icon={Users}
          color="indigo"
        />
        <StatCard
          label="Writings"
          value={stats.total_writings}
          icon={FileText}
          color="blue"
        />
        <StatCard
          label="Published Posts"
          value={stats.total_feed_items}
          icon={Rss}
          color="green"
        />
        <StatCard
          label="Visits Today"
          value={stats.visits_today}
          sub={`${stats.visits_week} this week`}
          icon={Eye}
          color="purple"
        />
      </div>

      <div className="grid grid-cols-1 sm:grid-cols-2 lg:grid-cols-4 gap-4 mb-8">
        <StatCard
          label="Unresolved Crashes"
          value={stats.unresolved_crashes}
          sub={`${stats.total_crashes} total`}
          icon={Bug}
          color="red"
        />
        <StatCard
          label="Errors Today"
          value={stats.errors_today}
          icon={AlertTriangle}
          color="amber"
        />
        <StatCard
          label="New Users (7d)"
          value={stats.new_users_week}
          icon={UserPlus}
          color="green"
        />
        <StatCard
          label="Weekly Visits"
          value={stats.visits_week}
          icon={TrendingUp}
          color="blue"
        />
      </div>

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

function Loading() {
  return (
    <div className="p-8 flex items-center justify-center h-full">
      <div className="animate-pulse text-gray-500">Loading dashboard...</div>
    </div>
  );
}
