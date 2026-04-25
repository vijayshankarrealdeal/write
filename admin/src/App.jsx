import { Routes, Route, Navigate } from "react-router-dom";
import { api } from "./api/client";
import DashboardLayout from "./components/DashboardLayout";
import Login from "./pages/Login";
import Overview from "./pages/Overview";
import DatabaseTables from "./pages/DatabaseTables";
import TableDetail from "./pages/TableDetail";
import Storage from "./pages/Storage";
import UserActivity from "./pages/UserActivity";
import Analytics from "./pages/Analytics";
import CrashReports from "./pages/CrashReports";
import Logs from "./pages/Logs";

function ProtectedRoute({ children }) {
  if (!api.isAuthenticated()) {
    return <Navigate to="/login" replace />;
  }
  return children;
}

export default function App() {
  return (
    <Routes>
      <Route path="/login" element={<Login />} />
      <Route
        element={
          <ProtectedRoute>
            <DashboardLayout />
          </ProtectedRoute>
        }
      >
        <Route index element={<Overview />} />
        <Route path="database" element={<DatabaseTables />} />
        <Route path="database/:name" element={<TableDetail />} />
        <Route path="storage" element={<Storage />} />
        <Route path="activity" element={<UserActivity />} />
        <Route path="analytics" element={<Analytics />} />
        <Route path="crashes" element={<CrashReports />} />
        <Route path="logs" element={<Logs />} />
      </Route>
    </Routes>
  );
}
