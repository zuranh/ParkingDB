// =====================================================================
// The ONLY place the front end talks to the back end.
// Every call goes to OUR C# Web API (/api/...), which runs one stored
// procedure through ADO.NET. The browser never sees SQL or the password.
// =====================================================================

/** Calls the Web API. On a refusal it throws an Error whose message is the
 *  database's own text and whose .number is the error number (50001-50009). */
export async function api(method, url, body) {
  const options = { method, headers: {} };
  if (body !== undefined) {
    options.headers["Content-Type"] = "application/json";
    options.body = JSON.stringify(body);
  }

  let response;
  try {
    response = await fetch(url, options);
  } catch {
    throw Object.assign(new Error("The web server is not running. Start it with run_app.bat."), { number: 0 });
  }

  const data = await response.json().catch(() => null);
  if (!response.ok) {
    throw Object.assign(new Error(data?.error ?? `Request failed (${response.status})`), { number: data?.number ?? 0 });
  }
  return data;
}

// ---------- formatting helpers ----------
export const money = (v) => (v === null || v === undefined ? "" : Number(v).toFixed(2));

export const dateTime = (v) =>
  v ? new Date(v).toLocaleString([], { year: "numeric", month: "2-digit", day: "2-digit", hour: "2-digit", minute: "2-digit" }) : "";

export const time = (v) => (v ? new Date(v).toLocaleTimeString([], { hour: "2-digit", minute: "2-digit" }) : "");

export const day = (v) => (v ? new Date(v).toLocaleDateString([], { year: "numeric", month: "short", day: "2-digit" }) : "");

/** Turns a caught error into the message object the <Banner> shows. */
export const errorMessage = (err) => ({ kind: "error", text: err.message, number: err.number });
