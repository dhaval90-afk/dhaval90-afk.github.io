// Requires auth.js to be loaded first. Call renderNav('pipeline') etc. after
// the DOM is ready, passing the current page's key.
const NAV_ITEMS = [
  { key: 'dashboard', label: 'Dashboard', href: 'index.html' },
  { key: 'pipeline', label: 'Pipeline', href: 'pipeline.html' },
  { key: 'tasks', label: 'Tasks', href: 'tasks.html' },
  { key: 'import', label: 'Import', href: 'import.html' },
];

async function renderNav(activeKey) {
  const el = document.getElementById('nav');
  if (!el) return;
  const label = await currentUserLabel();
  el.innerHTML = `
    <div class="nav-inner">
      <a class="brand" href="index.html">Workhall <span>Leads</span></a>
      <div class="nav-links">
        ${NAV_ITEMS.map(
          (item) =>
            `<a href="${item.href}" class="${item.key === activeKey ? 'active' : ''}">${item.label}</a>`
        ).join('')}
      </div>
      <div class="nav-user">
        <span>${label}</span>
        <button id="signOutBtn" class="btn-ghost">Sign out</button>
      </div>
    </div>
  `;
  const btn = document.getElementById('signOutBtn');
  if (btn) btn.addEventListener('click', signOut);
}
