import { useState } from "react";
import Dashboard from "./components/Dashboard.jsx";
import Register from "./components/Register.jsx";
import Entry from "./components/Entry.jsx";
import ExitPayment from "./components/ExitPayment.jsx";
import History from "./components/History.jsx";

// The five screens. Only the selected one is drawn; switching to the
// Dashboard draws it again, so it always shows fresh numbers.
const SCREENS = [
  { id: "dashboard", label: "Dashboard", Component: Dashboard },
  { id: "register", label: "Register vehicle", Component: Register },
  { id: "entry", label: "Entry", Component: Entry },
  { id: "exit", label: "Exit & payment", Component: ExitPayment },
  { id: "history", label: "History", Component: History },
];

export default function App() {
  const [screen, setScreen] = useState("dashboard");
  const Current = SCREENS.find((s) => s.id === screen).Component;

  return (
    <>
      <header className="topbar">
        <div className="brand">
          <span className="brand-mark">P</span>
          <span className="brand-name">ParkingDB</span>
        </div>
        <nav className="tabs">
          {SCREENS.map((s) => (
            <button key={s.id} className={"tab" + (s.id === screen ? " active" : "")} onClick={() => setScreen(s.id)}>
              {s.label}
            </button>
          ))}
        </nav>
      </header>

      <main>
        <Current />
      </main>
    </>
  );
}
