import { useEffect, useState } from "react";
import {
  BarChart,
  Bar,
  XAxis,
  YAxis,
  CartesianGrid,
  Tooltip,
  ResponsiveContainer,
  PieChart,
  Pie,
  Cell,
  Legend,
} from "recharts";
import { Users, UserPlus, Globe } from "lucide-react";
import { api } from "../api/client";
import PageHeader from "../components/PageHeader";

const COLORS = ["#818cf8", "#34d399", "#f59e0b", "#ef4444", "#8b5cf6"];

export default function UserActivity() {
  const [activity, setActivity] = useState(null);
  const [days, setDays] = useState(14);
  const [loading, setLoading] = useState(true);

  useEffect(() => {
    setLoading(true);
    api.userActivity(days).then(setActivity).finally(() => setLoading(false));
  }, [days]);

  if (loading) return <div className="p-8 animate-pulse text-gray-500">Loading...</div>;

  return (
    <div className="p-8">
      <PageHeader title="User Activity" description="Daily active users, registrations, and platform breakdown">
        <select
          value={days}
          onChange={(e) => setDays(Number(e.target.value))}
          className="bg-gray-800 border border-gray-700 rounded-lg px-3 py-2 text-sm text-gray-200"
        >
          <option value={7}>Last 7 days</option>
          <option value={14}>Last 14 days</option>
          <option value={30}>Last 30 days</option>
          <option value={90}>Last 90 days</option>
        </select>
      </PageHeader>

      <div className="grid grid-cols-1 lg:grid-cols-2 gap-6">
        {/* Daily active users */}
        <div className="bg-gray-900 border border-gray-800 rounded-xl p-6">
          <h3 className="text-sm font-medium text-gray-400 flex items-center gap-2 mb-4">
            <Users className="w-4 h-4" /> Daily Active Users
          </h3>
          <ResponsiveContainer width="100%" height={280}>
            <BarChart data={activity?.daily_active_users || []}>
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
              <Bar dataKey="active_users" fill="#818cf8" radius={[4, 4, 0, 0]} name="Active Users" />
              <Bar dataKey="total_visits" fill="#34d399" radius={[4, 4, 0, 0]} name="Visits" />
            </BarChart>
          </ResponsiveContainer>
        </div>

        {/* New users */}
        <div className="bg-gray-900 border border-gray-800 rounded-xl p-6">
          <h3 className="text-sm font-medium text-gray-400 flex items-center gap-2 mb-4">
            <UserPlus className="w-4 h-4" /> New Registrations
          </h3>
          <ResponsiveContainer width="100%" height={280}>
            <BarChart data={activity?.new_users || []}>
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
              <Bar dataKey="new_users" fill="#8b5cf6" radius={[4, 4, 0, 0]} name="New Users" />
            </BarChart>
          </ResponsiveContainer>
        </div>

        {/* Platform breakdown */}
        <div className="bg-gray-900 border border-gray-800 rounded-xl p-6">
          <h3 className="text-sm font-medium text-gray-400 mb-4">Platform Breakdown</h3>
          {(activity?.platforms?.length || 0) > 0 ? (
            <ResponsiveContainer width="100%" height={280}>
              <PieChart>
                <Pie
                  data={activity.platforms}
                  dataKey="count"
                  nameKey="platform"
                  cx="50%"
                  cy="50%"
                  outerRadius={100}
                  strokeWidth={2}
                  stroke="#111827"
                  label={({ platform, count }) => `${platform}: ${count}`}
                >
                  {activity.platforms.map((_, i) => (
                    <Cell key={i} fill={COLORS[i % COLORS.length]} />
                  ))}
                </Pie>
                <Tooltip
                  contentStyle={{ backgroundColor: "#1f2937", border: "1px solid #374151", borderRadius: 8 }}
                />
                <Legend />
              </PieChart>
            </ResponsiveContainer>
          ) : (
            <div className="text-center py-12 text-gray-500">No platform data available yet</div>
          )}
        </div>

        {/* Country breakdown — server-resolved from request IP on first
            authenticated call. `unknown` is the bucket for users whose
            resolution is still in flight (brand-new signup) or failed.
            Drives payment-provider routing later (Razorpay for IN,
            Stripe for the rest once it's wired). */}
        <div className="bg-gray-900 border border-gray-800 rounded-xl p-6">
          <h3 className="text-sm font-medium text-gray-400 flex items-center gap-2 mb-4">
            <Globe className="w-4 h-4" /> Countries
          </h3>
          {(activity?.countries?.length || 0) > 0 ? (
            <ResponsiveContainer width="100%" height={280}>
              <PieChart>
                <Pie
                  data={activity.countries}
                  dataKey="count"
                  nameKey="country"
                  cx="50%"
                  cy="50%"
                  outerRadius={100}
                  strokeWidth={2}
                  stroke="#111827"
                  label={({ country, count }) => `${country}: ${count}`}
                >
                  {activity.countries.map((_, i) => (
                    <Cell key={i} fill={COLORS[i % COLORS.length]} />
                  ))}
                </Pie>
                <Tooltip
                  contentStyle={{ backgroundColor: "#1f2937", border: "1px solid #374151", borderRadius: 8 }}
                />
                <Legend />
              </PieChart>
            </ResponsiveContainer>
          ) : (
            <div className="text-center py-12 text-gray-500">No country data available yet</div>
          )}
        </div>
      </div>
    </div>
  );
}
