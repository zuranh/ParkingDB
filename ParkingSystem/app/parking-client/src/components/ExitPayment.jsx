import { useState } from "react";
import { api, errorMessage, money } from "../api.js";
import { PageHead, Banner, Ticket, Field, Segmented } from "./ui.jsx";

const METHODS = ["Cash", "Card", "Mobile"].map((m) => ({ value: m, label: m }));

// Exit: usp_VehicleExit (the database computes the fee)
// Payment: usp_RecordPayment (the amount is NOT sent: the database takes it from the session)
export default function ExitPayment() {
  const [plate, setPlate] = useState("");
  const [exitMsg, setExitMsg] = useState(null);
  const [ticket, setTicket] = useState(null);
  const [sessionId, setSessionId] = useState("");
  const [method, setMethod] = useState("Cash");
  const [payMsg, setPayMsg] = useState(null);

  async function exit(e) {
    e.preventDefault();
    setExitMsg(null);
    setTicket(null);
    setPayMsg(null);
    try {
      const r = await api("POST", "/api/exits", { licensePlate: plate });
      const shownPlate = plate.trim().toUpperCase();
      setSessionId(String(r.sessionID));     // fill in step 2 for the user
      setTicket(
        Number(r.fee) === 0
          ? { kind: "ok", caption: "Nothing to pay", big: "Free", detail: `${shownPlate}  ·  10 minutes or less  ·  session #${r.sessionID}` }
          : { kind: "info", caption: "Fee to pay", big: money(r.fee), detail: `${shownPlate}  ·  session #${r.sessionID}  ·  now record the payment below` }
      );
      setPlate("");
    } catch (err) {
      setExitMsg(errorMessage(err));
    }
  }

  async function pay(e) {
    e.preventDefault();
    setPayMsg(null);
    try {
      const r = await api("POST", "/api/payments", { sessionId: Number(sessionId), method });
      setPayMsg({ kind: "ok", text: `Payment #${r.paymentId} recorded: session #${sessionId}, paid by ${method}.` });
    } catch (err) {
      setPayMsg(errorMessage(err));
    }
  }

  return (
    <section>
      <PageHead title="Exit & payment" subtitle="Record a car leaving, then its payment." />

      <form className="card narrow" onSubmit={exit} autoComplete="off">
        <h2><span className="step">1</span>Car leaves</h2>
        <p className="muted">
          The database closes the visit and calculates the fee: the first 10 minutes are free, then every started hour costs the hourly rate of the space type.
        </p>
        <Field label="License plate">
          <input value={plate} onChange={(e) => setPlate(e.target.value)} maxLength={15} placeholder="e.g. B 123456" required />
        </Field>
        <div className="actions"><button className="btn primary" type="submit">Record exit</button></div>
      </form>

      <Banner msg={exitMsg} />
      <Ticket t={ticket} />

      <form className="card narrow" onSubmit={pay} autoComplete="off">
        <h2><span className="step">2</span>Payment</h2>
        <p className="muted">
          The amount is not typed here: the database takes it from the visit's fee, so nobody can pay less than they owe.
        </p>
        <div className="row">
          <Field label="Session #" help="Filled in automatically after an exit.">
            <input type="number" min={1} value={sessionId} onChange={(e) => setSessionId(e.target.value)} placeholder="filled after an exit" required />
          </Field>
          <Field label="Method" group>
            <Segmented options={METHODS} value={method} onChange={setMethod} />
          </Field>
        </div>
        <div className="actions"><button className="btn primary" type="submit">Record payment</button></div>
      </form>

      <Banner msg={payMsg} />
    </section>
  );
}
