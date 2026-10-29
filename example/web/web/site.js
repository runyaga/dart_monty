const siteBase = new URL('.', document.currentScript.src);
(async () => {
 const root = document.documentElement;
 root.dataset.theme = localStorage.getItem('theme') || (matchMedia('(prefers-color-scheme: dark)').matches ? 'dark' : 'light');
 const applyTheme = () => {document.body.dataset.mdColorScheme = root.dataset.theme === 'dark' ? 'slate' : 'default';};
 applyTheme();
 const nav = await fetch(new URL('nav.inc', siteBase)); if (!nav.ok) throw Error('Navigation unavailable');
 document.getElementById('site-nav').innerHTML = await nav.text();
 document.querySelectorAll('#site-nav a').forEach(a => a.href = new URL(a.getAttribute('href'), siteBase));
 document.getElementById('theme').onclick = () => {root.dataset.theme = root.dataset.theme === 'dark' ? 'light' : 'dark';localStorage.setItem('theme',root.dataset.theme);applyTheme();};
 const meta = await (await fetch(new URL('build-meta.json', siteBase))).json();
 document.querySelectorAll('.version-badge').forEach(n => n.textContent = `dart_monty ${meta.runtime} · dart_monty_core ${meta.coreVersion} (${meta.coreRef}) · upstream ${meta.upstream}`);
})().catch(e => {document.getElementById('site-nav').textContent = e.message;window.__montyDemoError = e.message;});
