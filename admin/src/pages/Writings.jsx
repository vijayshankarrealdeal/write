import { useEffect, useMemo, useState } from "react";
import {
  ArrowLeft,
  BookOpen,
  Calendar,
  ChevronRight,
  FileText,
  Search,
  User as UserIcon,
} from "lucide-react";
import { api } from "../api/client";
import PageHeader from "../components/PageHeader";
import Pagination from "../components/Pagination";

export default function Writings() {
  const [data, setData] = useState(null);
  const [page, setPage] = useState(1);
  const [search, setSearch] = useState("");
  const [loading, setLoading] = useState(true);
  const [openId, setOpenId] = useState(null);

  const load = (p = page, s = search) => {
    setLoading(true);
    api.writings(p, 25, s).then(setData).finally(() => setLoading(false));
  };

  useEffect(() => {
    load(1, search);
    setPage(1);
  }, [search]);

  if (openId) {
    return <WritingDetail id={openId} onBack={() => setOpenId(null)} />;
  }

  return (
    <div className="p-8">
      <PageHeader
        title="Writings"
        description="Browse what users are writing — read titles, sections, and bodies to understand how the editor is being used"
      />

      <div className="flex items-center gap-3 mb-4">
        <div className="relative flex-1 max-w-md">
          <Search className="w-4 h-4 absolute left-3 top-1/2 -translate-y-1/2 text-gray-500" />
          <input
            type="text"
            placeholder="Search by title, author, or owner email"
            value={search}
            onChange={(e) => setSearch(e.target.value)}
            className="w-full bg-gray-900 border border-gray-800 rounded-lg pl-9 pr-3 py-2 text-sm text-gray-200 placeholder-gray-500 focus:outline-none focus:border-indigo-500"
          />
        </div>
        {data?.total != null && (
          <span className="text-xs text-gray-500">
            {data.total.toLocaleString()} total
          </span>
        )}
      </div>

      <div className="bg-gray-900 border border-gray-800 rounded-xl overflow-hidden">
        {loading ? (
          <div className="p-8 animate-pulse text-gray-500">Loading writings…</div>
        ) : (
          <table className="w-full text-sm">
            <thead>
              <tr className="border-b border-gray-800 text-xs text-gray-400 uppercase">
                <th className="text-left px-5 py-3">Title</th>
                <th className="text-left px-5 py-3">Owner</th>
                <th className="text-left px-5 py-3">Type</th>
                <th className="text-right px-5 py-3">Sections</th>
                <th className="text-right px-5 py-3">Updated</th>
                <th className="px-3 py-3" />
              </tr>
            </thead>
            <tbody>
              {data?.writings?.map((w) => (
                <tr
                  key={w.id}
                  onClick={() => setOpenId(w.id)}
                  className="border-b border-gray-800/50 hover:bg-gray-800/30 cursor-pointer"
                >
                  <td className="px-5 py-3">
                    <div className="font-medium text-gray-100">{w.title}</div>
                    {w.author && (
                      <div className="text-xs text-gray-500 mt-0.5">by {w.author}</div>
                    )}
                  </td>
                  <td className="px-5 py-3">
                    <div className="text-gray-300">{w.owner?.name || "—"}</div>
                    <div className="text-xs text-gray-500 font-mono">{w.owner?.email}</div>
                  </td>
                  <td className="px-5 py-3 text-gray-400">
                    {w.writing_type || "—"}
                    {w.subtype ? <span className="text-gray-600"> / {w.subtype}</span> : null}
                  </td>
                  <td className="px-5 py-3 text-right tabular-nums text-gray-300">
                    {w.section_count}
                  </td>
                  <td className="px-5 py-3 text-right text-gray-400 text-xs">
                    {w.updated_at ? new Date(w.updated_at).toLocaleDateString() : "—"}
                  </td>
                  <td className="px-3 py-3 text-gray-600">
                    <ChevronRight className="w-4 h-4" />
                  </td>
                </tr>
              ))}
              {data?.writings?.length === 0 && (
                <tr>
                  <td colSpan={6} className="px-5 py-12 text-center text-gray-500">
                    No writings match this search
                  </td>
                </tr>
              )}
            </tbody>
          </table>
        )}
      </div>

      <Pagination
        page={page}
        totalPages={data?.total_pages || 0}
        onPageChange={(p) => {
          setPage(p);
          load(p, search);
        }}
      />
    </div>
  );
}

