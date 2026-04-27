import { useEffect, useMemo, useState } from "react";
import { useParams, useNavigate } from "react-router-dom";
import {
  ArrowLeft,
  Columns3,
  Rows3,
  X,
  Copy,
  Check,
  ChevronRight,
  ChevronDown,
} from "lucide-react";
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
  const [selected, setSelected] = useState(null);

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
    return <div className="p-8 animate-pulse text-gray-500">Loading table…</div>;
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
                    <th
                      key={col}
                      className="text-left px-4 py-3 text-xs font-medium text-gray-400 uppercase tracking-wider whitespace-nowrap"
                    >
                      {col}
                    </th>
                  ))}
                </tr>
              </thead>
              <tbody>
                {data?.rows?.map((row, i) => (
                  <tr
                    key={i}
                    onClick={() => setSelected(row)}
                    className="border-b border-gray-800/50 hover:bg-indigo-500/5 cursor-pointer transition-colors"
                  >
                    {data.columns.map((col) => (
                      <td
                        key={col}
                        className="px-4 py-3 whitespace-nowrap max-w-xs truncate"
                      >
                        <CellPreview value={row[col]} />
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

      {selected && (
        <RowDrawer
          tableName={name}
          row={selected}
          columns={data?.columns || []}
          schema={schema?.columns || []}
          onClose={() => setSelected(null)}
        />
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

/* ─────────────────────────────────────────────── cell preview + drawer */

function CellPreview({ value }) {
  if (value === null || value === undefined) {
    return <span className="text-gray-600 italic">null</span>;
  }
  if (typeof value === "boolean") {
    return (
      <span className={value ? "text-emerald-400" : "text-red-400"}>
        {String(value)}
      </span>
    );
  }
  // Already-stringified JSON arrives from the backend; show a hint instead of the raw blob.
  if (typeof value === "string" && (value.startsWith("{") || value.startsWith("["))) {
    try {
      const parsed = JSON.parse(value);
      const isArr = Array.isArray(parsed);
      const len = isArr ? parsed.length : Object.keys(parsed).length;
      return (
        <span className="text-indigo-300 font-mono text-xs">
          {isArr ? `[${len}]` : `{${len}}`}
        </span>
      );
    } catch {
      /* not JSON, fall through */
    }
  }
  return <span className="text-gray-200">{String(value)}</span>;
}

function RowDrawer({ tableName, row, columns, schema, onClose }) {
  const typeMap = useMemo(() => {
    const m = {};
    for (const c of schema) m[c.name] = c.type;
    return m;
  }, [schema]);

  const title = useMemo(() => {
    if (row.email) return row.email;
    if (row.name) return row.name;
    if (row.title) return row.title;
    if (row.id) return String(row.id);
    return tableName;
  }, [row, tableName]);

  // Esc to close
  useEffect(() => {
    const onKey = (e) => e.key === "Escape" && onClose();
    window.addEventListener("keydown", onKey);
    return () => window.removeEventListener("keydown", onKey);
  }, [onClose]);

  return (
    <div className="fixed inset-0 z-50 flex" onClick={onClose}>
      <div className="flex-1 bg-black/60" />
      <aside
        className="w-full max-w-2xl h-full bg-gray-900 border-l border-gray-800 shadow-2xl flex flex-col"
        onClick={(e) => e.stopPropagation()}
      >
        <header className="px-6 py-4 border-b border-gray-800 flex items-start justify-between gap-4">
          <div className="min-w-0">
            <div className="text-xs uppercase tracking-wider text-gray-500">
              {tableName} row
            </div>
            <h2 className="text-lg font-semibold text-gray-100 truncate" title={title}>
              {title}
            </h2>
          </div>
          <div className="flex items-center gap-2 flex-shrink-0">
            <CopyButton
              label="Copy JSON"
              value={JSON.stringify(row, null, 2)}
            />
            <button
              onClick={onClose}
              className="p-2 rounded-lg text-gray-400 hover:bg-gray-800 hover:text-gray-200"
              title="Close (Esc)"
            >
              <X className="w-4 h-4" />
            </button>
          </div>
        </header>

        <div className="flex-1 overflow-y-auto">
          <div className="divide-y divide-gray-800">
            {columns.map((col) => (
              <FieldRow
                key={col}
                name={col}
                type={typeMap[col]}
                value={row[col]}
              />
            ))}
          </div>
        </div>
      </aside>
    </div>
  );
}

function FieldRow({ name, type, value }) {
  const parsed = useMemo(() => tryParseJson(value), [value]);
  const isComplex = parsed !== undefined;

  return (
    <div className="px-6 py-3">
      <div className="flex items-baseline gap-3 mb-1">
        <span className="font-mono text-xs text-indigo-300">{name}</span>
        {type && (
          <span className="text-[10px] uppercase tracking-wider text-gray-500">
            {type}
          </span>
        )}
        {isComplex && <CopyButton small value={JSON.stringify(parsed, null, 2)} />}
      </div>
      <ValueRenderer value={value} parsed={parsed} />
    </div>
  );
}

function ValueRenderer({ value, parsed }) {
  if (value === null || value === undefined) {
    return <span className="text-gray-600 italic text-sm">null</span>;
  }
  if (typeof value === "boolean") {
    return (
      <span className={`text-sm font-medium ${value ? "text-emerald-400" : "text-red-400"}`}>
        {String(value)}
      </span>
    );
  }
  if (parsed !== undefined) {
    return <JsonTree data={parsed} />;
  }
  // Long-form text → wrap; otherwise inline.
  const str = String(value);
  if (str.length > 80) {
    return (
      <pre className="text-sm text-gray-200 whitespace-pre-wrap break-words font-sans">
        {str}
      </pre>
    );
  }
  return <span className="text-sm text-gray-200 break-all">{str}</span>;
}

/* ─────────────────────────────────────────────────────────── JSON tree */

function JsonTree({ data, depth = 0 }) {
  if (data === null) return <span className="text-gray-600 italic">null</span>;
  if (typeof data !== "object") return <Primitive value={data} />;

  const isArray = Array.isArray(data);
  const entries = isArray
    ? data.map((v, i) => [i, v])
    : Object.entries(data);

  if (entries.length === 0) {
    return <span className="text-gray-500 font-mono text-xs">{isArray ? "[]" : "{}"}</span>;
  }

  return (
    <div className={depth === 0 ? "bg-gray-950 border border-gray-800 rounded-lg p-3 font-mono text-xs" : "ml-4 border-l border-gray-800 pl-3"}>
      {entries.map(([k, v]) => (
        <JsonNode key={String(k)} k={k} v={v} isArrayItem={isArray} depth={depth} />
      ))}
    </div>
  );
}

function JsonNode({ k, v, isArrayItem, depth }) {
  const isComplex = v !== null && typeof v === "object";
  const [open, setOpen] = useState(depth < 1);

  if (!isComplex) {
    return (
      <div className="py-0.5">
        <span className="text-indigo-300">{isArrayItem ? `[${k}]` : `"${k}"`}</span>
        <span className="text-gray-500">: </span>
        <Primitive value={v} />
      </div>
    );
  }

  const childCount = Array.isArray(v) ? v.length : Object.keys(v).length;
  const summary = Array.isArray(v) ? `Array(${childCount})` : `Object(${childCount})`;

  return (
    <div className="py-0.5">
      <button
        onClick={() => setOpen((o) => !o)}
        className="inline-flex items-center gap-1 text-left hover:text-gray-100"
      >
        {open ? <ChevronDown className="w-3 h-3" /> : <ChevronRight className="w-3 h-3" />}
        <span className="text-indigo-300">{isArrayItem ? `[${k}]` : `"${k}"`}</span>
        <span className="text-gray-500">:</span>
        {!open && <span className="text-gray-500 ml-1">{summary}</span>}
      </button>
      {open && <JsonTree data={v} depth={depth + 1} />}
    </div>
  );
}

function Primitive({ value }) {
  if (value === null) return <span className="text-gray-500">null</span>;
  if (typeof value === "boolean")
    return <span className={value ? "text-emerald-400" : "text-red-400"}>{String(value)}</span>;
  if (typeof value === "number") return <span className="text-amber-300">{value}</span>;
  return <span className="text-emerald-300 break-all">"{String(value)}"</span>;
}

/* ───────────────────────────────────────────────────────── tiny helpers */

function tryParseJson(value) {
  if (value === null || value === undefined) return undefined;
  if (typeof value === "object") return value;
  if (typeof value !== "string") return undefined;
  const t = value.trim();
  if (!(t.startsWith("{") || t.startsWith("["))) return undefined;
  try {
    return JSON.parse(t);
  } catch {
    return undefined;
  }
}

function CopyButton({ value, small = false, label }) {
  const [copied, setCopied] = useState(false);
  const click = async (e) => {
    e.stopPropagation();
    try {
      await navigator.clipboard.writeText(value);
      setCopied(true);
      setTimeout(() => setCopied(false), 1200);
    } catch {
      /* clipboard denied */
    }
  };
  if (small) {
    return (
      <button
        onClick={click}
        className="text-[10px] uppercase tracking-wider text-gray-500 hover:text-indigo-300 inline-flex items-center gap-1"
        title="Copy value"
      >
        {copied ? <Check className="w-3 h-3" /> : <Copy className="w-3 h-3" />}
        {copied ? "copied" : "copy"}
      </button>
    );
  }
  return (
    <button
      onClick={click}
      className="inline-flex items-center gap-1.5 px-2.5 py-1.5 rounded-lg text-xs text-gray-300 bg-gray-800 hover:bg-gray-700"
      title={label}
    >
      {copied ? <Check className="w-3.5 h-3.5 text-emerald-400" /> : <Copy className="w-3.5 h-3.5" />}
      {copied ? "Copied" : label}
    </button>
  );
}
