import { useEffect, useState } from "react";
import { useParams, useNavigate } from "react-router-dom";
import { ArrowLeft, Columns3, Rows3 } from "lucide-react";
import { api } from "../api/client";
import PageHeader from "../components/PageHeader";
import Pagination from "../components/Pagination";

export default function TableDetail() {
  const { name } = useParams();
  const navigate = useNavigate();
  const [tab, setTab] = useState("data");
  const [schema, setSchema] = useState(null);
  const [data, setData] = useState(null);
  const [page, setPage] = useState(1);
  const [loading, setLoading] = useState(true);

  useEffect(() => {
    Promise.all([api.tableSchema(name), api.tableData(name, 1)])
      .then(([s, d]) => {
        setSchema(s);
        setData(d);
      })
      .finally(() => setLoading(false));
  }, [name]);

  const loadPage = (p) => {
    setPage(p);
    api.tableData(name, p).then(setData);
  };

  if (loading) {
    return (
      <div className="p-8 animate-pulse text-gray-500">Loading table...</div>
    );
  }

  return (
    <div className="p-8">
      <button
        onClick={() => navigate("/database")}
        className="flex items-center gap-2 text-sm text-gray-400 hover:text-gray-200 mb-4"
      >
        <ArrowLeft className="w-4 h-4" /> Back to tables
      </button>

      <PageHeader title={name} description={`${data?.total ?? 0} total rows`}>
        <div className="flex bg-gray-800 rounded-lg p-1">
          <TabBtn active={tab === "data"} onClick={() => setTab("data")} icon={Rows3} label="Data" />
          <TabBtn active={tab === "schema"} onClick={() => setTab("schema")} icon={Columns3} label="Schema" />
        </div>
      </PageHeader>

      {tab === "data" ? (
        <div className="bg-gray-900 border border-gray-800 rounded-xl overflow-hidden">
          <div className="overflow-x-auto">
            <table className="w-full text-sm">
              <thead>
                <tr className="border-b border-gray-800">
                  {data?.columns?.map((col) => (
                    <th key={col} className="text-left px-4 py-3 text-xs font-medium text-gray-400 uppercase tracking-wider whitespace-nowrap">
                      {col}
                    </th>
                  ))}
                </tr>
              </thead>
              <tbody>
                {data?.rows?.map((row, i) => (
                  <tr key={i} className="border-b border-gray-800/50 hover:bg-gray-800/30">
                    {data.columns.map((col) => (
                      <td key={col} className="px-4 py-3 whitespace-nowrap max-w-xs truncate">
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
                      No data in this table
                    </td>
                  </tr>
                )}
              </tbody>
            </table>
          </div>
          <div className="px-4 pb-4">
            <Pagination page={page} totalPages={data?.total_pages || 0} onPageChange={loadPage} />
          </div>
        </div>
      ) : (
        <div className="bg-gray-900 border border-gray-800 rounded-xl overflow-hidden">
          <table className="w-full text-sm">
            <thead>
              <tr className="border-b border-gray-800">
                <th className="text-left px-4 py-3 text-xs font-medium text-gray-400 uppercase">Column</th>
                <th className="text-left px-4 py-3 text-xs font-medium text-gray-400 uppercase">Type</th>
                <th className="text-left px-4 py-3 text-xs font-medium text-gray-400 uppercase">Nullable</th>
                <th className="text-left px-4 py-3 text-xs font-medium text-gray-400 uppercase">Default</th>
              </tr>
            </thead>
            <tbody>
              {schema?.columns?.map((col) => (
                <tr key={col.name} className="border-b border-gray-800/50">
                  <td className="px-4 py-3 font-mono text-indigo-300">{col.name}</td>
                  <td className="px-4 py-3 text-gray-300">{col.type}</td>
                  <td className="px-4 py-3">
                    <span className={col.nullable ? "text-amber-400" : "text-emerald-400"}>
                      {col.nullable ? "YES" : "NO"}
                    </span>
                  </td>
                  <td className="px-4 py-3 text-gray-500 font-mono text-xs">
                    {col.default || "—"}
                  </td>
                </tr>
              ))}
            </tbody>
          </table>
        </div>
      )}
    </div>
  );
}

function TabBtn({ active, onClick, icon: Icon, label }) {
  return (
    <button
      onClick={onClick}
      className={`flex items-center gap-2 px-3 py-1.5 rounded-md text-sm font-medium transition-colors ${
        active ? "bg-gray-700 text-white" : "text-gray-400 hover:text-gray-200"
      }`}
    >
      <Icon className="w-4 h-4" />
      {label}
    </button>
  );
}
