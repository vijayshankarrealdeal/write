import { useEffect, useState } from "react";
import {
  Flag,
  CheckCircle,
  XCircle,
  AlertTriangle,
  Sparkles,
  ChevronDown,
  ChevronUp,
} from "lucide-react";
import { api } from "../api/client";
import PageHeader from "../components/PageHeader";
import Pagination from "../components/Pagination";

const TARGET_TYPES = [
  { label: "All", value: null },
  { label: "Stories", value: "story" },
  { label: "Comments", value: "comment" },
  { label: "Users", value: "user" },
  { label: "Chat", value: "chat_message" },
];

const STATUSES = [
  { label: "Pending", value: "pending" },
  { label: "Actioned", value: "actioned" },
  { label: "Dismissed", value: "dismissed" },
  { label: "All", value: null },
];

const SOURCES = [
  { label: "All", value: null },
  { label: "User", value: "user" },
  { label: "AI", value: "ai" },
];

const REASON_LABELS = {
  spam: "Spam",
  harassment: "Harassment",
  hate: "Hate speech",
  sexual: "Sexual content",
  violence: "Violence",
  self_harm: "Self-harm",
  other: "Other",
};

export default function Reports() {
  const [data, setData] = useState(null);
  const [stats, setStats] = useState(null);
  const [page, setPage] = useState(1);
  const [status, setStatus] = useState("pending");
  const [targetType, setTargetType] = useState(null);
  const [source, setSource] = useState(null);
  const [expanded, setExpanded] = useState(null);
  const [loading, setLoading] = useState(true);

  const load = (
    p = page,
    f = { status, target_type: targetType, source }
  ) => {
    setLoading(true);
    api.reports(p, 25, f).then(setData).finally(() => setLoading(false));
    api.reportStats().then(setStats).catch(() => {});
  };

  useEffect(() => {
    setPage(1);
    load(1, { status, target_type: targetType, source });
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [status, targetType, source]);

  const handleAction = async (id, nextStatus) => {
    await api.updateReport(id, nextStatus);
    load();
  };

  return (
    <div className="p-8">
      <PageHeader
        title="Reports"
        description="User-flagged content + AI-moderated chat queue"
      >
        <div className="flex bg-gray-800 rounded-lg p-1">
          {STATUSES.map((opt) => (
            <button
              key={String(opt.value)}
              onClick={() => setStatus(opt.value)}
              className={`px-3 py-1.5 rounded-md text-sm font-medium transition-colors ${
                status === opt.value
                  ? "bg-gray-700 text-white"
                  : "text-gray-400 hover:text-gray-200"
              }`}
            >
              {opt.label}
              {stats && opt.value && stats[opt.value] != null ? (
                <span className="ml-1.5 text-xs opacity-70">
                  {stats[opt.value]}
                </span>
              ) : null}
            </button>
          ))}
        </div>
      </PageHeader>

      <div className="flex flex-wrap gap-3 mb-5 text-sm">
        <FilterGroup
          label="Type"
          options={TARGET_TYPES}
          value={targetType}
          onChange={setTargetType}
        />
        <FilterGroup
          label="Source"
          options={SOURCES}
          value={source}
          onChange={setSource}
        />
      </div>

      {loading ? (
        <div className="animate-pulse text-gray-500">Loading reports...</div>
      ) : (
        <>
          <div className="space-y-3">
            {data?.reports?.map((r) => (
              <div
                key={r.id}
                className="bg-gray-900 border border-gray-800 rounded-xl overflow-hidden"
              >
                <div
                  className="flex items-center gap-4 px-5 py-4 cursor-pointer hover:bg-gray-800/30"
                  onClick={() => setExpanded(expanded === r.id ? null : r.id)}
                >
                  <StatusIcon status={r.status} />
                  <div className="flex-1 min-w-0">
                    <div className="flex items-center gap-2 flex-wrap">
                      <span className="font-medium">
                        {REASON_LABELS[r.reason] || r.reason}
                      </span>
                      <Pill>{r.target_type.replace("_", " ")}</Pill>
                      {r.source === "ai" && (
                        <Pill className="bg-fuchsia-500/15 text-fuchsia-300 border-fuchsia-500/30">
                          <Sparkles className="w-3 h-3" /> AI
                        </Pill>
                      )}
                    </div>
                    <div className="text-sm text-gray-400 truncate mt-0.5">
                      {r.snapshot || r.note || "—"}
                    </div>
                  </div>
                  <div className="text-xs text-gray-500 flex-shrink-0">
                    {new Date(r.created_at).toLocaleString()}
                  </div>
                  {expanded === r.id ? (
                    <ChevronUp className="w-4 h-4 text-gray-500" />
                  ) : (
                    <ChevronDown className="w-4 h-4 text-gray-500" />
                  )}
                </div>

                {expanded === r.id && (
                  <div className="px-5 pb-5 border-t border-gray-800 space-y-4">
                    <div className="grid grid-cols-2 sm:grid-cols-4 gap-4 mt-4">
                      <Detail
                        label="Reported by"
                        value={
                          r.source === "ai"
                            ? "AI moderation"
                            : r.reporter_name || r.reporter_id || "—"
                        }
                      />
                      <Detail label="Target" value={r.target_type} />
                      <Detail
                        label="Target author"
                        value={r.target_author_name || r.target_author_id || "—"}
                      />
                      <Detail label="Status" value={r.status} />
                    </div>
                    {r.note && (
                      <div>
                        <div className="text-xs text-gray-400 mb-1">
                          Reporter note
                        </div>
                        <div className="bg-gray-950 border border-gray-800 rounded-lg p-3 text-sm text-gray-200">
                          {r.note}
                        </div>
                      </div>
                    )}
                    {r.snapshot && (
                      <div>
                        <div className="text-xs text-gray-400 mb-1">
                          Reported content
                        </div>
                        <div className="bg-gray-950 border border-gray-800 rounded-lg p-3 text-sm text-gray-200 whitespace-pre-wrap break-words">
                          {r.snapshot}
                        </div>
                      </div>
                    )}
                    {r.ai_meta && (
                      <div>
                        <div className="text-xs text-gray-400 mb-1">
                          AI verdict
                        </div>
                        <pre className="bg-gray-950 border border-gray-800 rounded-lg p-3 text-xs text-gray-300 overflow-x-auto">
                          {JSON.stringify(r.ai_meta, null, 2)}
                        </pre>
                      </div>
                    )}
                    {r.status === "pending" && (
                      <div
                        className="flex gap-2 pt-2"
                        onClick={(e) => e.stopPropagation()}
                      >
                        <button
                          onClick={() => handleAction(r.id, "actioned")}
                          className="px-4 py-2 bg-emerald-500/10 text-emerald-400 rounded-lg text-sm font-medium hover:bg-emerald-500/20 transition-colors flex items-center gap-2"
                        >
                          <CheckCircle className="w-4 h-4" />
                          Mark actioned
                        </button>
                        <button
                          onClick={() => handleAction(r.id, "dismissed")}
                          className="px-4 py-2 bg-gray-800 text-gray-300 rounded-lg text-sm font-medium hover:bg-gray-700 transition-colors flex items-center gap-2"
                        >
                          <XCircle className="w-4 h-4" />
                          Dismiss
                        </button>
                      </div>
                    )}
                  </div>
                )}
              </div>
            ))}
            {data?.reports?.length === 0 && (
              <div className="text-center py-12 text-gray-500 bg-gray-900 border border-gray-800 rounded-xl">
                <Flag className="w-8 h-8 mx-auto mb-3 text-gray-600" />
                No reports match these filters.
              </div>
            )}
          </div>
          <Pagination
            page={page}
            totalPages={data?.total_pages || 0}
            onPageChange={(p) => {
              setPage(p);
              load(p, { status, target_type: targetType, source });
            }}
          />
        </>
      )}
    </div>
  );
}

function FilterGroup({ label, options, value, onChange }) {
  return (
    <div className="flex items-center gap-2">
      <span className="text-gray-500 text-xs uppercase tracking-wide">
        {label}
      </span>
      <div className="flex bg-gray-800 rounded-lg p-1">
        {options.map((opt) => (
          <button
            key={String(opt.value)}
            onClick={() => onChange(opt.value)}
            className={`px-3 py-1 rounded-md text-xs font-medium transition-colors ${
              value === opt.value
                ? "bg-gray-700 text-white"
                : "text-gray-400 hover:text-gray-200"
            }`}
          >
            {opt.label}
          </button>
        ))}
      </div>
    </div>
  );
}

function StatusIcon({ status }) {
  if (status === "actioned")
    return <CheckCircle className="w-5 h-5 text-emerald-400 flex-shrink-0" />;
  if (status === "dismissed")
    return <XCircle className="w-5 h-5 text-gray-500 flex-shrink-0" />;
  return <AlertTriangle className="w-5 h-5 text-amber-400 flex-shrink-0" />;
}

function Pill({ children, className = "" }) {
  return (
    <span
      className={`inline-flex items-center gap-1 text-[11px] uppercase tracking-wide px-2 py-0.5 rounded-full border ${
        className || "bg-gray-800 text-gray-300 border-gray-700"
      }`}
    >
      {children}
    </span>
  );
}

function Detail({ label, value }) {
  return (
    <div>
      <div className="text-xs text-gray-500">{label}</div>
      <div className="text-sm text-gray-300 break-words">{value || "—"}</div>
    </div>
  );
}
