import { useEffect, useState } from "react";
import { api, errorMessage, money, time } from "../api.js";
import { PageHead, Banner, Ticket, Field, Segmented } from "./ui.jsx";

// Entry: usp_VehicleEntry. The DATABASE chooses the space (lowest free one,
// locked with UPDLOCK + READPAST so two cars never get the same space).
export default function Entry() {
  const [plate, setPlate] = useState("");
  const [types, setTypes] = useState([]);        // from vw_SpaceStatus
  const [typeId, setTypeId] = useState(null);    // null = any type
  const [msg, setMsg] = useState(null);
  const [ticket, setTicket] = useState(null);

  // Load the space types once, for the buttons.
  useEffect(() => {
    api("GET", "/api/space-types").then(setTypes).catch(() => setTypes([]));
  }, []);

  const options = [
    { value: null, label: "Any type" },
    ...types.map((t) => ({ value: t.spaceTypeID, label: `${t.typeName} · ${money(t.hourlyRate)}/h` })),
  ];

  async function submit(e) {
    e.preventDefault();
    setMsg(null);
    setTicket(null);
    try {
      const r = await api("POST", "/api/entries", { licensePlate: plate, spaceTypeId: typeId });
      const floor = /^F(\d)/.exec(r.spaceCode)?.[1] ?? "?";   // codes look like F1-042
      setTicket({
        kind: "ok",
        caption: "Go to space",
        big: r.spaceCode,
        detail: `Floor ${floor}  ·  ${plate.trim().toUpperCase()}  ·  entered ${time(new Date())}  ·  session #${r.sessionID}`,
      });
      setPlate("");
    } catch (err) {
      setMsg(errorMessage(err));
    }
  }

  return (
    <section>
      <PageHead title="Entry" subtitle="Record a car arriving at the gate." />

      <form className="card narrow" onSubmit={submit} autoComplete="off">
        <h2>Car arrives</h2>
        <p className="muted">
          The database gives the car the lowest-numbered free space. Two cars arriving at the same moment never get the same space.
        </p>
        <Field label="License plate" help="The car must be registered first.">
          <input value={plate} onChange={(e) => setPlate(e.target.value)} maxLength={15} placeholder="e.g. B 123456" required />
        </Field>
        <Field label="Space type" group help='Leave "Any type" unless the car needs a special space (EV charger, accessible ...).'>
          <Segmented options={options} value={typeId} onChange={setTypeId} />
        </Field>
        <div className="actions">
          <button className="btn primary" type="submit">Let the car in</button>
        </div>
      </form>

      <Banner msg={msg} />
      <Ticket t={ticket} />
    </section>
  );
}
