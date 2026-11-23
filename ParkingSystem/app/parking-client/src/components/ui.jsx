// Small building blocks used by every screen.
// React puts all text on the page as TEXT, never as HTML, so a name like
// <script>...</script> typed in a form is shown as letters and never runs (no XSS).

/** Page title with a one-line explanation. */
export function PageHead({ title, subtitle, children }) {
  return (
    <div className="page-head">
      <div>
        <h1>{title}</h1>
        <p className="subtitle">{subtitle}</p>
      </div>
      {children}
    </div>
  );
}

/** Green (ok) or red (error) message strip. msg = { kind, text, number } or null. */
export function Banner({ msg }) {
  if (!msg) return null;
  return (
    <div className={`banner ${msg.kind}`}>
      {msg.kind === "ok" ? "✓ " : "✕ "}
      {msg.text}
      {msg.number ? <span className="code">[error {msg.number}]</span> : null}
    </div>
  );
}

/** The big result ticket. t = { kind, caption, big, detail } or null. */
export function Ticket({ t }) {
  if (!t) return null;
  return (
    <div className={`ticket ${t.kind}`}>
      <div className="caption">{t.caption}</div>
      <div className="big">{t.big}</div>
      <div className="detail">{t.detail}</div>
    </div>
  );
}

/** One input with its label above and an optional help line below.
 *  group = true for a row of buttons (a <div>, because a <label> around
 *  buttons would "click" the first button when the label is clicked). */
export function Field({ label, help, group = false, children }) {
  const Tag = group ? "div" : "label";
  return (
    <Tag className="field">
      <span>{label}</span>
      {children}
      {help && <small>{help}</small>}
    </Tag>
  );
}

/** A row of buttons where exactly one is selected (like radio buttons).
 *  options = [{ value, label }]. */
export function Segmented({ options, value, onChange }) {
  return (
    <div className="segmented">
      {options.map((o) => (
        <button
          type="button"
          key={String(o.value)}
          className={"seg" + (o.value === value ? " active" : "")}
          onClick={() => onChange(o.value)}
        >
          {o.label}
        </button>
      ))}
    </div>
  );
}
