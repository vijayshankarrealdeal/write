import { useEffect, useState } from "react";
import {
  MessageSquare,
  CheckCircle,
  Eye,
  Sparkles,
  Bug,
  Lightbulb,
  Heart,
  ChevronDown,
  ChevronUp,
} from "lucide-react";
import { api } from "../api/client";
import PageHeader from "../components/PageHeader";
import Pagination from "../components/Pagination";

const CATEGORIES = [
  { label: "All", value: null },
  { label: "Bug", value: "bug" },
  { label: "Feature", value: "feature" },
  { label: "Praise", value: "praise" },
  { label: "Other", value: "other" },
];

const STATUSES = [
  { label: "New", value: "new" },
  { label: "Seen", value: "seen" },
  { label: "Resolved", value: "resolved" },
  { label: "All", value: null },
];

const CATEGORY_LABELS = {
  bug: "Bug",
  feature: "Feature request",
  praise: "Praise",
  other: "Other",
};

export default function Feedback() {
  const [data, setData] = useState(null);
  const [stats, setStats] = useState(null);
  const [page, setPage] = useState(1);
  const [status, setStatus] = useState("new");
  const [category, setCategory] = useState(null);
  const [expanded, setExpanded] = useState(null);
  const [loading, setLoading] = useState(true);

  const load = (p = page, f = { status, category }) => {
    setLoading(true);
    api.feedback(p, 25, f).then(setData).finally(() => setLoading(false));
    api.feedbackStats().then(setStats).catch(() => {});
  };

  useEffect(() => {
    setPage(1);
    load(1, { status, category });
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [status, category]);

  const handleAction = async (id, nextStatus) => {
    await api.updateFeedback(id, nextStatus);
    load();
  };

  return (
    <div className="p-8">
      <PageHeader
        title="Feedback"
        description="What users are telling us about the app"
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
          label="Category"
          options={CATEGORIES}
          value={category}
          onChange={setCategory}
        />
      </div>

      {loading ? (
        <div className="animate-pulse text-gray-500">Loading feedback...</div>
      ) : (
        <>
          <div className="space-y-3">
            {data?.feedback?.map((fb) => (
              <div
                key={fb.id}
                className="bg-gray-900 border border-gray-800 rounded-xl overflow-hidden"
              >
                <div
                  className="flex items-center gap-4 px-5 py-4 cursor-pointer hover:bg-gray-800/30"
                  onClick={() => setExpanded(expanded === fb.id ? null : fb.id)}
                >
                  <CategoryIcon category={fb.category} />
                  <div className="flex-1 min-w-0">
                    <div className="flex items-center gap-2 flex-wrap">
                      <span className="font-medium">
                        {CATEGORY_LABELS[fb.category] || fb.category}
                      </span>
                      <Pill>{fb.status}</Pill>
                      {fb.platform && <Pill>{fb.platform}</Pill>}
                    </div>
                    <div className="text-sm text-gray-400 truncate mt-0.5">
                      {fb.message}
                    </div>
                    <div className="text-xs text-gray-500 mt-1">
                      {fb.user_name || fb.user_email || "Anonymous"}
                    </div>
                  </div>
                  <div className="text-xs text-gray-500 flex-shrink-0">
                    {new Date(fb.created_at).toLocaleString()}
                  </div>
                  {expanded === fb.id ? (
                    <ChevronUp className="w-4 h-4 text-gray-500" />
                  ) : (
                    <ChevronDown className="w-4 h-4 text-gray-500" />
                  )}
                </div>

                {expanded === fb.id && (
                  <div className="px-5 pb-5 border-t border-gray-800 space-y-4">
                    <div className="grid grid-cols-2 sm:grid-cols-4 gap-4 mt-4">
                      <Detail
                        label="From"
                        value={fb.user_name || fb.user_email || fb.user_id || "—"}
                      />
                      <Detail label="Category" value={fb.category} />
                      <Detail label="Platform" value={fb.platform || "—"} />
                      <Detail
                        label="App version"
                        value={fb.app_version || "—"}
                      />
                    </div>
                    <div>
                      <div className="text-xs text-gray-400 mb-1">Message</div>
                      <div className="bg-gray-950 border border-gray-800 rounded-lg p-3 text-sm text-gray-200 whitespace-pre-wrap break-words">
                        {fb.message}
                      </div>
                    </div>
                    <div
                      className="flex gap-2 pt-2"
                      onClick={(e) => e.stopPropagation()}
                    >
                      {fb.status !== "seen" && (
                        <button
                          onClick={() => handleAction(fb.id, "seen")}
                          className="px-4 py-2 bg-gray-800 text-gray-300 rounded-lg text-sm font-medium hover:bg-gray-700 transition-colors flex items-center gap-2"
                        >
                          <Eye className="w-4 h-4" />
                          Mark seen
                        </button>
                      )}
                      {fb.status !== "resolved" && (
                        <button
                          onClick={() => handleAction(fb.id, "resolved")}
                          className="px-4 py-2 bg-emerald-500/10 text-emerald-400 rounded-lg text-sm font-medium hover:bg-emerald-500/20 transition-colors flex items-center gap-2"
                        >
                          <CheckCircle className="w-4 h-4" />
                          Mark resolved
                        </button>
                      )}
                      {fb.status !== "new" && (
                        <button
                          onClick={() => handleAction(fb.id, "new")}
                          className="px-4 py-2 bg-gray-800 text-gray-300 rounded-lg text-sm font-medium hover:bg-gray-700 transition-colors flex items-center gap-2"
                        >
                          Reopen
                        </button>
                      )}
                    </div>
                  </div>
                )}
              </div>
            ))}
            {data?.feedback?.length === 0 && (
              <div className="text-center py-12 text-gray-500 bg-gray-900 border border-gray-800 rounded-xl">
                <MessageSquare className="w-8 h-8 mx-auto mb-3 text-gray-600" />
                No feedback matches these filters.
              </div>
            )}
          </div>
          <Pagination
            page={page}
            totalPages={data?.total_pages || 0}
            onPageChange={(p) => {
              setPage(p);
              load(p, { status, category });
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

function CategoryIcon({ category }) {
  const cls = "w-5 h-5 flex-shrink-0";
  if (category === "bug")
    return <Bug className={`${cls} text-rose-400`} />;
  if (category === "feature")
    return <Lightbulb className={`${cls} text-amber-400`} />;
  if (category === "praise")
    return <Heart className={`${cls} text-pink-400`} />;
  return <Sparkles className={`${cls} text-indigo-400`} />;
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
