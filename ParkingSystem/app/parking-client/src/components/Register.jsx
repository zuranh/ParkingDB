import { useState } from "react";
import { api, errorMessage } from "../api.js";
import { PageHead, Banner, Field, Segmented } from "./ui.jsx";

const EMPTY = { licensePlate: "", ownerName: "", phone: "", vehicleType: "Car" };
const TYPES = ["Car", "Motorcycle", "Van"].map((t) => ({ value: t, label: t }));

// Register vehicle: usp_RegisterVehicle
// The page does NOT check the rules itself: the database does (CHECK constraints),
// so they can never be bypassed. The page only shows the database's answer.
export default function Register() {
  const [form, setForm] = useState(EMPTY);
  const [msg, setMsg] = useState(null);

  // One function updates any field: set("ownerName")(event)
  const set = (name) => (e) => setForm({ ...form, [name]: e.target.value });

  async function submit(e) {
    e.preventDefault();
    setMsg(null);
    try {
      const result = await api("POST", "/api/vehicles", {
        licensePlate: form.licensePlate,
        ownerName: form.ownerName,
        phone: form.phone.trim() === "" ? null : form.phone,
        vehicleType: form.vehicleType,
      });
      setMsg({
        kind: "ok",
        text: `${form.licensePlate.trim().toUpperCase()} registered for ${form.ownerName.trim()} (vehicle #${result.vehicleId}). It can now use the Entry tab.`,
      });
      setForm(EMPTY);
    } catch (err) {
      setMsg(errorMessage(err));
    }
  }

  return (
    <section>
      <PageHead title="Register a vehicle" subtitle="Add a car once. After that it can enter and leave as often as it likes." />

      <form className="card narrow" onSubmit={submit} autoComplete="off">
        <h2>Vehicle details</h2>
        <p className="muted">Every rule is checked by the database itself, so it can never be bypassed.</p>

        <div className="row">
          <Field label="License plate" help="Letters A-Z, digits, spaces, hyphens. Saved in capitals.">
            <input value={form.licensePlate} onChange={set("licensePlate")} maxLength={15} placeholder="e.g. B 123456" required />
          </Field>
          <Field label="Vehicle type" group>
            <Segmented options={TYPES} value={form.vehicleType} onChange={(v) => setForm({ ...form, vehicleType: v })} />
          </Field>
        </div>

        <div className="row">
          <Field label="Owner name" help="At least 2 characters, no digits or symbols.">
            <input value={form.ownerName} onChange={set("ownerName")} maxLength={100} placeholder="e.g. Maya Haddad" required />
          </Field>
          <Field label="Phone" help="Digits, spaces, hyphens, one leading +. 7 to 15 digits.">
            <input value={form.phone} onChange={set("phone")} maxLength={20} placeholder="optional, e.g. +961 71 123456" />
          </Field>
        </div>

        <div className="actions">
          <button className="btn primary" type="submit">Register vehicle</button>
          <button className="btn secondary" type="button" onClick={() => { setForm(EMPTY); setMsg(null); }}>Clear</button>
        </div>
      </form>

      <Banner msg={msg} />
    </section>
  );
}
