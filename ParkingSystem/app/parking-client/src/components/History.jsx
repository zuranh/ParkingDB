import { useState } from "react";
import { api, errorMessage, money, dateTime } from "../api.js";
import { PageHead, Banner, Field } from "./ui.jsx";

const NO_FILTERS = { plate: "", from: "", to: "", status: "", pageSize: "50" };

// History:
//  - Search: usp_SearchSessions (optional filters, newest first, one page at a time)
//  - Full history of one plate: usp_GetVehicleHistory
// One row = one visit, with both its entry and exit time.
export default function History() {
  const [filters, setFilters] = useState(NO_FILTERS);
  const [msg, setMsg] = useState(null);
  const [result, setResult] = useState(null);   // { mode, rows, title, page, totalPages, totalRows }

  const set = (name) => (e) => setFilters({ ...filters, [name]: e.target.value });

  async function search(page) {
    setMsg(null);
    // Only filled-in filters are sent; the procedure treats a missing one as "all".
    const params = new URLSearchParams({ page, pageSize: filters.pageSize });
    if (filters.plate.trim()) params.set("plate", filters.plate.trim());
    if (filters.from) params.set("from", filters.from);
    if (filters.to) params.set("to", filters.to);
    if (filters.status) params.set("status", filters.status);
    try {
      const r = await api("GET", "/api/sessions?" + params);
      setResult({
        mode: "search",
        rows: r.rows,
        title: "Results",
        page,
        totalRows: r.totalRows,
        totalPages: Math.max(1, Math.ceil(r.totalRows / Number(filters.pageSize))),
      });
    } catch (err) {
      setMsg(errorMessage(err));
    }
  }

  async function fullHistory() {
    setMsg(null);
    const plate = filters.plate.trim();
    if (!plate) {
      setMsg({ kind: "error", text: "Type the full license plate first." });
      return;
    }
    try {
      const rows = await api("GET", `/api/vehicles/${encodeURIComponent(plate)}/history`);
      setResult({ mode: "history", rows, title: `Full history of ${plate.toUpperCase()}` });
    } catch (err) {
      setMsg(errorMessage(err));
    }
  }

  return (
    <section>
      <PageHead title="History" subtitle="Every visit ever recorded: one row = one visit, with its entry and exit time." />

      <form className="card filters" onSubmit={(e) => { e.preventDefault(); search(1); }} autoComplete="off">
        <Field label="Plate starts with"><input value={filters.plate} onChange={set("plate")} maxLength={15} placeholder="e.g. B 1" /></Field>
        <Field label="Entered from"><input type="date" value={filters.from} onChange={set("from")} /></Field>
        <Field label="to"><input type="date" value={filters.to} onChange={set("to")} /></Field>
        <Field label="Status">
          <select value={filters.status} onChange={set("status")}>
            <option value="">Any</option>
            <option>Active</option>
            <option>Completed</option>
            <option>Cancelled</option>
          </select>
        </Field>
        <Field label="Rows per page">
          <select value={filters.pageSize} onChange={set("pageSize")}>
            <option>25</option>
            <option>50</option>
            <option>100</option>
          </select>
        </Field>
        <div className="actions inline">
          <button className="btn primary" type="submit">Search</button>
          <button className="btn secondary" type="button" onClick={fullHistory}>Full history of this plate</button>
        </div>
      </form>

      <Banner msg={msg} />

      <div className="card">
        <div className="card-head">
          <h2>{result?.title ?? "Results"}</h2>
          {result?.mode === "search" && (
            <div className="pager">
              <button className="btn secondary small" disabled={result.page <= 1} onClick={() => search(result.page - 1)}>&larr; Previous</button>
              <span className="muted">
                Page {result.page} of {result.totalPages.toLocaleString()} ({result.totalRows.toLocaleString()} visits)
              </span>
              <button className="btn secondary small" disabled={result.page >= result.totalPages} onClick={() => search(result.page + 1)}>Next &rarr;</button>
            </div>
          )}
          {result?.mode === "history" && <span className="muted">{result.rows.length} visits</span>}
        </div>

        <div className="table-wrap">
          {!result && <p className="muted">Choose filters and press Search.</p>}
          {result?.mode === "search" && <SearchTable rows={result.rows} />}
          {result?.mode === "history" && <HistoryTable rows={result.rows} />}
        </div>
      </div>
    </section>
  );
}

function StatusBadge({ status }) {
  return <span className={`badge ${status}`}>{status}</span>;
}

function SearchTable({ rows }) {
  return (
    <table>
      <thead>
        <tr><th>#</th><th>Plate</th><th>Owner</th><th>Space</th><th>Entry</th><th>Exit</th><th>Status</th><th className="num">Fee</th><th>Paid by</th></tr>
      </thead>
      <tbody>
        {rows.length === 0 && <tr><td colSpan={9} className="empty">No visit matches these filters.</td></tr>}
        {rows.map((r) => (
          <tr key={r.sessionID}>
            <td>{r.sessionID}</td>
            <td><strong>{r.licensePlate}</strong></td>
            <td>{r.ownerName}</td>
            <td>{r.spaceCode}</td>
            <td>{dateTime(r.entryTime)}</td>
            <td>{dateTime(r.exitTime)}</td>
            <td><StatusBadge status={r.status} /></td>
            <td className="num">{money(r.fee)}</td>
            <td>{r.paymentMethod ?? ""}</td>
          </tr>
        ))}
      </tbody>
    </table>
  );
}

function HistoryTable({ rows }) {
  return (
    <table>
      <thead>
        <tr><th>#</th><th>Space</th><th>Type</th><th>Entry</th><th>Exit</th><th>Status</th><th className="num">Fee</th><th>Paid by</th><th>Paid at</th></tr>
      </thead>
      <tbody>
        {rows.length === 0 && <tr><td colSpan={9} className="empty">This car has no visits yet.</td></tr>}
        {rows.map((r) => (
          <tr key={r.sessionID}>
            <td>{r.sessionID}</td>
            <td>{r.spaceCode}</td>
            <td>{r.spaceType}</td>
            <td>{dateTime(r.entryTime)}</td>
            <td>{dateTime(r.exitTime)}</td>
            <td><StatusBadge status={r.status} /></td>
            <td className="num">{money(r.fee)}</td>
            <td>{r.paymentMethod ?? ""}</td>
            <td>{dateTime(r.paidAt)}</td>
          </tr>
        ))}
      </tbody>
    </table>
  );
}
