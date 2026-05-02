import { useEffect, useState } from "react";
import {
  HardDrive,
  Folder,
  FileIcon,
  ChevronRight,
  ArrowLeft,
  Image,
  File,
  Trash2,
} from "lucide-react";
import {
  PieChart,
  Pie,
  Cell,
  Tooltip,
  ResponsiveContainer,
  Legend,
} from "recharts";
import { api } from "../api/client";
import PageHeader from "../components/PageHeader";
import StatCard from "../components/StatCard";
import { ConfirmModal } from "./TableDetail";

const COLORS = ["#818cf8", "#34d399", "#f59e0b", "#ef4444", "#8b5cf6", "#06b6d4"];

function formatBytes(bytes) {
  if (!bytes) return "0 B";
  const k = 1024;
  const sizes = ["B", "KB", "MB", "GB"];
  const i = Math.floor(Math.log(bytes) / Math.log(k));
  return `${(bytes / Math.pow(k, i)).toFixed(1)} ${sizes[i]}`;
}

export default function Storage() {
  const [stats, setStats] = useState(null);
  const [objects, setObjects] = useState(null);
  const [prefix, setPrefix] = useState("");
  const [bucket, setBucket] = useState("inkspacex");
  const [loading, setLoading] = useState(true);
  const [confirm, setConfirm] = useState(null);
  const [busy, setBusy] = useState(false);

  useEffect(() => {
    Promise.all([api.storageStats(), api.browse(bucket, "")])
      .then(([s, o]) => {
        setStats(s);
        setObjects(o);
      })
      .finally(() => setLoading(false));
  }, []);

  const navigate = (newPrefix) => {
    setPrefix(newPrefix);
    api.browse(bucket, newPrefix).then(setObjects);
  };

  const goUp = () => {
    const parts = prefix.split("/").filter(Boolean);
    parts.pop();
    navigate(parts.length ? parts.join("/") + "/" : "");
  };

  const reload = () =>
    Promise.all([api.storageStats(), api.browse(bucket, prefix)]).then(
      ([s, o]) => {
        setStats(s);
        setObjects(o);
      }
    );

  const handleDeleteObject = (obj) => {
    setConfirm({
      title: "Delete object?",
      message: `Permanently delete ${obj.name} from "${bucket}".`,
      onConfirm: async () => {
        await api.deleteObject(bucket, obj.name);
        await reload();
      },
    });
  };

  const handleClearBucket = () => {
    const scope = prefix ? `prefix "${prefix}"` : `entire bucket "${bucket}"`;
    setConfirm({
      title: prefix ? "Clear this folder?" : "Clear entire bucket?",
      message: `Permanently delete every object under ${scope}. This action is irreversible.`,
      requireText: prefix || bucket,
      onConfirm: async () => {
        setBusy(true);
        try {
          await api.clearBucket(bucket, prefix);
          await reload();
        } finally {
          setBusy(false);
        }
      },
    });
  };

  if (loading) {
    return <div className="p-8 animate-pulse text-gray-500">Loading storage...</div>;
  }

  const typeData = stats?.by_type
    ? Object.entries(stats.by_type).map(([ext, v]) => ({
        name: ext.toUpperCase(),
        value: v.count,
        size: v.size,
      }))
    : [];

  return (
    <div className="p-8">
      <PageHeader title="Storage Explorer" description="MinIO object storage browser">
        <button
          onClick={handleClearBucket}
          disabled={busy || !objects?.objects?.length}
          className="flex items-center gap-1.5 px-3 py-1.5 rounded-lg text-xs font-medium bg-red-500/10 text-red-300 hover:bg-red-500/20 border border-red-500/30 disabled:opacity-40 disabled:cursor-not-allowed"
          title={prefix ? "Clear current folder" : "Clear entire bucket"}
        >
          <Trash2 className="w-3.5 h-3.5" />
          {prefix ? "Clear folder" : "Clear bucket"}
        </button>
      </PageHeader>

      <div className="grid grid-cols-1 sm:grid-cols-3 gap-4 mb-6">
        <StatCard
          label="Total Objects"
          value={stats?.total_objects ?? 0}
          icon={FileIcon}
          color="indigo"
        />
        <StatCard
          label="Total Size"
          value={`${stats?.total_size_mb ?? 0} MB`}
          icon={HardDrive}
          color="blue"
        />
        <StatCard
          label="Bucket"
          value={stats?.bucket ?? bucket}
          icon={Folder}
          color="green"
        />
      </div>

      <div className="grid grid-cols-1 lg:grid-cols-3 gap-6">
        {/* File browser */}
        <div className="lg:col-span-2 bg-gray-900 border border-gray-800 rounded-xl p-5">
          <div className="flex items-center gap-2 mb-4 text-sm text-gray-400">
            <HardDrive className="w-4 h-4" />
            <span>{bucket}</span>
            {prefix && (
              <>
                <ChevronRight className="w-3 h-3" />
                <span className="text-gray-200">{prefix}</span>
              </>
            )}
            {prefix && (
              <button onClick={goUp} className="ml-auto flex items-center gap-1 text-indigo-400 hover:text-indigo-300">
                <ArrowLeft className="w-4 h-4" /> Up
              </button>
            )}
          </div>

          <div className="space-y-1">
            {objects?.objects?.length === 0 && (
              <div className="text-center py-8 text-gray-500">Empty directory</div>
            )}
            {objects?.objects?.map((obj) => (
              <div
                key={obj.name}
                onClick={() => obj.is_dir && navigate(obj.name)}
                className={`flex items-center gap-3 px-4 py-3 rounded-lg hover:bg-gray-800 group ${
                  obj.is_dir ? "cursor-pointer" : ""
                }`}
              >
                {obj.is_dir ? (
                  <Folder className="w-5 h-5 text-amber-400" />
                ) : obj.name?.match(/\.(jpg|jpeg|png|gif|webp|svg)$/i) ? (
                  <Image className="w-5 h-5 text-emerald-400" />
                ) : (
                  <File className="w-5 h-5 text-gray-400" />
                )}
                <span className="flex-1 truncate">
                  {obj.name?.replace(prefix, "").replace(/\/$/, "")}
                </span>
                {!obj.is_dir && (
                  <span className="text-xs text-gray-500">{formatBytes(obj.size)}</span>
                )}
                {!obj.is_dir && (
                  <button
                    onClick={(e) => {
                      e.stopPropagation();
                      handleDeleteObject(obj);
                    }}
                    className="p-1.5 rounded-md text-gray-500 hover:text-red-400 hover:bg-red-500/10 opacity-0 group-hover:opacity-100 transition-opacity"
                    title="Delete object"
                  >
                    <Trash2 className="w-4 h-4" />
                  </button>
                )}
                {obj.is_dir && <ChevronRight className="w-4 h-4 text-gray-600" />}
              </div>
            ))}
          </div>
        </div>

        {/* Type breakdown */}
        {typeData.length > 0 && (
          <div className="bg-gray-900 border border-gray-800 rounded-xl p-5">
            <h3 className="text-sm font-medium text-gray-400 mb-4">Files by Type</h3>
            <ResponsiveContainer width="100%" height={250}>
              <PieChart>
                <Pie
                  data={typeData}
                  dataKey="value"
                  nameKey="name"
                  cx="50%"
                  cy="50%"
                  outerRadius={80}
                  strokeWidth={2}
                  stroke="#111827"
                >
                  {typeData.map((_, i) => (
                    <Cell key={i} fill={COLORS[i % COLORS.length]} />
                  ))}
                </Pie>
                <Tooltip
                  contentStyle={{ backgroundColor: "#1f2937", border: "1px solid #374151", borderRadius: 8 }}
                  formatter={(v, name, entry) => [`${v} files (${formatBytes(entry.payload.size)})`, name]}
                />
                <Legend />
              </PieChart>
            </ResponsiveContainer>
          </div>
        )}
      </div>

      {confirm && (
        <ConfirmModal {...confirm} onClose={() => setConfirm(null)} />
      )}
    </div>
  );
}
