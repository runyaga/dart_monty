const $ = id => document.getElementById(id);
let catalog, selected, busy = false, feedCount = 0;
const api = () => window.VfsDemo || window.ReplSessionDemo;
function transcript(text) {
 const target = $('transcript'); if (!target) return;
 const entry = document.createElement('pre'); entry.textContent = text;
 target.appendChild(entry); target.scrollTop = target.scrollHeight;
}
window._onToolCall = payload => { const e=JSON.parse(payload); transcript('↳ ' + JSON.stringify(e)); };
window._onOsCall = () => {};
window._onFilesChanged = () => {};
const dataReady = fetch('examples.json').then(r => {if (!r.ok) throw Error('Examples unavailable'); return r.json();}).then(all => {
 catalog = all.filter(e => e.pages.includes(document.body.dataset.page) && e.setup !== 'bridge-walkthrough');
 selectExample();
});
function selectExample() {
 selected = catalog.find(e => e.id === $('examples').value);
 $('editor').value = selected.code;
 $('detail').textContent = selected.stagedFiles ? 'Dart stages these memory files before Run:\n' + JSON.stringify(selected.stagedFiles, null, 2) : 'Setup: ' + selected.setup;
 $('expected').textContent = 'Exact expected ' + (selected.error ? 'Python exception: ' + selected.error : 'value: ' + JSON.stringify(selected.expected));
}
$('examples').onchange = selectExample;
window._onReady = async () => {await dataReady; $('status').textContent = 'Ready'; $('run').disabled = false; $('resetBtn').disabled = false;};
async function run() {
 if (busy) throw Error('Execution already active');
 busy = true; $('run').disabled = true; $('resetBtn').disabled = true;
 try {
  if (window.VfsDemo) {
   window.VfsDemo.clearMounts();
   for (const [path, text] of Object.entries(selected.stagedFiles || {})) await window.VfsDemo.mountFile(path, text);
  }
  const code = (selected.setup === 'denied' ? '# denied\n' : '') + $('editor').value;
  feedCount++;
  transcript('>>> ' + code.replaceAll('\n','\n... '));
  const started = performance.now();
  const result = JSON.parse(await api().run(code));
  transcript((result.print_output || '') + '\n' + (result.ok ? JSON.stringify(result.value) : result.error) + ' [' + (performance.now()-started).toFixed(1) + 'ms]');
  $('output').textContent = JSON.stringify(result.value ?? null) + '\n' + (result.print_output || result.error || '');
  $('detail').textContent = JSON.stringify(result, null, 2);
  const ok = selected.error ? !result.ok && (result.excType === selected.error || (result.error || '').includes(selected.error)) : result.ok && JSON.stringify(result.value) === JSON.stringify(selected.expected);
  if (selected.id === 'tools' && document.body.dataset.page !== 'repl' && result.toolCalls !== 1) throw Error('Expected exactly one tools.add callback');
  const scans = ['walk','glob'].includes(selected.id);
  const scanned = !scans || result.osCallLog.some(e => /scan/i.test(e.op));
  if (window.VfsDemo && !result.files.some(f => f.path === '/sandbox/a.csv' && f.preview === 'a,b\n1,2\n')) throw Error('File inspector mismatch');
  $('status').textContent = ok && scanned ? 'Expected output matched' : 'Output mismatch';
  if ($('transcript')) $('status').textContent += ' (' + feedCount + ')';
  return JSON.stringify({ok:ok && scanned, status:$('status').textContent, detail:JSON.stringify(result)});
 } finally {busy = false; $('run').disabled = false; $('resetBtn').disabled = false;}
}
$('run').onclick = () => {window.__lastRun = run().catch(e => {
 $('status').textContent = e.message;
 return JSON.stringify({ok:false,status:'Error',detail:e.message});
});};
async function reset() {
 if (busy) throw Error('Execution already active');
 if (api().reset) {
  const r = JSON.parse(await api().reset()); if (!r.ok) throw Error(r.error);
 } else api().clearMounts();
 feedCount = 0;
 if ($('transcript')) { $('transcript').textContent = ''; transcript('--- Session reset ---'); }
 $('output').textContent = ''; $('detail').textContent = ''; $('status').textContent = 'Reset complete';
}
$('resetBtn').onclick = () => {window.__lastReset = reset();};
async function clickReset() { $('resetBtn').click(); await window.__lastReset; }
window.__montyRunExample = async key => {
 await dataReady;
 const example = catalog.find(e => e.id === key);
 if (example.requires) await window.__montyRunExample(example.requires);
 $('examples').value = key; $('examples').dispatchEvent(new Event('change'));
 $('run').click();
 return window.__lastRun;
};
window.__montyCheckControls = async () => {
 if (window.VfsDemo) {
  await api().mountFile('/sandbox/reset-check.txt', 'saved');
  let r = JSON.parse(await api().run('open("/sandbox/reset-check.txt").read()'));
  if (!r.ok || r.value !== 'saved') throw Error('Staging failed');
  await clickReset();
  r = JSON.parse(await api().run('from pathlib import Path\nPath("/sandbox/reset-check.txt").exists()'));
  if (!r.ok || r.value !== false) throw Error('Reset kept staged file');
  return true;
 }
 let r = JSON.parse(await api().run('from pathlib import Path\nPath("/work/reset-check.txt").write_text("saved")\n42'));
 if (!r.ok || r.value !== 42) throw Error('Reset setup failed');
 await clickReset();
 r = JSON.parse(await api().run('from pathlib import Path\nPath("/work/reset-check.txt").exists()'));
 if (!r.ok || r.value !== false) throw Error('Reset retained a file');
 r = JSON.parse(await api().run('40 + 2'));
 if (!r.ok || r.value !== 42) throw Error('Recovery failed');
 return true;
};
setTimeout(() => {if ($('run').disabled) {window.__montyDemoError = 'Worker startup exceeded 60 seconds'; $('status').textContent = window.__montyDemoError;}},60000);

$('editor').addEventListener('keydown', e => {
 if ((e.key === 'Enter' && (e.ctrlKey || e.metaKey || (document.body.dataset.page === 'repl' && !e.shiftKey)))) {
  e.preventDefault(); if (!busy && !$('run').disabled) $('run').click();
 }
 if (e.key === 'Tab') {
  e.preventDefault(); const editor=$('editor'), start=editor.selectionStart;
  editor.setRangeText('    ', start, editor.selectionEnd, 'end');
 }
});
