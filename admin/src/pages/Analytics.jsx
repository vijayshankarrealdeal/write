import { useEffect, useState } from "react";
import {
  BarChart,
  Bar,
  XAxis,
  YAxis,
  CartesianGrid,
  Tooltip,
  ResponsiveContainer,
  LineChart,
  Line,
} from "recharts";
import { BarChart3, TrendingUp } from "lucide-react";
import { api } from "../api/client";
import PageHeader from "../components/PageHeader";

export default function Analytics() {
  const [topPages, setTopPages] = useState([]);
  const [visits, setVisits] = useState([]);
  const [days, setDays] = useState(7);
  const [loading, setLoading] = useState(true);

  useEffect(() => {
    setLoading(true);
    Promise.all([api.topPages(days), api.pageVisits(days)])
      .then(([tp, pv]) => {
        setTopPages(tp);
        setVisits(pv);
      })
      .finally(() => setLoading(false));
  }, [days]);

  if (loading) return <div className="p-8 animate-pulse text-gray-500">Loading...</div>;

  // Group visits by day for line chart
  const byDay = {};
  for (const v of visits) {
    const day = v.day?.split("T")[0];
    if (!byDay[day]) byDay[day] = { day, visits: 0 };
    byDay[day].visits += v.visits;
  }
  const dailyVisits = Object.values(byDay).sort((a, b) => a.day.localeCompare(b.day));

  return (
    <div className="p-8">
      <PageHeader title="Analytics" description="Page visit analytics and trends">
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

      <div className="grid grid-cols-1 lg:grid-cols-2 gap-6 mb-6">
        {/* Total visits trend */}
        <div className="bg-gray-900 border border-gray-800 rounded-xl p-6">
          <h3 className="text-sm font-medium text-gray-400 flex items-center gap-2 mb-4">
            <TrendingUp className="w-4 h-4" /> Visit Trend
          </h3>
          <ResponsiveContainer width="100%" height={280}>
            <LineChart data={dailyVisits}>
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
              />
              <Line type="monotone" dataKey="visits" stroke="#818cf8" strokeWidth={2} dot={{ r: 4 }} />
            </LineChart>
          </ResponsiveContainer>
        </div>

        {/* Top pages */}
        <div className="bg-gray-900 border border-gray-800 rounded-xl p-6">
          <h3 className="text-sm font-medium text-gray-400 flex items-center gap-2 mb-4">
            <BarChart3 className="w-4 h-4" /> Most Visited Pages
          </h3>
          <ResponsiveContainer width="100%" height={280}>
            <BarChart data={topPages} layout="vertical">
              <CartesianGrid strokeDasharray="3 3" stroke="#374151" />
              <XAxis type="number" stroke="#6b7280" fontSize={12} />
              <YAxis
                type="category"
                dataKey="page"
                stroke="#6b7280"
                fontSize={11}
                width={150}
                tickFormatter={(v) => (v.length > 25 ? v.slice(0, 25) + "..." : v)}
              />
              <Tooltip
                contentStyle={{ backgroundColor: "#1f2937", border: "1px solid #374151", borderRadius: 8 }}
              />
              <Bar dataKey="visits" fill="#34d399" radius={[0, 4, 4, 0]} />
            </BarChart>
          </ResponsiveContainer>
        </div>
      </div>

      {/* Detailed table */}
      <div className="bg-gray-900 border border-gray-800 rounded-xl overflow-hidden">
        <div className="px-5 py-4 border-b border-gray-800">
          <h3 className="text-sm font-medium text-gray-400">Page Visit Details</h3>
        </div>
        <table className="w-full text-sm">
          <thead>
            <tr className="border-b border-gray-800">
              <th className="text-left px-5 py-3 text-xs font-medium text-gray-400 uppercase">#</th>
              <th className="text-left px-5 py-3 text-xs font-medium text-gray-400 uppercase">Page</th>
              <th className="text-right px-5 py-3 text-xs font-medium text-gray-400 uppercase">Visits</th>
            </tr>
          </thead>
          <tbody>
            {topPages.map((p, i) => (
              <tr key={p.page} className="border-b border-gray-800/50 hover:bg-gray-800/30">
                <td className="px-5 py-3 text-gray-500">{i + 1}</td>
                <td className="px-5 py-3 font-mono text-indigo-300">{p.page}</td>
                <td className="px-5 py-3 text-right font-medium">{p.visits}</td>
              </tr>
            ))}
            {topPages.length === 0 && (
              <tr>
                <td colSpan={3} className="px-5 py-8 text-center text-gray-500">
                  No visit data yet
                </td>
              </tr>
            )}
          </tbody>
        </table>
      </div>
    </div>
  );
}