function WritingDetail({ id, onBack }) {
  const [doc, setDoc] = useState(null);
  const [loading, setLoading] = useState(true);
  const [openSection, setOpenSection] = useState(null);

  useEffect(() => {
    setLoading(true);
    api.writing(id).then((d) => {
      setDoc(d);
      setOpenSection(d?.sections?.[0]?.id ?? null);
    }).finally(() => setLoading(false));
  }, [id]);

  const totalChars = useMemo(() => {
    if (!doc?.sections) return 0;
    return doc.sections.reduce((s, sec) => s + (sec.body?.length || 0), 0);
  }, [doc]);

  if (loading) {
    return (
      <div className="p-8">
        <BackButton onClick={onBack} />
        <div className="animate-pulse text-gray-500 mt-6">Loading writing…</div>
      </div>
    );
  }
  if (!doc) {
    return (
      <div className="p-8">
        <BackButton onClick={onBack} />
        <div className="text-gray-500 mt-6">Writing not found.</div>
      </div>
    );
  }

  const active = doc.sections.find((s) => s.id === openSection);

  return (
    <div className="p-8">
      <BackButton onClick={onBack} />

      <div className="mt-6 mb-6">
        <h1 className="text-2xl font-bold text-gray-100">{doc.title}</h1>
        {doc.author && (
          <p className="text-sm text-gray-400 mt-1">by {doc.author}</p>
        )}
        {doc.description && (
          <p className="text-sm text-gray-400 mt-2 max-w-3xl">{doc.description}</p>
        )}
        <div className="flex flex-wrap items-center gap-x-6 gap-y-2 mt-4 text-xs text-gray-500">
          <Meta icon={UserIcon} label="Owner">
            <span className="text-gray-300">{doc.owner?.name || "—"}</span>{" "}
            <span className="text-gray-500 font-mono">({doc.owner?.email})</span>
          </Meta>
          <Meta icon={FileText} label="Type">
            {doc.writing_type || "—"}
            {doc.subtype ? ` / ${doc.subtype}` : ""}
          </Meta>
          <Meta icon={BookOpen} label="Sections">
            {doc.section_count} · {doc.total_words.toLocaleString()} words ·{" "}
            {totalChars.toLocaleString()} chars
          </Meta>
          <Meta icon={Calendar} label="Updated">
            {doc.updated_at ? new Date(doc.updated_at).toLocaleString() : "—"}
          </Meta>
        </div>
      </div>

      <div className="grid grid-cols-12 gap-6">
        <aside className="col-span-12 lg:col-span-4 xl:col-span-3 bg-gray-900 border border-gray-800 rounded-xl overflow-hidden self-start">
          <div className="px-4 py-3 border-b border-gray-800 text-xs uppercase text-gray-500">
            Sections
          </div>
          <div className="max-h-[70vh] overflow-y-auto divide-y divide-gray-800/60">
            {doc.sections.length === 0 && (
              <div className="px-4 py-6 text-sm text-gray-500">No sections</div>
            )}
            {doc.sections.map((s, i) => {
              const active = openSection === s.id;
              return (
                <button
                  key={s.id}
                  onClick={() => setOpenSection(s.id)}
                  className={`w-full text-left px-4 py-3 transition-colors ${
                    active ? "bg-indigo-500/10" : "hover:bg-gray-800/40"
                  }`}
                >
                  <div className="flex items-center justify-between gap-2">
                    <span className="text-xs text-gray-500 tabular-nums">
                      {String(i + 1).padStart(2, "0")}
                    </span>
                    <div className="flex items-center gap-1.5">
                      {s.is_published && (
                        <span className="text-[10px] bg-emerald-500/10 text-emerald-300 px-1.5 py-0.5 rounded">
                          published
                        </span>
                      )}
                      {s.is_free_preview && (
                        <span className="text-[10px] bg-amber-500/10 text-amber-300 px-1.5 py-0.5 rounded">
                          preview
                        </span>
                      )}
                    </div>
                  </div>
                  <div
                    className={`mt-1 text-sm truncate ${
                      active ? "text-indigo-200" : "text-gray-200"
                    }`}
                  >
                    {s.title}
                  </div>
                  <div className="mt-0.5 text-xs text-gray-500">
                    {s.word_count.toLocaleString()} words
                  </div>
                </button>
              );
            })}
          </div>
        </aside>

        <main className="col-span-12 lg:col-span-8 xl:col-span-9 bg-gray-900 border border-gray-800 rounded-xl overflow-hidden">
          {active ? (
            <SectionReader section={active} />
          ) : (
            <div className="p-12 text-center text-gray-500">Select a section</div>
          )}
        </main>
      </div>
    </div>
  );
}

function SectionReader({ section }) {
  return (
    <div>
      <div className="px-6 py-4 border-b border-gray-800">
        <h2 className="text-lg font-semibold text-gray-100">{section.title}</h2>
        <div className="mt-1 text-xs text-gray-500 flex flex-wrap items-center gap-x-4 gap-y-1">
          <span>{section.word_count.toLocaleString()} words</span>
          {section.kind && <span>kind: {section.kind}</span>}
          {section.updated_at && (
            <span>updated {new Date(section.updated_at).toLocaleString()}</span>
          )}
        </div>
        {section.synopsis && (
          <div className="mt-3 text-sm text-gray-400 italic max-w-3xl">
            {section.synopsis}
          </div>
        )}
      </div>
      <div className="px-6 py-6 max-h-[70vh] overflow-y-auto">
        {section.body ? (
          <pre className="whitespace-pre-wrap font-serif text-[15px] leading-7 text-gray-200">
            {section.body}
          </pre>
        ) : (
          <div className="text-sm text-gray-500 italic">This section is empty.</div>
        )}
      </div>
    </div>
  );
}

function BackButton({ onClick }) {
  return (
    <button
      onClick={onClick}
      className="inline-flex items-center gap-1.5 text-sm text-gray-400 hover:text-gray-200"
    >
      <ArrowLeft className="w-4 h-4" /> Back to writings
    </button>
  );
}

function Meta({ icon: Icon, label, children }) {
  return (
    <div className="flex items-center gap-2">
      <Icon className="w-3.5 h-3.5 text-gray-600" />
      <span className="text-gray-500">{label}:</span>
      <span className="text-gray-300">{children}</span>
    </div>
  );
}
