import { useEffect, useState } from "react";
import {
  BookText,
  Sparkles,
  Trash2,
  Loader2,
  Search,
  CheckCircle2,
  XCircle,
  Clock,
} from "lucide-react";
import { api } from "../api/client";
import PageHeader from "../components/PageHeader";
import Pagination from "../components/Pagination";

const STATUSES = [
  { label: "Pending", value: "pending", icon: Clock },
  { label: "Approved", value: "approved", icon: CheckCircle2 },
  { label: "Rejected", value: "rejected", icon: XCircle },
];

export default function Dictionary() {
  const [tab, setTab] = useState("submissions");
  const [stats, setStats] = useState(null);
  const [merging, setMerging] = useState(false);
  const [mergeResult, setMergeResult] = useState(null);

  // Submissions state
  const [submissions, setSubmissions] = useState(null);
  const [subStatus, setSubStatus] = useState("pending");
  const [subPage, setSubPage] = useState(1);

  // Words state
  const [words, setWords] = useState(null);
  const [wordSearch, setWordSearch] = useState("");
  const [wordPage, setWordPage] = useState(1);

  const refreshStats = () => api.dictionaryStats().then(setStats).catch(() => {});

  useEffect(() => {
    refreshStats();
  }, []);

  useEffect(() => {
    if (tab !== "submissions") return;
    api.dictionarySubmissions(subPage, 50, subStatus).then(setSubmissions);
  }, [tab, subPage, subStatus]);

  useEffect(() => {
    if (tab !== "words") return;
    api.dictionaryWords(wordPage, 100, wordSearch).then(setWords);
  }, [tab, wordPage, wordSearch]);

  const handleMerge = async () => {
    if (!confirm(
      "Run AI merge on all pending submissions? Approved words will be added to the global dictionary and pushed to every connected client."
    )) return;
    setMerging(true);
    setMergeResult(null);
    try {
      const res = await api.dictionaryMerge();
      setMergeResult(res);
      await refreshStats();
      if (tab === "submissions") {
        const next = await api.dictionarySubmissions(subPage, 50, subStatus);
        setSubmissions(next);
      }
    } catch (e) {
      alert("Merge failed: " + e.message);
    } finally {
      setMerging(false);
    }
  };

  const handleDelete = async (word, language) => {
    if (!confirm(`Remove "${word}" from the global dictionary? Every client cache will drop it on next sync.`)) return;
    try {
      await api.dictionaryDeleteWord(word, language);
      const next = await api.dictionaryWords(wordPage, 100, wordSearch);
      setWords(next);
      refreshStats();
    } catch (e) {
      alert("Delete failed: " + e.message);
    }
  };

  return (
    <div className="p-8">
      <PageHeader
        title="Dictionary"
        description="User-submitted words → AI-curated global dictionary, synced live to every client"
      >
        <button
          onClick={handleMerge}
          disabled={merging || !stats?.pending}
          className="inline-flex items-center gap-2 bg-indigo-500 hover:bg-indigo-600 disabled:bg-gray-700 disabled:text-gray-500 text-white px-4 py-2 rounded-lg text-sm font-medium transition-colors"
        >
          {merging ? (
            <Loader2 className="w-4 h-4 animate-spin" />
          ) : (
            <Sparkles className="w-4 h-4" />
          )}
          {merging ? "Merging…" : `Merge ${stats?.pending || 0} pending`}
        </button>
      </PageHeader>

      {mergeResult && (
        <div className="mb-6 p-4 rounded-lg bg-indigo-500/10 border border-indigo-500/20 text-sm text-indigo-200">
          Merge complete — version <strong>{mergeResult.version}</strong> ·
          {" "}<strong>{mergeResult.accepted}</strong> accepted ·
          {" "}<strong>{mergeResult.rejected}</strong> rejected.
          {" "}Connected clients have been notified.
        </div>
      )}

      <div className="grid grid-cols-2 md:grid-cols-5 gap-3 mb-6">
        <StatCard label="Pending" value={stats?.pending} icon={Clock} accent="amber" />
        <StatCard label="Approved" value={stats?.approved} icon={CheckCircle2} accent="emerald" />
        <StatCard label="Rejected" value={stats?.rejected} icon={XCircle} accent="rose" />
        <StatCard label="Global words" value={stats?.global_words} icon={BookText} accent="indigo" />
        <StatCard label="Version" value={stats?.version} icon={Sparkles} accent="violet" />
      </div>

      <div className="flex gap-2 mb-4">
        <TabButton active={tab === "submissions"} onClick={() => setTab("submissions")}>
          Submissions
        </TabButton>
        <TabButton active={tab === "words"} onClick={() => setTab("words")}>
          Global dictionary
        </TabButton>
      </div>

      {tab === "submissions" ? (
        <SubmissionsTab
          status={subStatus}
          setStatus={(s) => { setSubStatus(s); setSubPage(1); }}
          page={subPage}
          setPage={setSubPage}
          data={submissions}
        />
      ) : (
        <WordsTab
          search={wordSearch}
          setSearch={(s) => { setWordSearch(s); setWordPage(1); }}
          page={wordPage}
          setPage={setWordPage}
          data={words}
          onDelete={handleDelete}
        />
      )}
    </div>
  );
}

