import { useEffect, useState } from "react";
import { api, money, time, day } from "../api.js";
import { PageHead } from "./ui.jsx";

// Dashboard: usp_GetDashboard + vw_SpaceStatus + vw_ActiveSessions + vw_DailyRevenue
export default function Dashboard() {
  const [data, setData] = useState(null);   // { dash, spaces, active, revenue }
  const [error, setError] = useState(null);

  async function load() {
    try {
      // The four calls run at the same time; we wait for all of them.
      const [dash, spaces, active, revenue] = await Promise.all([
        api("GET", "/api/dashboard"),
        api("GET", "/api/spaces"),
        api("GET", "/api/active-sessions"),
        api("GET", "/api/revenue?days=14"),
      ]);
      setData({ dash, spaces, active, revenue });
      setError(null);
    } catch (err) {
      setError(err.message);
    }
  }

  // Load once when the screen appears.
  useEffect(() => { load(); }, []);

  // usp_CancelSession
  async function cancel(session) {
    if (!window.confirm(`Cancel session #${session.sessionID} of ${session.licensePlate}?\nThe car leaves without paying (fee 0) and the space becomes free.`)) return;
    try {
      await api("POST", `/api/sessions/${session.sessionID}/cancel`);
      load();
    } catch (err) {
      window.alert(err.message);
    }
  }

  return (
    <section>
      <PageHead title="Dashboard" subtitle="What is happening in the parking lot right now.">
        <button className="btn secondary" onClick={load}>Refresh</button>
      </PageHead>

      {error && <div className="banner error">{"✕ "}{error}</div>}

      {data && (
        <>
          <div className="stats">
            <Stat value={data.dash.freeSpaces} label="free spaces" />
            <Stat value={data.dash.occupiedSpaces} label="occupied" />
            <Stat value={data.dash.outOfServiceSpaces} label="out of service" />
            <Stat value={money(data.dash.revenueToday)} label={`revenue today (${data.dash.paymentsToday} payments)`} />
          </div>

          <div className="grid-2">
            <div className="card">
              <div className="card-head">
                <h2>Parking map</h2>
                <div className="legend">
                  <span><i className="dot free" />free</span>
                  <span><i className="dot occupied" />occupied</span>
                  <span><i className="dot out" />out of service</span>
                </div>
              </div>
              <ParkingMap spaces={data.spaces} />
            </div>

            <div className="stack">
              <div className="card">
                <div className="card-head">
                  <h2>Cars parked now</h2>
                  <span className="muted">{data.active.length} cars</span>
                </div>
                <div className="table-wrap tall">
                  <table>
                    <thead>
                      <tr><th>Plate</th><th>Owner</th><th>Space</th><th>Since</th><th className="num">Min</th><th className="num">Fee now</th><th /></tr>
                    </thead>
                    <tbody>
                      {data.active.length === 0 && (
                        <tr><td colSpan={7} className="empty">No car is parked right now.</td></tr>
                      )}
                      {data.active.map((a) => (
                        <tr key={a.sessionID}>
                          <td><strong>{a.licensePlate}</strong></td>
                          <td>{a.ownerName}</td>
                          <td>{a.spaceCode}</td>
                          <td>{time(a.entryTime)}</td>
                          <td className="num">{a.minutesParked}</td>
                          <td className="num">{money(a.currentFee)}</td>
                          <td><button className="btn danger" onClick={() => cancel(a)}>Cancel</button></td>
                        </tr>
                      ))}
                    </tbody>
                  </table>
                </div>
              </div>

              <div className="card">
                <div className="card-head">
                  <h2>Revenue per day</h2>
                  <span className="muted">last 14 days with payments</span>
                </div>
                <RevenueBars rows={data.revenue} />
              </div>
            </div>
          </div>
        </>
      )}
    </section>
  );
}

function Stat({ value, label }) {
  return (
    <div className="stat">
      <span className="stat-value">{value}</span>
      <span className="stat-label">{label}</span>
    </div>
  );
}

/** One small tile per space, grouped by floor: green free, red occupied, grey out of service. */
function ParkingMap({ spaces }) {
  const floors = {};
  for (const s of spaces) (floors[s.floorNo] ??= []).push(s);

  return Object.keys(floors).sort().map((floor) => (
    <div className="floor" key={floor}>
      <div className="floor-label">Floor {floor}</div>
      <div className="spaces">
        {floors[floor].map((s) => {
          const state = !s.inService ? "out" : s.isOccupied ? "occupied" : "free";
          const tip =
            `${s.spaceCode} - ${s.spaceType} (${money(s.hourlyRate)}/h)` +
            (s.currentPlate ? ` - ${s.currentPlate} since ${time(s.occupiedSince)}` : !s.inService ? " - out of service" : " - free");
          return <div key={s.spaceCode} className={`space ${state}`} title={tip} />;
        })}
      </div>
    </div>
  ));
}

/** A bar per day, scaled to the best day. */
function RevenueBars({ rows }) {
  if (rows.length === 0) return <p className="muted">No payments yet.</p>;
  const max = Math.max(1, ...rows.map((r) => r.totalAmount));
  return rows.map((r) => (
    <div className="rev-row" key={r.payDate}>
      <span>{day(r.payDate)}</span>
      <div className="rev-bar" style={{ width: `${(r.totalAmount / max) * 100}%` }} title={`${r.paymentCount} payments`} />
      <span className="rev-amount">{money(r.totalAmount)}</span>
    </div>
  ));
}
