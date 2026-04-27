import { NavLink, Outlet } from "react-router-dom";
import {
  LayoutDashboard,
  Database,
  HardDrive,
  Users,
  BarChart3,
  Bug,
  ScrollText,
  PenTool,
  LogOut,
  ShieldCheck,
} from "lucide-react";
import { api } from "../api/client";
import clsx from "clsx";

const links = [
  { to: "/", icon: LayoutDashboard, label: "Overview" },
  { to: "/console", icon: ShieldCheck, label: "Console" },
  { to: "/database", icon: Database, label: "Database" },
  { to: "/storage", icon: HardDrive, label: "Storage" },
  { to: "/activity", icon: Users, label: "User Activity" },
  { to: "/analytics", icon: BarChart3, label: "Analytics" },
  { to: "/crashes", icon: Bug, label: "Crash Reports" },
  { to: "/logs", icon: ScrollText, label: "Logs" },
];

export default function DashboardLayout() {
  return (
    <div className="flex h-screen overflow-hidden">
      {/* Sidebar */}
      <aside className="w-64 flex-shrink-0 bg-gray-900 border-r border-gray-800 flex flex-col">
        <div className="h-16 flex items-center gap-3 px-6 border-b border-gray-800">
          <PenTool className="w-6 h-6 text-indigo-400" />
          <span className="text-lg font-bold tracking-tight">InkSpaceX</span>
          <span className="text-xs bg-indigo-500/20 text-indigo-300 px-2 py-0.5 rounded-full ml-auto">
            Admin
          </span>
        </div>
        <nav className="flex-1 py-4 px-3 space-y-1 overflow-y-auto">
          {links.map(({ to, icon: Icon, label }) => (
            <NavLink
              key={to}
              to={to}
              end={to === "/"}
              className={({ isActive }) =>
                clsx(
                  "flex items-center gap-3 px-3 py-2.5 rounded-lg text-sm font-medium transition-colors",
                  isActive
                    ? "bg-indigo-500/10 text-indigo-400"
                    : "text-gray-400 hover:bg-gray-800 hover:text-gray-200"
                )
              }
            >
              <Icon className="w-5 h-5" />
              {label}
            </NavLink>
          ))}
        </nav>
        <div className="p-4 border-t border-gray-800">
          <button
            onClick={() => api.logout()}
            className="flex items-center gap-2 w-full px-3 py-2 rounded-lg text-sm text-gray-400 hover:bg-gray-800 hover:text-gray-200 transition-colors"
          >
            <LogOut className="w-4 h-4" />
            Sign Out
          </button>
        </div>
      </aside>

      {/* Main */}
      <main className="flex-1 overflow-y-auto bg-gray-950">
        <Outlet />
      </main>
    </div>
  );
}
