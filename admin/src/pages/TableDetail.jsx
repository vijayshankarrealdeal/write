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
  Trash2,
  Pencil,
  Save,
  AlertTriangle,
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
  const [confirm, setConfirm] = useState(null);
  const [busy, setBusy] = useState(false);

  useEffect(() => {
    Promise.all([api.tableSchema(name), api.tableData(name, 1)])
      .then(([s, d]) => {
        setSchema(s);
        setData(d);
      })
      .finally(() => setLoading(false));
  }, [name]);

  const reload = (p = page) => api.tableData(name, p).then(setData);

  const loadPage = (p) => {
    setPage(p);
    api.tableData(name, p).then(setData);
  };

  const pkColumn = useMemo(() => {
    if (!data?.columns) return null;
    return data.columns.includes("id") ? "id" : data.columns[0];
  }, [data]);

  const handleClearTable = () => {
    setConfirm({
      title: `Clear table "${name}"?`,
      message:
        "This deletes every row in the table. This action is irreversible.",
      requireText: name,
      extra: { cascade: false },
      onConfirm: async (extra) => {
        setBusy(true);
        try {
          await api.clearTable(name, { cascade: extra.cascade });
          await reload(1);
          setPage(1);
        } finally {
          setBusy(false);
        }
      },
    });
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
        <div className="flex items-center gap-2">
          <button
            onClick={handleClearTable}
            disabled={busy || !data?.total}
            className="flex items-center gap-1.5 px-3 py-1.5 rounded-lg text-xs font-medium bg-red-500/10 text-red-300 hover:bg-red-500/20 border border-red-500/30 disabled:opacity-40 disabled:cursor-not-allowed"
            title="Truncate this table"
          >
            <Trash2 className="w-3.5 h-3.5" /> Clear table
          </button>
          <div className="flex bg-gray-800 rounded-lg p-1">
            <TabBtn active={tab === "data"} onClick={() => setTab("data")} icon={Rows3} label="Data" />
            <TabBtn active={tab === "schema"} onClick={() => setTab("schema")} icon={Columns3} label="Schema" />
          </div>
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
          pkColumn={pkColumn}
          onClose={() => setSelected(null)}
          onSaved={async () => {
            await reload();
            setSelected(null);
          }}
          onDeleted={async () => {
            await reload();
            setSelected(null);
          }}
          requestConfirm={setConfirm}
        />
      )}

      {confirm && (
        <ConfirmModal
          {...confirm}
          onClose={() => setConfirm(null)}
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

function RowDrawer({
  tableName,
  row,
  columns,
  schema,
  pkColumn,
  onClose,
  onSaved,
  onDeleted,
  requestConfirm,
}) {
  const typeMap = useMemo(() => {
    const m = {};
    for (const c of schema) m[c.name] = c.type;
    return m;
  }, [schema]);

  const [editing, setEditing] = useState(false);
  const [draft, setDraft] = useState({});
  const [saving, setSaving] = useState(false);
  const [error, setError] = useState(null);

  const startEdit = () => {
    const init = {};
    for (const col of columns) init[col] = row[col];
    setDraft(init);
    setError(null);
    setEditing(true);
  };

  const cancel = () => {
    setEditing(false);
    setDraft({});
    setError(null);
  };

  const setField = (col, val) => setDraft((d) => ({ ...d, [col]: val }));

  const save = async () => {
    setError(null);
    const updates = {};
    for (const col of columns) {
      if (col === pkColumn) continue;
      if (!Object.prototype.hasOwnProperty.call(draft, col)) continue;
      const before = row[col];
      const after = draft[col];
      if (before === after) continue;
      // null sentinel: empty string on a column that was previously null stays null.
      if (after === "" && before === null) continue;
      updates[col] = after;
    }
    if (Object.keys(updates).length === 0) {
      setEditing(false);
      return;
    }
    setSaving(true);
    try {
      await api.updateRow(tableName, row[pkColumn], updates);
      await onSaved();
    } catch (e) {
      setError(e.message);
    } finally {
      setSaving(false);
    }
  };

  const handleDelete = () => {
    requestConfirm({
      title: "Delete row?",
      message: `Permanently delete this row from "${tableName}". This cannot be undone.`,
      onConfirm: async () => {
        await api.deleteRow(tableName, row[pkColumn]);
        await onDeleted();
      },
    });
  };

  const title = useMemo(() => {
    if (row.email) return row.email;
    if (row.name) return row.name;
    if (row.title) return row.title;
    if (row.id) return String(row.id);
    return tableName;
  }, [row, tableName]);

  // Esc to close
  useEffect(() => {
    const onKey = (e) => e.key === "Escape" && (editing ? cancel() : onClose());
    window.addEventListener("keydown", onKey);
    return () => window.removeEventListener("keydown", onKey);
  }, [onClose, editing]);

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
            {pkColumn && (
              <div className="text-[10px] uppercase tracking-wider text-gray-500 mt-0.5">
                pk: {pkColumn}
              </div>
            )}
          </div>
          <div className="flex items-center gap-2 flex-shrink-0">
            {!editing ? (
              <>
                <button
                  onClick={startEdit}
                  className="inline-flex items-center gap-1.5 px-2.5 py-1.5 rounded-lg text-xs text-gray-300 bg-gray-800 hover:bg-gray-700"
                  title="Edit row"
                >
                  <Pencil className="w-3.5 h-3.5" /> Edit
                </button>
                <button
                  onClick={handleDelete}
                  className="inline-flex items-center gap-1.5 px-2.5 py-1.5 rounded-lg text-xs text-red-300 bg-red-500/10 hover:bg-red-500/20"
                  title="Delete row"
                >
                  <Trash2 className="w-3.5 h-3.5" /> Delete
                </button>
                <CopyButton label="Copy JSON" value={JSON.stringify(row, null, 2)} />
              </>
            ) : (
              <>
                <button
                  onClick={save}
                  disabled={saving}
                  className="inline-flex items-center gap-1.5 px-2.5 py-1.5 rounded-lg text-xs text-white bg-indigo-600 hover:bg-indigo-500 disabled:opacity-50"
                >
                  <Save className="w-3.5 h-3.5" /> {saving ? "Saving…" : "Save"}
                </button>
                <button
                  onClick={cancel}
                  disabled={saving}
                  className="inline-flex items-center gap-1.5 px-2.5 py-1.5 rounded-lg text-xs text-gray-300 bg-gray-800 hover:bg-gray-700"
                >
                  Cancel
                </button>
              </>
            )}
            <button
              onClick={onClose}
              className="p-2 rounded-lg text-gray-400 hover:bg-gray-800 hover:text-gray-200"
              title="Close (Esc)"
            >
              <X className="w-4 h-4" />
            </button>
          </div>
        </header>

        {error && (
          <div className="mx-6 mt-3 px-3 py-2 text-sm text-red-300 bg-red-500/10 border border-red-500/30 rounded-lg">
            {error}
          </div>
        )}

        <div className="flex-1 overflow-y-auto">
          <div className="divide-y divide-gray-800">
            {columns.map((col) => (
              <FieldRow
                key={col}
                name={col}
                type={typeMap[col]}
                value={row[col]}
                editing={editing && col !== pkColumn}
                draftValue={draft[col]}
                onChange={(v) => setField(col, v)}
                isPk={col === pkColumn}
              />
            ))}
          </div>
        </div>
      </aside>
    </div>
  );
}

function FieldRow({ name, type, value, editing, draftValue, onChange, isPk }) {
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
        {isPk && (
          <span className="text-[10px] uppercase tracking-wider text-amber-400">
            primary key
          </span>
        )}
        {!editing && isComplex && <CopyButton small value={JSON.stringify(parsed, null, 2)} />}
      </div>
      {editing ? (
        <FieldEditor type={type} value={draftValue} onChange={onChange} />
      ) : (
        <ValueRenderer value={value} parsed={parsed} />
      )}
    </div>
  );
}

