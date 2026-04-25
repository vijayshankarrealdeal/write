import { useEffect, useState } from "react";
import { Bug, CheckCircle, AlertCircle, ChevronDown, ChevronUp } from "lucide-react";
import { api } from "../api/client";
import PageHeader from "../components/PageHeader";
import Pagination from "../components/Pagination";

export default function CrashReports() {
  const [data, setData] = useState(null);
  const [page, setPage] = useState(1);
  const [filter, setFilter] = useState(null); // null = all, true = resolved, false = unresolved
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
    <div className="p-8">
      <PageHeader title="Crash Reports" description="Application crash and error tracking">
        <div className="flex bg-gray-800 rounded-lg p-1">
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
              className={`px-3 py-1.5 rounded-md text-sm font-medium transition-colors ${
                filter === opt.value ? "bg-gray-700 text-white" : "text-gray-400 hover:text-gray-200"
              }`}
            >
              {opt.label}
            </button>
          ))}
        </div>
      </PageHeader>

      {loading ? (
        <div className="animate-pulse text-gray-500">Loading crashes...</div>
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
                        className="mt-4 px-4 py-2 bg-emerald-500/10 text-emerald-400 rounded-lg text-sm font-medium hover:bg-emerald-500/20 transition-colors"
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
                No crash reports found
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

function Detail({ label, value }) {
  return (
    <div>
      <div className="text-xs text-gray-500">{label}</div>
      <div className="text-sm text-gray-300">{value || "—"}</div>
    </div>
  );
}
