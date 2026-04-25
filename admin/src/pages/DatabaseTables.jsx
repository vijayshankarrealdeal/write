import { useEffect, useState } from "react";
import { useNavigate } from "react-router-dom";
import { Database, Table2, ChevronRight } from "lucide-react";
import { api } from "../api/client";
import PageHeader from "../components/PageHeader";

export default function DatabaseTables() {
  const [tables, setTables] = useState([]);
  const [loading, setLoading] = useState(true);
  const navigate = useNavigate();

  useEffect(() => {
    api.tables().then(setTables).finally(() => setLoading(false));
  }, []);

  return (
    <div className="p-8">
      <PageHeader
        title="Database Tables"
        description="PostgreSQL table browser — click a table to view its data"
      />

      {loading ? (
        <div className="animate-pulse text-gray-500">Loading tables...</div>
      ) : (
        <div className="grid grid-cols-1 sm:grid-cols-2 lg:grid-cols-3 gap-4">
          {tables.map((t) => (
            <button
              key={t.name}
              onClick={() => navigate(`/database/${t.name}`)}
              className="bg-gray-900 border border-gray-800 rounded-xl p-5 text-left hover:border-indigo-500/50 transition-colors group"
            >
              <div className="flex items-center justify-between">
                <div className="flex items-center gap-3">
                  <div className="p-2 rounded-lg bg-indigo-500/10 text-indigo-400">
                    <Table2 className="w-5 h-5" />
                  </div>
                  <div>
                    <div className="font-medium">{t.name}</div>
                    <div className="text-sm text-gray-500">{t.row_count} rows</div>
                  </div>
                </div>
                <ChevronRight className="w-5 h-5 text-gray-600 group-hover:text-indigo-400 transition-colors" />
              </div>
            </button>
          ))}
        </div>
      )}
    </div>
  );
}