function StatCard({ label, value, icon: Icon, accent }) {
  const colors = {
    amber: "text-amber-400 bg-amber-500/10",
    emerald: "text-emerald-400 bg-emerald-500/10",
    rose: "text-rose-400 bg-rose-500/10",
    indigo: "text-indigo-400 bg-indigo-500/10",
    violet: "text-violet-400 bg-violet-500/10",
  };
  return (
    <div className="bg-gray-900 border border-gray-800 rounded-xl p-4">
      <div className="flex items-center justify-between">
        <span className="text-xs text-gray-400 uppercase tracking-wide">{label}</span>
        <div className={`w-7 h-7 rounded-md flex items-center justify-center ${colors[accent]}`}>
          <Icon className="w-3.5 h-3.5" />
        </div>
      </div>
      <div className="mt-2 text-2xl font-bold text-white">{value ?? "—"}</div>
    </div>
  );
}

function TabButton({ active, onClick, children }) {
  return (
    <button
      onClick={onClick}
      className={`px-4 py-2 rounded-lg text-sm font-medium transition-colors ${
        active
          ? "bg-gray-800 text-white"
          : "text-gray-400 hover:bg-gray-800/50 hover:text-gray-200"
      }`}
    >
      {children}
    </button>
  );
}

function SubmissionsTab({ status, setStatus, page, setPage, data }) {
  return (
    <div>
      <div className="flex bg-gray-800 rounded-lg p-1 w-fit mb-4">
        {STATUSES.map(({ label, value, icon: Icon }) => (
          <button
            key={value}
            onClick={() => setStatus(value)}
            className={`flex items-center gap-1.5 px-3 py-1.5 rounded-md text-sm font-medium transition-colors ${
              status === value
                ? "bg-gray-700 text-white"
                : "text-gray-400 hover:text-gray-200"
            }`}
          >
            <Icon className="w-3.5 h-3.5" />
            {label}
          </button>
        ))}
      </div>
      <div className="bg-gray-900 border border-gray-800 rounded-xl overflow-hidden">
        <table className="w-full text-sm">
          <thead className="bg-gray-800/50 text-xs uppercase text-gray-400">
            <tr>
              <th className="text-left px-4 py-3">Word</th>
              <th className="text-left px-4 py-3">Lang</th>
              <th className="text-left px-4 py-3">Submitters</th>
              <th className="text-left px-4 py-3">Submitted</th>
              <th className="text-left px-4 py-3">Note</th>
            </tr>
          </thead>
          <tbody>
            {(data?.submissions || []).map((s) => (
              <tr key={s.id} className="border-t border-gray-800 hover:bg-gray-800/30">
                <td className="px-4 py-3 font-mono">{s.word}</td>
                <td className="px-4 py-3 text-gray-400">{s.language}</td>
                <td className="px-4 py-3 text-gray-300">{s.submitter_count}</td>
                <td className="px-4 py-3 text-gray-400">
                  {s.created_at ? new Date(s.created_at).toLocaleString() : ""}
                </td>
                <td className="px-4 py-3 text-gray-400 text-xs italic">
                  {s.note || ""}
                </td>
              </tr>
            ))}
            {data && data.submissions.length === 0 && (
              <tr>
                <td colSpan={5} className="px-4 py-8 text-center text-gray-500">
                  No {status} submissions.
                </td>
              </tr>
            )}
          </tbody>
        </table>
      </div>
      <Pagination
        page={page}
        totalPages={data?.total_pages || 1}
        onPageChange={setPage}
      />
    </div>
  );
}

function WordsTab({ search, setSearch, page, setPage, data, onDelete }) {
  return (
    <div>
      <div className="flex items-center gap-2 mb-4">
        <div className="relative flex-1 max-w-sm">
          <Search className="w-4 h-4 absolute left-3 top-1/2 -translate-y-1/2 text-gray-500" />
          <input
            type="text"
            placeholder="Search the global dictionary…"
            value={search}
            onChange={(e) => setSearch(e.target.value)}
            className="w-full bg-gray-900 border border-gray-800 rounded-lg pl-9 pr-3 py-2 text-sm focus:outline-none focus:border-gray-700"
          />
        </div>
      </div>
      <div className="bg-gray-900 border border-gray-800 rounded-xl overflow-hidden">
        <table className="w-full text-sm">
          <thead className="bg-gray-800/50 text-xs uppercase text-gray-400">
            <tr>
              <th className="text-left px-4 py-3">Word</th>
              <th className="text-left px-4 py-3">Lang</th>
              <th className="text-left px-4 py-3">Source</th>
              <th className="text-left px-4 py-3">Users</th>
              <th className="text-left px-4 py-3">Added in v</th>
              <th className="text-right px-4 py-3"></th>
            </tr>
          </thead>
          <tbody>
            {(data?.words || []).map((w) => (
              <tr key={`${w.word}|${w.language}`} className="border-t border-gray-800 hover:bg-gray-800/30">
                <td className="px-4 py-3 font-mono">{w.word}</td>
                <td className="px-4 py-3 text-gray-400">{w.language}</td>
                <td className="px-4 py-3 text-gray-400">{w.source}</td>
                <td className="px-4 py-3 text-gray-300">{w.submission_count}</td>
                <td className="px-4 py-3 text-gray-400">{w.added_in_version}</td>
                <td className="px-4 py-3 text-right">
                  <button
                    onClick={() => onDelete(w.word, w.language)}
                    className="inline-flex items-center text-rose-400 hover:text-rose-300"
                    title="Remove from global dictionary"
                  >
                    <Trash2 className="w-4 h-4" />
                  </button>
                </td>
              </tr>
            ))}
            {data && data.words.length === 0 && (
              <tr>
                <td colSpan={6} className="px-4 py-8 text-center text-gray-500">
                  {search ? "No words match." : "Global dictionary is empty. Run a merge to populate it."}
                </td>
              </tr>
            )}
          </tbody>
        </table>
      </div>
      <Pagination
        page={page}
        totalPages={data?.total_pages || 1}
        onPageChange={setPage}
      />
    </div>
  );
}