function FieldEditor({ type, value, onChange }) {
  const t = (type || "").toLowerCase();

  if (t.includes("bool")) {
    const v = value === true || value === "true";
    return (
      <select
        value={v ? "true" : value === null ? "null" : "false"}
        onChange={(e) =>
          onChange(
            e.target.value === "null"
              ? null
              : e.target.value === "true"
          )
        }
        className="bg-gray-950 border border-gray-700 text-gray-100 text-sm rounded-md px-2 py-1.5 focus:outline-none focus:border-indigo-500"
      >
        <option value="true">true</option>
        <option value="false">false</option>
        <option value="null">null</option>
      </select>
    );
  }

  if (t.includes("json")) {
    const initial =
      value === null || value === undefined
        ? ""
        : typeof value === "string"
        ? value
        : JSON.stringify(value, null, 2);
    return (
      <textarea
        value={initial}
        onChange={(e) => {
          const txt = e.target.value;
          if (txt.trim() === "") return onChange(null);
          try {
            onChange(JSON.parse(txt));
          } catch {
            onChange(txt);
          }
        }}
        rows={6}
        className="w-full bg-gray-950 border border-gray-700 text-gray-100 text-sm font-mono rounded-md px-2 py-1.5 focus:outline-none focus:border-indigo-500"
      />
    );
  }

  if (t.includes("int") || t.includes("numeric") || t.includes("real") || t.includes("double")) {
    return (
      <input
        type="number"
        value={value ?? ""}
        onChange={(e) =>
          onChange(e.target.value === "" ? null : Number(e.target.value))
        }
        className="w-full bg-gray-950 border border-gray-700 text-gray-100 text-sm rounded-md px-2 py-1.5 focus:outline-none focus:border-indigo-500"
      />
    );
  }

  // Long text → textarea, otherwise single-line input.
  const str = value == null ? "" : String(value);
  if (str.length > 80 || str.includes("\n")) {
    return (
      <textarea
        value={str}
        onChange={(e) => onChange(e.target.value)}
        rows={5}
        className="w-full bg-gray-950 border border-gray-700 text-gray-100 text-sm rounded-md px-2 py-1.5 focus:outline-none focus:border-indigo-500"
      />
    );
  }
  return (
    <input
      type="text"
      value={str}
      onChange={(e) => onChange(e.target.value)}
      className="w-full bg-gray-950 border border-gray-700 text-gray-100 text-sm rounded-md px-2 py-1.5 focus:outline-none focus:border-indigo-500"
    />
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

/* ───────────────────────────────────────────── confirm modal */

export function ConfirmModal({
  title,
  message,
  requireText,
  extra: initialExtra,
  onConfirm,
  onClose,
}) {
  const [typed, setTyped] = useState("");
  const [extra, setExtra] = useState(initialExtra || {});
  const [busy, setBusy] = useState(false);
  const [error, setError] = useState(null);

  const canConfirm = !requireText || typed === requireText;

  const run = async () => {
    setBusy(true);
    setError(null);
    try {
      await onConfirm(extra);
      onClose();
    } catch (e) {
      setError(e.message);
    } finally {
      setBusy(false);
    }
  };

  return (
    <div className="fixed inset-0 z-[60] flex items-center justify-center bg-black/70 p-4" onClick={onClose}>
      <div
        className="w-full max-w-md bg-gray-900 border border-gray-800 rounded-xl shadow-2xl"
        onClick={(e) => e.stopPropagation()}
      >
        <div className="px-6 pt-6 pb-2 flex items-start gap-3">
          <div className="p-2 rounded-lg bg-red-500/10 text-red-400">
            <AlertTriangle className="w-5 h-5" />
          </div>
          <div className="flex-1">
            <h3 className="text-lg font-semibold text-gray-100">{title}</h3>
            <p className="text-sm text-gray-400 mt-1">{message}</p>
          </div>
        </div>

        <div className="px-6 py-4 space-y-3">
          {initialExtra && "cascade" in initialExtra && (
            <label className="flex items-center gap-2 text-sm text-gray-300 select-none">
              <input
                type="checkbox"
                checked={!!extra.cascade}
                onChange={(e) => setExtra((x) => ({ ...x, cascade: e.target.checked }))}
                className="accent-red-500"
              />
              Cascade — also wipe rows in tables that reference this one
            </label>
          )}

          {requireText && (
            <div>
              <label className="text-xs text-gray-400">
                Type <span className="font-mono text-gray-200">{requireText}</span> to confirm:
              </label>
              <input
                value={typed}
                onChange={(e) => setTyped(e.target.value)}
                className="mt-1 w-full bg-gray-950 border border-gray-700 text-gray-100 text-sm rounded-md px-2 py-1.5 focus:outline-none focus:border-red-500"
                autoFocus
              />
            </div>
          )}

          {error && (
            <div className="text-sm text-red-300">{error}</div>
          )}
        </div>

        <div className="px-6 pb-6 flex justify-end gap-2">
          <button
            onClick={onClose}
            disabled={busy}
            className="px-3 py-1.5 rounded-lg text-sm text-gray-300 bg-gray-800 hover:bg-gray-700"
          >
            Cancel
          </button>
          <button
            onClick={run}
            disabled={!canConfirm || busy}
            className="px-3 py-1.5 rounded-lg text-sm text-white bg-red-600 hover:bg-red-500 disabled:opacity-40 disabled:cursor-not-allowed"
          >
            {busy ? "Working…" : "Confirm"}
          </button>
        </div>
      </div>
    </div>
  );
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
