import { useState } from "react";
import { NavLink, Outlet } from "react-router-dom";
import {
  LayoutDashboard,
  Database,
  HardDrive,
  Users,
  BarChart3,
  Bug,
  Flag,
  ScrollText,
  PenTool,
  LogOut,
  ShieldCheck,
  ChevronLeft,
  ChevronRight,
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
  { to: "/reports", icon: Flag, label: "Reports" },
  { to: "/logs", icon: ScrollText, label: "Logs" },
];

const STORAGE_KEY = "admin_sidebar_collapsed";

export default function DashboardLayout() {
  const [collapsed, setCollapsed] = useState(
    () => localStorage.getItem(STORAGE_KEY) === "1"
  );

  const toggle = () => {
    setCollapsed((c) => {
      const next = !c;
      localStorage.setItem(STORAGE_KEY, next ? "1" : "0");
      return next;
    });
  };

  return (
    <div className="flex h-screen overflow-hidden">
      <aside
        className={clsx(
          "flex-shrink-0 bg-gray-900 border-r border-gray-800 flex flex-col transition-[width] duration-200",
          collapsed ? "w-16" : "w-64"
        )}
      >
        <div
          className={clsx(
            "h-16 flex items-center border-b border-gray-800",
            collapsed ? "justify-center px-2" : "gap-3 px-6"
          )}
        >
          <PenTool className="w-6 h-6 text-indigo-400 flex-shrink-0" />
          {!collapsed && (
            <>
              <span className="text-lg font-bold tracking-tight">InkSpaceX</span>
              <span className="text-xs bg-indigo-500/20 text-indigo-300 px-2 py-0.5 rounded-full ml-auto">
                Admin
              </span>
            </>
          )}
        </div>

        <nav className="flex-1 py-4 px-3 space-y-1 overflow-y-auto">
          {links.map(({ to, icon: Icon, label }) => (
            <NavLink
              key={to}
              to={to}
              end={to === "/"}
              title={collapsed ? label : undefined}
              className={({ isActive }) =>
                clsx(
                  "flex items-center rounded-lg text-sm font-medium transition-colors",
                  collapsed ? "justify-center px-0 py-2.5" : "gap-3 px-3 py-2.5",
                  isActive
                    ? "bg-indigo-500/10 text-indigo-400"
                    : "text-gray-400 hover:bg-gray-800 hover:text-gray-200"
                )
              }
            >
              <Icon className="w-5 h-5 flex-shrink-0" />
              {!collapsed && <span>{label}</span>}
            </NavLink>
          ))}
        </nav>

        <div className="p-3 border-t border-gray-800 space-y-1">
          <button
            onClick={toggle}
            title={collapsed ? "Expand sidebar" : "Collapse sidebar"}
            className={clsx(
              "flex items-center w-full rounded-lg text-sm text-gray-400 hover:bg-gray-800 hover:text-gray-200 transition-colors",
              collapsed ? "justify-center px-0 py-2" : "gap-2 px-3 py-2"
            )}
          >
            {collapsed ? (
              <ChevronRight className="w-4 h-4" />
            ) : (
              <>
                <ChevronLeft className="w-4 h-4" />
                <span>Collapse</span>
              </>
            )}
          </button>
          <button
            onClick={() => api.logout()}
            title={collapsed ? "Sign Out" : undefined}
            className={clsx(
              "flex items-center w-full rounded-lg text-sm text-gray-400 hover:bg-gray-800 hover:text-gray-200 transition-colors",
              collapsed ? "justify-center px-0 py-2" : "gap-2 px-3 py-2"
            )}
          >
            <LogOut className="w-4 h-4 flex-shrink-0" />
            {!collapsed && <span>Sign Out</span>}
          </button>
        </div>
      </aside>

      <main className="flex-1 overflow-y-auto bg-gray-950">
        <Outlet />
      </main>
    </div>
  );
}
