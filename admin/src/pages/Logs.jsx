import { useEffect, useState, useCallback } from "react";
import {
  ScrollText,
  Search,
  RefreshCw,
  Info,
  AlertTriangle,
  XCircle,
} from "lucide-react";
import {
  BarChart,
  Bar,
  XAxis,
  YAxis,
  CartesianGrid,
  Tooltip,
  ResponsiveContainer,
  Legend,
} from "recharts";
import { api } from "../api/client";
import PageHeader from "../components/PageHeader";
import Pagination from "../components/Pagination";

const LEVEL_STYLES = {
  info: { icon: Info, bg: "bg-blue-500/10", text: "text-blue-400", border: "border-blue-500/20" },
  warn: { icon: AlertTriangle, bg: "bg-amber-500/10", text: "text-amber-400", border: "border-amber-500/20" },
  error: { icon: XCircle, bg: "bg-red-500/10", text: "text-red-400", border: "border-red-500/20" },
};

export default function Logs() {
  const [data, setData] = useState(null);
  const [stats, setStats] = useState([]);
  const [page, setPage] = useState(1);
  const [level, setLevel] = useState("");
  const [source, setSource] = useState("");
  const [env, setEnv] = useState("");
  const [search, setSearch] = useState("");
  const [loading, setLoading] = useState(true);

  const load = useCallback(
    (p = page) => {
      setLoading(true);
      const filters = {};
      if (level) filters.level = level;
      if (source) filters.source = source;
      if (env) filters.env = env;
      if (search) filters.search = search;
      api.logs(p, 50, filters).then(setData).finally(() => setLoading(false));
    },
    [page, level, source, env, search]
  );

  useEffect(() => {
    load(1);
    const statFilters = {};
    if (source) statFilters.source = source;
    if (env) statFilters.env = env;
    api.logStats(7, statFilters).then(setStats);
  }, [level, source, env]);

  // Group stats by day for stacked bar chart
  const chartData = {};
  for (const s of stats) {
    const day = s.day?.split("T")[0];
    if (!chartData[day]) chartData[day] = { day, info: 0, warn: 0, error: 0 };
    chartData[day][s.level] = (chartData[day][s.level] || 0) + s.count;
  }
  const chartArr = Object.values(chartData).sort((a, b) => a.day.localeCompare(b.day));

  return (
    <div className="p-8">
      <PageHeader title="Application Logs" description="Backend and frontend log viewer">
        <button
          onClick={() => load(page)}
          className="flex items-center gap-2 px-3 py-2 bg-gray-800 rounded-lg text-sm text-gray-300 hover:bg-gray-700"
        >
          <RefreshCw className="w-4 h-4" /> Refresh
        </button>
      </PageHeader>

      {/* Log stats chart */}
      {chartArr.length > 0 && (
        <div className="bg-gray-900 border border-gray-800 rounded-xl p-6 mb-6">
          <h3 className="text-sm font-medium text-gray-400 mb-4">Log Volume (7 days)</h3>
          <ResponsiveContainer width="100%" height={200}>
            <BarChart data={chartArr}>
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
              <Legend />
              <Bar dataKey="info" fill="#3b82f6" stackId="a" name="Info" />
              <Bar dataKey="warn" fill="#f59e0b" stackId="a" name="Warn" />
              <Bar dataKey="error" fill="#ef4444" stackId="a" name="Error" />
            </BarChart>
          </ResponsiveContainer>
        </div>
      )}

      {/* Filters */}
      <div className="flex flex-wrap gap-3 mb-4">
        <select
          value={level}
          onChange={(e) => { setLevel(e.target.value); setPage(1); }}
          className="bg-gray-800 border border-gray-700 rounded-lg px-3 py-2 text-sm text-gray-200"
        >
          <option value="">All Levels</option>
          <option value="info">Info</option>
          <option value="warn">Warn</option>
          <option value="error">Error</option>
        </select>
        <select
          value={source}
          onChange={(e) => { setSource(e.target.value); setPage(1); }}
          className="bg-gray-800 border border-gray-700 rounded-lg px-3 py-2 text-sm text-gray-200"
        >
          <option value="">All Sources</option>
          <option value="backend">Backend</option>
          <option value="frontend">Frontend</option>
        </select>
        <select
          value={env}
          onChange={(e) => { setEnv(e.target.value); setPage(1); }}
          className="bg-gray-800 border border-gray-700 rounded-lg px-3 py-2 text-sm text-gray-200"
        >
          <option value="">All Envs</option>
          <option value="dev">Dev</option>
          <option value="prod">Prod</option>
        </select>
        <div className="relative flex-1 min-w-[200px]">
          <Search className="absolute left-3 top-1/2 -translate-y-1/2 w-4 h-4 text-gray-500" />
          <input
            type="text"
            value={search}
            onChange={(e) => setSearch(e.target.value)}
            onKeyDown={(e) => e.key === "Enter" && load(1)}
            placeholder="Search logs..."
            className="w-full bg-gray-800 border border-gray-700 rounded-lg pl-10 pr-4 py-2 text-sm text-gray-200 placeholder-gray-500"
          />
        </div>
        <button
          onClick={() => { setPage(1); load(1); }}
          className="px-4 py-2 bg-indigo-500/10 text-indigo-400 rounded-lg text-sm font-medium hover:bg-indigo-500/20"
        >
          Search
        </button>
      </div>

      {/* Log entries */}
      {loading ? (
        <div className="animate-pulse text-gray-500">Loading logs...</div>
      ) : (
        <>
          <div className="space-y-2">
            {data?.logs?.map((log) => {
              const style = LEVEL_STYLES[log.level] || LEVEL_STYLES.info;
              const Icon = style.icon;
              return (
                <div
                  key={log.id}
                  className={`bg-gray-900 border ${style.border} rounded-lg px-4 py-3 flex items-start gap-3`}
                >
                  <div className={`p-1.5 rounded ${style.bg} mt-0.5`}>
                    <Icon className={`w-3.5 h-3.5 ${style.text}`} />
                  </div>
                  <div className="flex-1 min-w-0">
                    <div className="flex items-center gap-2 mb-1">
                      <span className={`text-xs font-medium uppercase ${style.text}`}>{log.level}</span>
                      <span className="text-xs text-gray-600">|</span>
                      <span className="text-xs text-gray-400">{log.source}</span>
                      {log.env && (
                        <span
                          className={`text-[10px] px-1.5 py-0.5 rounded font-mono uppercase ${
                            log.env === "prod"
                              ? "bg-emerald-500/10 text-emerald-400"
                              : "bg-gray-700/50 text-gray-400"
                          }`}
                        >
                          {log.env}
                        </span>
                      )}
                      {log.logger && (
                        <>
                          <span className="text-xs text-gray-600">|</span>
                          <span className="text-xs text-gray-500 font-mono">{log.logger}</span>
                        </>
                      )}
                      {log.status_code && (
                        <span
                          className={`text-xs font-mono ${
                            log.status_code >= 500
                              ? "text-red-400"
                              : log.status_code >= 400
                              ? "text-amber-400"
                              : "text-emerald-400"
                          }`}
                        >
                          {log.status_code}
                        </span>
                      )}
                      {log.duration_ms != null && (
                        <span className="text-xs text-gray-500">{log.duration_ms}ms</span>
                      )}
                    </div>
                    <div className="text-sm text-gray-200 font-mono break-all">{log.message}</div>
                    {log.details && (
                      <pre className="mt-2 text-xs text-gray-400 bg-gray-950 rounded p-2 overflow-x-auto max-h-32">
                        {log.details}
                      </pre>
                    )}
                  </div>
                  <div className="text-xs text-gray-500 flex-shrink-0 whitespace-nowrap">
                    {new Date(log.created_at).toLocaleTimeString()}
                  </div>
                </div>
              );
            })}
            {data?.logs?.length === 0 && (
              <div className="text-center py-12 text-gray-500 bg-gray-900 border border-gray-800 rounded-xl">
                <ScrollText className="w-8 h-8 mx-auto mb-3 text-gray-600" />
                No logs found
              </div>
            )}
          </div>
          <Pagination
            page={page}
            totalPages={Math.ceil((data?.total || 0) / 50)}
            onPageChange={(p) => {
              setPage(p);
              load(p);
            }}
          />
        </>
      )}
    </div>
  );
}
