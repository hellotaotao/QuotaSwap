// Interactive preview of the QuotaSwap menu. Mirrors the app's layout and
// pace rule: red when usage leads elapsed time by more than 5 points,
// green when it trails by more than 5, yellow in between.

const HOUR = 3600;
const WINDOWS = { five: 5 * HOUR, week: 7 * 24 * HOUR };

const accounts = [
  { id: "a", email: "alex@acme.dev", name: "work",
    five: { used: 42, elapsed: 0.13 }, week: { used: 26, elapsed: 0.62 } },
  { id: "b", email: "alex@sidequest.dev", name: "personal",
    five: { used: 0, elapsed: 0.27 }, week: { used: 88, elapsed: 0.79 } },
];

const state = { current: "a", pending: null, busy: null };

const panel = document.getElementById("panel");
const statusItem = document.getElementById("status-item");
const statusText = document.getElementById("status-text");
const hint = document.getElementById("panel-hint");

function pace(used, elapsed) {
  if (used >= 100) return "over";
  const lead = used - elapsed * 100;
  return lead > 5 ? "over" : lead < -5 ? "under" : "even";
}

function untilReset(elapsed, length) {
  const minutes = Math.round(((1 - elapsed) * length) / 60);
  if (minutes >= 1440) return `${Math.floor(minutes / 1440)}d ${Math.floor((minutes % 1440) / 60)}h`;
  if (minutes >= 60) return `${Math.floor(minutes / 60)}h ${minutes % 60}m`;
  return `${minutes}m`;
}

function bar(label, window, length) {
  return `
    <div class="p-bar">
      <span class="label">${label}</span>
      <span class="track">
        <span class="fill ${pace(window.used, window.elapsed)}" style="width:${window.used}%"></span>
        <span class="tick" style="left:${window.elapsed * 100}%"></span>
      </span>
      <span class="value">${window.used}%</span>
      <span class="reset">↻ ${untilReset(window.elapsed, length)}</span>
    </div>`;
}

function account(a) {
  const current = a.id === state.current;
  const action = !current && !state.pending && !state.busy
    ? `<button class="p-button" type="button" data-use="${a.id}">Use account</button>` : "";
  const confirm = state.pending === a.id ? `
    <div class="p-confirm">
      <p>Claude restarts signed in as ${a.email}.</p>
      <div>
        <button class="p-button plain" type="button" data-cancel>Cancel</button>
        <button class="p-button primary" type="button" data-switch="${a.id}">Switch</button>
      </div>
    </div>` : "";
  return `
    <div class="p-account${current ? " is-current" : ""}">
      <div class="p-row">
        <span class="p-mark" aria-hidden="true"></span>
        <div class="p-who">
          <div class="p-email">${a.email}</div>
          <div class="p-name">${current ? `${a.name} · signed in` : a.name}</div>
        </div>
        ${action}
      </div>
      ${confirm}
      ${bar("5h", a.five, WINDOWS.five)}
      ${bar("Week", a.week, WINDOWS.week)}
    </div>`;
}

function render(focusSelector) {
  const busy = state.busy
    ? `<div class="p-busy"><span class="spinner" aria-hidden="true"></span>Switching to ${state.busy} ...</div>` : "";
  panel.innerHTML = `
    <div class="p-header"><span class="p-title">QuotaSwap</span><span class="p-sub">${accounts.length} accounts</span></div>
    ${accounts.map(account).join("")}
    ${busy}
    <div class="p-footer"><span>Add account…</span><span>Quit</span></div>`;
  const current = accounts.find((a) => a.id === state.current);
  statusText.textContent = `5h ${current.five.used}% · Wk ${current.week.used}%`;
  if (focusSelector) panel.querySelector(focusSelector)?.focus();
}

panel.addEventListener("click", (event) => {
  const target = event.target.closest("button");
  if (!target) return;
  if (target.dataset.use) {
    state.pending = target.dataset.use;
    render(`[data-switch="${state.pending}"]`);
  } else if (target.hasAttribute("data-cancel")) {
    const id = state.pending;
    state.pending = null;
    render(`[data-use="${id}"]`);
  } else if (target.dataset.switch) {
    const next = accounts.find((a) => a.id === target.dataset.switch);
    const previous = state.current;
    state.pending = null;
    state.busy = next.email;
    render();
    setTimeout(() => {
      state.busy = null;
      state.current = next.id;
      render(`[data-use="${previous}"]`);
      hint.textContent = `Switched. The menu bar now shows ${next.email}'s usage.`;
    }, 1200);
  }
});

statusItem.addEventListener("click", () => {
  const open = statusItem.getAttribute("aria-expanded") !== "true";
  statusItem.setAttribute("aria-expanded", String(open));
  panel.hidden = !open;
});

document.querySelectorAll("[data-copy]").forEach((button) => {
  button.addEventListener("click", async () => {
    const text = document.getElementById(button.dataset.copy).textContent;
    try {
      await navigator.clipboard.writeText(text);
      button.textContent = "Copied";
    } catch {
      button.textContent = "Press ⌘C";
      getSelection().selectAllChildren(document.getElementById(button.dataset.copy));
    }
    setTimeout(() => { button.textContent = "Copy"; }, 1600);
  });
});

render();
