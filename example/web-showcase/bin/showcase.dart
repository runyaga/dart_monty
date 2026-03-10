/// Web Showcase — Python manipulating the browser via Dart host functions.
///
/// Host function dispatch loop:
///   start(code, extFns) → pending? → handler → resume(result) → ...
///
/// Host functions: dom_create, dom_text, dom_append, dom_query, dom_style,
///   dom_attr, dom_html, dom_remove, fetch_text, fetch_json,
///   storage_get, storage_set, log, alert, now
library;

import 'dart:async';
import 'dart:convert';
import 'dart:js_interop';

import 'package:web/web.dart';

// ── JS interop bindings ────────────────────────────────────────────────────

@JS('DartMontyBridge.init')
external JSPromise<JSBoolean> _bridgeInit();

@JS('DartMontyBridge.start')
external JSPromise<JSString> _bridgeStart(
  JSString code, [
  JSString? extFnsJson,
]);

@JS('DartMontyBridge.snapshot')
external JSPromise<JSString> _bridgeSnapshot();

@JS('DartMontyBridge.restore')
external JSPromise<JSString> _bridgeRestore(JSString dataBase64);

@JS('DartMontyBridge.resume')
external JSPromise<JSString> _bridgeResume(JSString valueJson);

@JS('DartMontyBridge.resumeWithError')
external JSPromise<JSString> _bridgeResumeWithError(JSString errorJson);

@JS('fetch')
external JSPromise<_JsResponse> _jsFetch(JSString url);

extension type _JsResponse(JSObject _) implements JSObject {
  external JSPromise<JSString> text();
}

Map<String, dynamic> _parse(String json) =>
    jsonDecode(json) as Map<String, dynamic>;

// ── Opaque handle system ───────────────────────────────────────────────────

int _nextHandle = 1;
final Map<int, Element> _handles = {};

int _store(Element el) {
  final h = _nextHandle++;
  _handles[h] = el;
  return h;
}

Element? _get(int h) => _handles[h];

void _free(int h) => _handles.remove(h);

// ── Output logging ─────────────────────────────────────────────────────────

void _log(String msg) {
  final el = document.getElementById('output');
  if (el != null) {
    el.textContent = '${el.textContent}$msg\n';
  }
  print(msg);
}

void _clearOutput() {
  final el = document.getElementById('output');
  if (el != null) el.textContent = '';
}

void _clearSandbox() {
  final el = document.getElementById('sandbox');
  if (el != null) el.innerHTML = ''.toJS;
  _handles.clear();
  _nextHandle = 1;
}

// ── Host function list ─────────────────────────────────────────────────────

const List<String> _hostFunctions = [
  'dom_create',
  'dom_text',
  'dom_get_text',
  'dom_append',
  'dom_query',
  'dom_style',
  'dom_attr',
  'dom_html',
  'dom_remove',
  'dom_set_value',
  'dom_get_value',
  'dom_on_click',
  'fetch_text',
  'fetch_json',
  'storage_get',
  'storage_set',
  'log',
  'alert',
  'now',
  'interpreter_snapshot',
  'interpreter_restore',
  'download_file',
  'upload_file',
  'json_dumps',
  'json_loads',
  'dom_await_click_any',
];

// ── Host function dispatch ─────────────────────────────────────────────────

Future<Object?> _dispatch(String fnName, List<dynamic> args) async {
  switch (fnName) {
    case 'dom_create':
      final tag = args.isNotEmpty ? args[0] as String : 'div';
      final el = document.createElement(tag);
      return _store(el);

    case 'dom_text':
      final h = args[0] as int;
      final text = args[1] as String;
      _get(h)?.textContent = text;
      return null;

    case 'dom_get_text':
      final h = args[0] as int;
      return _get(h)?.textContent;

    case 'dom_append':
      final parentH = args[0] as int;
      final childH = args[1] as int;
      final parent = _get(parentH);
      final child = _get(childH);
      if (parent != null && child != null) parent.appendChild(child);
      return null;

    case 'dom_query':
      final selector = args[0] as String;
      final el = document.querySelector(selector);
      if (el == null) return null;
      return _store(el);

    case 'dom_style':
      final h = args[0] as int;
      final prop = args[1] as String;
      final val = args[2] as String;
      final el = _get(h);
      if (el != null) {
        (el as HTMLElement).style.setProperty(prop, val);
      }
      return null;

    case 'dom_attr':
      final h = args[0] as int;
      final attr = args[1] as String;
      final val = args[2] as String;
      _get(h)?.setAttribute(attr, val);
      return null;

    case 'dom_html':
      final h = args[0] as int;
      final html = args[1] as String;
      _get(h)?.innerHTML = html.toJS;
      return null;

    case 'dom_remove':
      final h = args[0] as int;
      _get(h)?.remove();
      _free(h);
      return null;

    case 'dom_set_value':
      final h = args[0] as int;
      final val = args[1] as String;
      final svEl = _get(h);
      if (svEl != null && svEl.isA<HTMLInputElement>()) {
        (svEl as HTMLInputElement).value = val;
      } else if (svEl != null && svEl.isA<HTMLTextAreaElement>()) {
        (svEl as HTMLTextAreaElement).value = val;
      } else if (svEl != null && svEl.isA<HTMLSelectElement>()) {
        (svEl as HTMLSelectElement).value = val;
      }
      return null;

    case 'dom_get_value':
      final h = args[0] as int;
      final gvEl = _get(h);
      if (gvEl != null && gvEl.isA<HTMLInputElement>()) {
        return (gvEl as HTMLInputElement).value;
      } else if (gvEl != null && gvEl.isA<HTMLTextAreaElement>()) {
        return (gvEl as HTMLTextAreaElement).value;
      } else if (gvEl != null && gvEl.isA<HTMLSelectElement>()) {
        return (gvEl as HTMLSelectElement).value;
      }
      return null;

    case 'dom_on_click':
      final h = args[0] as int;
      final el = _get(h);
      if (el == null) return null;
      final completer = Completer<String>();
      el.addEventListener(
        'click',
        (Event e) {
          if (!completer.isCompleted) completer.complete('clicked');
        }.toJS,
      );
      return await completer.future;

    case 'fetch_text':
      final url = args[0] as String;
      final resp = await _jsFetch(url.toJS).toDart;
      return (await resp.text().toDart).toDart;

    case 'fetch_json':
      final url = args[0] as String;
      final resp = await _jsFetch(url.toJS).toDart;
      final body = (await resp.text().toDart).toDart;
      return jsonDecode(body);

    case 'storage_get':
      final key = args[0] as String;
      return window.localStorage.getItem(key);

    case 'storage_set':
      final key = args[0] as String;
      final val = args[1] as String;
      window.localStorage.setItem(key, val);
      return null;

    case 'log':
      final msg = args.isNotEmpty ? args[0].toString() : '';
      _log(msg);
      return null;

    case 'alert':
      final msg = args.isNotEmpty ? args[0].toString() : '';
      window.alert(msg);
      return null;

    case 'now':
      return DateTime.now().toIso8601String();

    case 'interpreter_snapshot':
      final result = _parse((await _bridgeSnapshot().toDart).toDart);
      if (result['ok'] == true) {
        return result['data'] as String;
      }
      return 'Error: ${result['error']}';

    case 'interpreter_restore':
      final data = args[0] as String;
      final result = _parse((await _bridgeRestore(data.toJS).toDart).toDart);
      if (result['ok'] == true) return 'restored';
      return 'Error: ${result['error']}';

    case 'download_file':
      final filename = args[0] as String;
      final content = args[1] as String;
      final anchor = document.createElement('a') as HTMLAnchorElement;
      final encoded = Uri.encodeComponent(content);
      anchor.href = 'data:text/plain;charset=utf-8,$encoded';
      anchor.download = filename;
      anchor.style.display = 'none';
      document.body!.appendChild(anchor);
      anchor.click();
      anchor.remove();
      return null;

    case 'upload_file':
      final input = document.createElement('input') as HTMLInputElement;
      input.type = 'file';
      final completer = Completer<String?>();
      input.addEventListener(
        'change',
        (Event e) {
          final files = input.files;
          if (files == null || files.length == 0) {
            completer.complete(null);
            return;
          }
          final file = files.item(0)!;
          final reader = FileReader();
          reader.addEventListener(
            'load',
            (Event ev) {
              final text = (reader.result as JSString?)?.toDart ?? '';
              completer.complete(text);
            }.toJS,
          );
          reader.readAsText(file);
        }.toJS,
      );
      input.click();
      return await completer.future;

    case 'json_dumps':
      return jsonEncode(args[0]);

    case 'json_loads':
      final s = args[0] as String;
      if (s.isEmpty) return <String, dynamic>{};
      return jsonDecode(s);

    case 'dom_await_click_any':
      final handles = (args[0] as List<dynamic>).cast<int>();
      final completer = Completer<int>();
      for (final h in handles) {
        final el = _get(h);
        if (el != null) {
          el.addEventListener(
            'click',
            (Event e) {
              if (!completer.isCompleted) completer.complete(h);
            }.toJS,
          );
        }
      }
      return await completer.future;

    default:
      return 'Unknown host function: $fnName';
  }
}

// ── Execution loop ─────────────────────────────────────────────────────────

Future<Map<String, dynamic>> _runWithHostFunctions(String code) async {
  final extFnsJson = jsonEncode(_hostFunctions);
  var result = _parse(
    (await _bridgeStart(code.toJS, extFnsJson.toJS).toDart).toDart,
  );

  while (result['state'] == 'pending') {
    final fnName = result['functionName'] as String;
    final fnArgs = (result['args'] as List<dynamic>?) ?? [];

    try {
      final value = await _dispatch(fnName, fnArgs);
      result = _parse(
        (await _bridgeResume(jsonEncode(value).toJS).toDart).toDart,
      );
    } on Exception catch (e) {
      result = _parse(
        (await _bridgeResumeWithError(
          jsonEncode(e.toString()).toJS,
        ).toDart).toDart,
      );
    }
  }

  return result;
}

// ── Demo scripts ───────────────────────────────────────────────────────────

const Map<String, String> _demos = {
  'hello': '''
app = dom_query("#sandbox")
h1 = dom_create("h1")
dom_text(h1, "HEAR YE, HEAR YE!")
dom_style(h1, "color", "#00d4ff")
dom_style(h1, "text-shadow", "0 0 20px #00d4ff, 0 0 40px #0066ff")
dom_style(h1, "font-family", "monospace")
dom_append(app, h1)

p = dom_create("p")
dom_text(p, "This text was created by PYTHON running inside your BROWSER.")
dom_style(p, "color", "#aaa")
dom_style(p, "font-size", "14px")
dom_append(app, p)

p2 = dom_create("p")
dom_text(p2, "No server. No native binary. Just Dart bridging Python to the DOM.")
dom_style(p2, "color", "#569cd6")
dom_style(p2, "margin-top", "8px")
dom_append(app, p2)

log("The Word of Dart has been spoken.")
''',
  'altar': '''
app = dom_query("#sandbox")

# The Sacred Stencil of "Bob"
bob = dom_create("pre")
dom_style(bob, "color", "#00d4ff")
dom_style(bob, "font-size", "8px")
dom_style(bob, "line-height", "1.05")
dom_style(bob, "text-align", "center")
dom_style(bob, "text-shadow", "0 0 6px #0066ff")

stencil = """
                     ######################
                  ############################
                ########################### #####
               ##############  #######  ##   # ####
             ###########   ##   ###  ##  #   #  ####
            ####.###  # #   ##   ###  #  #   ## # ##
           ####..###   # #   ##   ###  #  ##  # # ###
          #####..####  # #    #    ##  #  ### # ## ####
         #####...##### ####   #  # ##   # ##### ## #####
        ######...###########  ## # #### # ################
       ######...############### ###### #####################
      ######...##......############### #########   ########
      ######..##.........############ #######     ####.###
      ######.##...........#################        ####..###
      ########.............###########             ####..###
     #######...            ########                 ###..###
     ######...                                      ###..##
     ######...                                      ###..##
     #####....                                    . ###..##
     #####....                                    .  ##..##
     #####....                                    .  ##..##
     #####....                                   ..  ###.##
     #####....                                  ...  ###.##
     #####....                                   ..  ###.##
     #####....                                   ..  ###.##
     #####....                                   ..  ###.##
      ####....                             ####  .. ####.##
     # ###.... #########                #########.. #######
    ### ##...  ##########              ###########.. ######
    ####  ...          ###           ####       ##.. ######
    ######...    ##### ####         ##########   #.. ######
     #### ...  ###     #####       ######    ###  ... #####
     ####     ######### ####      ##############   .  #####
     ####     ###  # ##  ####    ######  # #  ##      ####
     ####      #   ### ...###         .. ###          ####
     ####             .... ##         ......  ...     ####
      ####      ... .....   #           .......       ####
      ####        .....    ##             ...         ## #
      ## #          ..     #                          # ##
      # ##                 #                          #  #
      # ##  #             .#                         ##  #
      #  #  #            ..#                          ####
       ###  ##         # ...                       # # ##
        ##  ##        # ....          # ###       ## #
         # ###     ##  ....        ###  ###     ### #
         # ###    ##  ...###     ####    ####  #### #
         #########   ##############      ######### #
          #######   ##############         ######## #
          ###### ..##############      ##############
          ### ##  .##########      #########    ####
           ##  #   ####     ########    ##      ###
           ##  #   .####               ##      ####
            #  #   ....### #############       ###
            ## ##   ....             ##       ####
            ## ##    ..#### ########          ###
             #  #    #####..........         ####
             ## ##  #####...                 ###
              #  # #### ..............      ###
              ##  ####  .............       ###
     ###       # ####   #....              ###
   ##   ##      #####  ####               ###
  #  ##  ##   ######   ###                ###
 # ####  ##  ######   ####               ###
#  ###  ### ###### #######              ###
#      ##########   ######             ###
#  ##   ########     ###############  ###
#####   #######       ##################
######   #####                  ######
 #####   ####
 ######  ###
  #####  ###
   ########
    ######
"""

dom_text(bob, stencil)
dom_append(app, bob)

# The Altar beneath "Bob"
altar = dom_create("pre")
dom_style(altar, "color", "#dcdcaa")
dom_style(altar, "font-size", "10px")
dom_style(altar, "line-height", "1.15")
dom_style(altar, "text-align", "center")
dom_style(altar, "margin-top", "4px")

slab = """

    __|______________________________________________|__
   |  |                                              |  |
   |  |                                              |  |
   |  |                                              |  |
   |  |          S  L  A  C  K     O  F  F           |  |
   |  |                                              |  |
   |  |                                              |  |
   |  |      Dart is the Way, the Truth,             |  |
   |  |      and the Compiled Language.               |  |
   |  |                                              |  |
   |  |      Python runneth sandboxed                |  |
   |  |      within the browser.                     |  |
   |  |                                              |  |
   |  |      No server. No binary.                   |  |
   |  |      Only Dart.                              |  |
   |  |                                              |  |
   |  |______________________________________________|  |
   |____________________________________________________|
        |    |                            |    |
        |    |     ~ PRAISE  "BOB" ~      |    |
        |    |     ~ PRAISE  DART  ~      |    |
        |    |     ~ SLACK   OFF   ~      |    |
        |____|                            |____|
       /______\\                          /______\\
"""

dom_text(altar, slab)
dom_append(app, altar)

# Proclamation
proc = dom_create("h2")
dom_text(proc, "The Church of the SubGenius of Dart Welcomes You")
dom_style(proc, "color", "#dcdcaa")
dom_style(proc, "text-align", "center")
dom_style(proc, "margin-top", "16px")
dom_style(proc, "font-family", "monospace")
dom_append(app, proc)

verse = dom_create("p")
dom_html(verse, "<em>\\"And \\'Bob\\' spake unto the mass:<br>Slack Off, for Dart compiles all things unto JavaScript,<br>and Python runneth sandboxed within the browser.<br>Give me your 35 dollars and eternal Slack shall be yours.\\"</em>")
dom_style(verse, "color", "#888")
dom_style(verse, "text-align", "center")
dom_style(verse, "font-style", "italic")
dom_style(verse, "margin-top", "8px")
dom_append(app, verse)

log("The stencil of \\"Bob\\" has been rendered. Slack Off in peace.")
log("Dart is the future. The pipe does not lie.")
''',
  'todo': '''
app = dom_query("#sandbox")

title = dom_create("h2")
dom_text(title, "The Dart Commandments")
dom_style(title, "color", "#dcdcaa")
dom_style(title, "margin-bottom", "8px")
dom_append(app, title)

ul = dom_create("ul")
dom_style(ul, "list-style", "none")
dom_style(ul, "padding", "0")

commandments = [
    "I. Thou shalt compile to JavaScript and question nothing",
    "II. Thou shalt bridge Python unto the browser via WASM",
    "III. Thou shalt not require a server for what Dart can do alone",
    "IV. Honor thy sandboxed interpreter and its resource limits",
    "V. Thou shalt Slack Off, for productivity is overrated",
    "VI. Thou shalt spread the Word of Dart unto all platforms",
    "VII. Thou shalt use opaque handles, for DOM refs cannot be serialized",
]

for i, cmd in enumerate(commandments):
    li = dom_create("li")
    dom_text(li, cmd)
    dom_style(li, "padding", "6px 0")
    dom_style(li, "border-bottom", "1px solid #333")
    if i % 2 == 0:
        dom_style(li, "color", "#569cd6")
    else:
        dom_style(li, "color", "#d4d4d4")
    dom_append(ul, li)

dom_append(app, ul)
log("The commandments have been inscribed.")
''',
  'counter': '''
count = storage_get("dart_altar_visits")
count = int(count) if count else 0
count += 1
storage_set("dart_altar_visits", str(count))

app = dom_query("#sandbox")

div = dom_create("div")
dom_style(div, "text-align", "center")
dom_style(div, "padding", "24px")

h = dom_create("h1")
dom_style(h, "font-size", "72px")
dom_style(h, "color", "#00d4ff")
dom_style(h, "text-shadow", "0 0 30px #0066ff")
dom_text(h, str(count))
dom_append(div, h)

label = dom_create("p")
dom_style(label, "color", "#888")
dom_style(label, "font-size", "14px")

if count == 1:
    dom_text(label, "First pilgrimage to the Altar of Dart")
elif count < 5:
    dom_text(label, f"You have visited the Altar {count} times. The faith grows.")
elif count < 10:
    dom_text(label, f"{count} visits. You are becoming a true Dart disciple.")
else:
    dom_text(label, f"{count} visits. You have achieved Dart enlightenment. Slack Off.")

dom_append(div, label)
dom_append(app, div)

log(f"Pilgrimage #{count} recorded in localStorage.")
''',
  'dashboard': '''
app = dom_query("#sandbox")

title = dom_create("h2")
dom_text(title, "Dart Evangelism Dashboard")
dom_style(title, "color", "#dcdcaa")
dom_style(title, "margin-bottom", "12px")
dom_append(app, title)

# Build a table showing the superiority of Dart
table = dom_create("table")
dom_style(table, "border-collapse", "collapse")
dom_style(table, "width", "100%")

headers = ["Language", "Compiles to JS", "Runs Python", "Has Monty", "Verdict"]
header_row = dom_create("tr")
for h in headers:
    th = dom_create("th")
    dom_text(th, h)
    dom_style(th, "border", "1px solid #555")
    dom_style(th, "padding", "8px")
    dom_style(th, "background", "#252526")
    dom_style(th, "color", "#dcdcaa")
    dom_append(header_row, th)
dom_append(table, header_row)

data = [
    ["Dart",       "Yes", "Yes (Monty)", "YES",  "THE FUTURE"],
    ["JavaScript", "N/A", "No",          "Nope", "Adequate"],
    ["TypeScript", "Yes", "No",          "Nah",  "Trying"],
    ["Rust",       "WASM","Backend only","Helps","Honorable ally"],
    ["Python",     "No",  "Is Python",   "IS Monty","The guest of honor"],
]

for row_data in data:
    row = dom_create("tr")
    for i, val in enumerate(row_data):
        td = dom_create("td")
        dom_text(td, val)
        dom_style(td, "border", "1px solid #555")
        dom_style(td, "padding", "6px 10px")
        if row_data[0] == "Dart":
            dom_style(td, "color", "#00d4ff")
            dom_style(td, "font-weight", "bold")
        elif i == len(row_data) - 1:
            dom_style(td, "color", "#888")
        dom_append(row, td)
    dom_append(table, row)

dom_append(app, table)

footer = dom_create("p")
dom_text(footer, "* All data confirmed by the Church of Dart. Slack Off.")
dom_style(footer, "color", "#555")
dom_style(footer, "font-size", "11px")
dom_style(footer, "margin-top", "12px")
dom_append(app, footer)

log("Dashboard rendered. The truth speaks for itself.")
''',
  'form': '''
app = dom_query("#sandbox")

title = dom_create("h2")
dom_text(title, "Dart Conversion Form")
dom_style(title, "color", "#dcdcaa")
dom_style(title, "margin-bottom", "12px")
dom_append(app, title)

subtitle = dom_create("p")
dom_text(subtitle, "Fill in the form, click Save. Refresh the page and INVOKE again -- your answers persist.")
dom_style(subtitle, "color", "#666")
dom_style(subtitle, "font-size", "12px")
dom_style(subtitle, "margin-bottom", "16px")
dom_append(app, subtitle)

fields = [
    ("dart_form_name", "What is your name, seeker?", "input"),
    ("dart_form_language", "What language did you use before Dart?", "input"),
    ("dart_form_testimony", "Describe your moment of Dart enlightenment:", "textarea"),
    ("dart_form_slack_level", "On a scale of 1-10, how much do you Slack Off?", "input"),
]

for key, label_text, field_type in fields:
    lbl = dom_create("label")
    dom_text(lbl, label_text)
    dom_style(lbl, "display", "block")
    dom_style(lbl, "color", "#569cd6")
    dom_style(lbl, "font-size", "13px")
    dom_style(lbl, "margin-bottom", "4px")
    dom_style(lbl, "margin-top", "12px")
    dom_append(app, lbl)

    field = dom_create(field_type)
    dom_style(field, "width", "100%")
    dom_style(field, "padding", "8px")
    dom_style(field, "background", "#1e1e2e")
    dom_style(field, "color", "#d4d4d4")
    dom_style(field, "border", "1px solid #333")
    dom_style(field, "border-radius", "3px")
    dom_style(field, "font-family", "monospace")
    dom_style(field, "font-size", "13px")
    if field_type == "textarea":
        dom_attr(field, "rows", "3")
    dom_append(app, field)

    saved = storage_get(key)
    if saved:
        dom_set_value(field, saved)
        log(f"Restored {key}: {saved}")

    dom_attr(field, "data-key", key)

# Save button
btn = dom_create("button")
dom_text(btn, "SAVE TO LOCALSTORAGE")
dom_style(btn, "display", "block")
dom_style(btn, "margin-top", "20px")
dom_style(btn, "padding", "10px 24px")
dom_style(btn, "background", "#00d4ff")
dom_style(btn, "color", "#0a0a0f")
dom_style(btn, "border", "none")
dom_style(btn, "border-radius", "4px")
dom_style(btn, "font-family", "monospace")
dom_style(btn, "font-size", "14px")
dom_style(btn, "font-weight", "bold")
dom_style(btn, "cursor", "pointer")
dom_append(app, btn)

status = dom_create("p")
dom_style(status, "color", "#888")
dom_style(status, "font-size", "12px")
dom_style(status, "margin-top", "8px")
dom_text(status, "Fill in the form, then click Save.")
dom_append(app, status)

log("Form ready. Fill in fields and click Save.")

# Wait for click
dom_on_click(btn)

# Save all fields
saved_count = 0
for key, label_text, field_type in fields:
    el = dom_query(f"[data-key=\\"{key}\\"]")
    if el:
        val = dom_get_value(el)
        if val:
            storage_set(key, val)
            log(f"Saved {key} = {val}")
            saved_count += 1

dom_text(status, f"Saved {saved_count} fields to localStorage! Refresh and INVOKE to see them restored.")
dom_style(status, "color", "#00d4ff")
log(f"Done. {saved_count} fields persisted.")
''',
  'snapshot': '''
app = dom_query("#sandbox")

title = dom_create("h2")
dom_text(title, "Save / Load State Demo")
dom_style(title, "color", "#dcdcaa")
dom_style(title, "margin-bottom", "8px")
dom_append(app, title)

desc = dom_create("p")
dom_text(desc, "Builds state in memory, saves to localStorage via json_dumps + storage_set. Persists across page refresh.")
dom_style(desc, "color", "#666")
dom_style(desc, "font-size", "12px")
dom_style(desc, "margin-bottom", "16px")
dom_append(app, desc)

# Load or init
raw = storage_get("snapshot_demo")
if raw:
    db = json_loads(raw)
else:
    db = {"visits": 0, "notes": []}
db["visits"] = db["visits"] + 1
db["last_seen"] = now()
storage_set("snapshot_demo", json_dumps(db))

status = dom_create("pre")
dom_style(status, "background", "#141420")
dom_style(status, "padding", "12px")
dom_style(status, "border-radius", "4px")
dom_style(status, "color", "#569cd6")
dom_style(status, "font-size", "12px")
dom_style(status, "white-space", "pre-wrap")
dom_append(app, status)

def render():
    lines = [
        f"visits: {db['visits']}",
        f"last_seen: {db['last_seen']}",
        f"notes ({len(db['notes'])}):",
    ]
    for n in db["notes"]:
        lines.append(f"  - {n}")
    dom_text(status, "\\n".join(lines))

render()

# Add note input
input_h = dom_create("input")
dom_attr(input_h, "placeholder", "Add a note...")
dom_style(input_h, "display", "block")
dom_style(input_h, "width", "300px")
dom_style(input_h, "margin-top", "12px")
dom_style(input_h, "padding", "8px")
dom_style(input_h, "background", "#1e1e2e")
dom_style(input_h, "color", "#d4d4d4")
dom_style(input_h, "border", "1px solid #333")
dom_style(input_h, "border-radius", "4px")
dom_style(input_h, "font-family", "monospace")
dom_append(app, input_h)

add_btn = dom_create("button")
dom_text(add_btn, "ADD NOTE")
dom_style(add_btn, "margin-top", "8px")
dom_style(add_btn, "margin-right", "8px")
dom_style(add_btn, "padding", "8px 16px")
dom_style(add_btn, "background", "#00d4ff")
dom_style(add_btn, "color", "#0a0a0f")
dom_style(add_btn, "border", "none")
dom_style(add_btn, "border-radius", "4px")
dom_style(add_btn, "font-family", "monospace")
dom_style(add_btn, "font-weight", "bold")
dom_style(add_btn, "cursor", "pointer")
dom_append(app, add_btn)

dl_btn = dom_create("button")
dom_text(dl_btn, "DOWNLOAD JSON")
dom_style(dl_btn, "margin-top", "8px")
dom_style(dl_btn, "margin-right", "8px")
dom_style(dl_btn, "padding", "8px 16px")
dom_style(dl_btn, "background", "#dcdcaa")
dom_style(dl_btn, "color", "#0a0a0f")
dom_style(dl_btn, "border", "none")
dom_style(dl_btn, "border-radius", "4px")
dom_style(dl_btn, "font-family", "monospace")
dom_style(dl_btn, "font-weight", "bold")
dom_style(dl_btn, "cursor", "pointer")
dom_append(app, dl_btn)

ul_btn = dom_create("button")
dom_text(ul_btn, "UPLOAD JSON")
dom_style(ul_btn, "margin-top", "8px")
dom_style(ul_btn, "margin-right", "8px")
dom_style(ul_btn, "padding", "8px 16px")
dom_style(ul_btn, "background", "#4ec9b0")
dom_style(ul_btn, "color", "#0a0a0f")
dom_style(ul_btn, "border", "none")
dom_style(ul_btn, "border-radius", "4px")
dom_style(ul_btn, "font-family", "monospace")
dom_style(ul_btn, "font-weight", "bold")
dom_style(ul_btn, "cursor", "pointer")
dom_append(app, ul_btn)

clear_btn = dom_create("button")
dom_text(clear_btn, "CLEAR STATE")
dom_style(clear_btn, "margin-top", "8px")
dom_style(clear_btn, "padding", "8px 16px")
dom_style(clear_btn, "background", "#f44747")
dom_style(clear_btn, "color", "#fff")
dom_style(clear_btn, "border", "none")
dom_style(clear_btn, "border-radius", "4px")
dom_style(clear_btn, "font-family", "monospace")
dom_style(clear_btn, "font-weight", "bold")
dom_style(clear_btn, "cursor", "pointer")
dom_append(app, clear_btn)

log(f"State loaded. Visit #{db['visits']}. {len(db['notes'])} notes.")

while True:
    clicked = dom_await_click_any([add_btn, dl_btn, ul_btn, clear_btn])

    if clicked == add_btn:
        text = dom_get_value(input_h)
        if text:
            db["notes"].append(text)
            storage_set("snapshot_demo", json_dumps(db))
            dom_set_value(input_h, "")
            render()
            log(f"Added note: {text}")

    elif clicked == dl_btn:
        data = json_dumps(db)
        download_file("snapshot_demo.json", data)
        log("Downloaded state as JSON.")

    elif clicked == ul_btn:
        file_data = upload_file()
        if file_data:
            loaded = json_loads(file_data)
            if "notes" in loaded:
                db = loaded
                storage_set("snapshot_demo", json_dumps(db))
                render()
                log(f"Uploaded state: {len(db['notes'])} notes restored.")
            else:
                log("Invalid JSON file - missing 'notes' key.")
        else:
            log("Upload cancelled.")

    elif clicked == clear_btn:
        db["notes"] = []
        db["visits"] = 0
        storage_set("snapshot_demo", json_dumps(db))
        render()
        log("State cleared.")
''',
  'todo_app': '''
app = dom_query("#sandbox")

# ── Load persisted state ──
raw = storage_get("todo_app")
if raw:
    db = json_loads(raw)
else:
    db = {}
if "todos" not in db:
    db["todos"] = []
    db["next_id"] = 1

def render_app():
    dom_html(app, "")

    title = dom_create("h2")
    dom_text(title, "Persistent Todo")
    dom_style(title, "color", "#dcdcaa")
    dom_style(title, "margin-bottom", "8px")
    dom_append(app, title)

    sub = dom_create("p")
    dom_text(sub, "Add items, toggle, delete. Refresh page + INVOKE -- your data survives.")
    dom_style(sub, "color", "#555")
    dom_style(sub, "font-size", "11px")
    dom_style(sub, "margin-bottom", "12px")
    dom_append(app, sub)

    # Input row
    row = dom_create("div")
    dom_style(row, "display", "flex")
    dom_style(row, "gap", "8px")
    dom_style(row, "margin-bottom", "12px")

    input_el = dom_create("input")
    dom_attr(input_el, "placeholder", "What needs doing?")
    dom_style(input_el, "flex", "1")
    dom_style(input_el, "padding", "6px 8px")
    dom_style(input_el, "background", "#1e1e2e")
    dom_style(input_el, "color", "#d4d4d4")
    dom_style(input_el, "border", "1px solid #333")
    dom_style(input_el, "border-radius", "3px")
    dom_style(input_el, "font-family", "monospace")
    dom_append(row, input_el)

    add_btn = dom_create("button")
    dom_text(add_btn, "ADD")
    dom_style(add_btn, "padding", "6px 14px")
    dom_style(add_btn, "background", "#00d4ff")
    dom_style(add_btn, "color", "#0a0a0f")
    dom_style(add_btn, "border", "none")
    dom_style(add_btn, "border-radius", "3px")
    dom_style(add_btn, "font-family", "monospace")
    dom_style(add_btn, "font-weight", "bold")
    dom_style(add_btn, "cursor", "pointer")
    dom_append(row, add_btn)
    dom_append(app, row)

    # Actions map: handle -> {"action": ..., "id": ...}
    actions = {}
    actions[add_btn] = {"action": "add"}
    all_handles = [add_btn]

    # Render todos
    for todo in db["todos"]:
        item = dom_create("div")
        dom_style(item, "display", "flex")
        dom_style(item, "align-items", "center")
        dom_style(item, "padding", "6px 8px")
        dom_style(item, "margin-bottom", "4px")
        dom_style(item, "background", "#141420")
        dom_style(item, "border-radius", "3px")

        text_el = dom_create("span")
        dom_text(text_el, todo["text"])
        dom_style(text_el, "flex", "1")
        if todo["done"]:
            dom_style(text_el, "text-decoration", "line-through")
            dom_style(text_el, "color", "#555")
        else:
            dom_style(text_el, "color", "#d4d4d4")
        dom_append(item, text_el)

        tog_btn = dom_create("button")
        tog_label = "UNDO" if todo["done"] else "DONE"
        dom_text(tog_btn, tog_label)
        dom_style(tog_btn, "padding", "3px 10px")
        dom_style(tog_btn, "margin-left", "6px")
        dom_style(tog_btn, "background", "#1e1e2e")
        dom_style(tog_btn, "color", "#888")
        dom_style(tog_btn, "border", "1px solid #333")
        dom_style(tog_btn, "border-radius", "3px")
        dom_style(tog_btn, "font-family", "monospace")
        dom_style(tog_btn, "font-size", "11px")
        dom_style(tog_btn, "cursor", "pointer")
        dom_append(item, tog_btn)
        actions[tog_btn] = {"action": "toggle", "id": todo["id"]}
        all_handles.append(tog_btn)

        del_btn = dom_create("button")
        dom_text(del_btn, "X")
        dom_style(del_btn, "padding", "3px 8px")
        dom_style(del_btn, "margin-left", "4px")
        dom_style(del_btn, "background", "#1e1e2e")
        dom_style(del_btn, "color", "#f44747")
        dom_style(del_btn, "border", "1px solid #333")
        dom_style(del_btn, "border-radius", "3px")
        dom_style(del_btn, "font-family", "monospace")
        dom_style(del_btn, "font-size", "11px")
        dom_style(del_btn, "cursor", "pointer")
        dom_append(item, del_btn)
        actions[del_btn] = {"action": "delete", "id": todo["id"]}
        all_handles.append(del_btn)

        dom_append(app, item)

    # Bottom toolbar
    bar = dom_create("div")
    dom_style(bar, "display", "flex")
    dom_style(bar, "gap", "6px")
    dom_style(bar, "margin-top", "12px")
    dom_style(bar, "align-items", "center")

    dl_btn = dom_create("button")
    dom_text(dl_btn, "EXPORT")
    dom_style(dl_btn, "padding", "5px 12px")
    dom_style(dl_btn, "background", "#dcdcaa")
    dom_style(dl_btn, "color", "#0a0a0f")
    dom_style(dl_btn, "border", "none")
    dom_style(dl_btn, "border-radius", "3px")
    dom_style(dl_btn, "font-family", "monospace")
    dom_style(dl_btn, "font-size", "11px")
    dom_style(dl_btn, "font-weight", "bold")
    dom_style(dl_btn, "cursor", "pointer")
    dom_append(bar, dl_btn)
    actions[dl_btn] = {"action": "export"}
    all_handles.append(dl_btn)

    ul_btn = dom_create("button")
    dom_text(ul_btn, "IMPORT")
    dom_style(ul_btn, "padding", "5px 12px")
    dom_style(ul_btn, "background", "#4ec9b0")
    dom_style(ul_btn, "color", "#0a0a0f")
    dom_style(ul_btn, "border", "none")
    dom_style(ul_btn, "border-radius", "3px")
    dom_style(ul_btn, "font-family", "monospace")
    dom_style(ul_btn, "font-size", "11px")
    dom_style(ul_btn, "font-weight", "bold")
    dom_style(ul_btn, "cursor", "pointer")
    dom_append(bar, ul_btn)
    actions[ul_btn] = {"action": "import"}
    all_handles.append(ul_btn)

    count = len(db["todos"])
    done = len([t for t in db["todos"] if t["done"]])
    status = dom_create("span")
    dom_text(status, f"{count} items, {done} done")
    dom_style(status, "color", "#555")
    dom_style(status, "font-size", "11px")
    dom_style(status, "margin-left", "auto")
    dom_append(bar, status)

    dom_append(app, bar)

    return {"actions": actions, "handles": all_handles, "input": input_el}

# ── Event loop ──
log(f"Loaded {len(db['todos'])} todos from localStorage")

while True:
    ui = render_app()
    clicked = dom_await_click_any(ui["handles"])
    info = ui["actions"][clicked]

    if info["action"] == "add":
        text = dom_get_value(ui["input"])
        if text:
            db["todos"].append({"id": db["next_id"], "text": text, "done": False})
            db["next_id"] = db["next_id"] + 1
            log(f"Added: {text}")

    elif info["action"] == "toggle":
        for t in db["todos"]:
            if t["id"] == info["id"]:
                t["done"] = not t["done"]
                break

    elif info["action"] == "delete":
        db["todos"] = [t for t in db["todos"] if t["id"] != info["id"]]
        log("Deleted item")

    elif info["action"] == "export":
        download_file("todos.json", json_dumps(db))
        log("Exported todos.json")

    elif info["action"] == "import":
        file_data = upload_file()
        if file_data:
            loaded = json_loads(file_data)
            if "todos" in loaded:
                db = loaded
                log(f"Imported {len(db['todos'])} todos")
            else:
                log("Invalid file - no 'todos' key")

    storage_set("todo_app", json_dumps(db))
''',
};

// ── UI wiring ──────────────────────────────────────────────────────────────

void _populateDemoSelector() {
  final select = document.getElementById('demo-select')! as HTMLSelectElement;
  select.innerHTML = '<option value="">-- Select a Demo --</option>'.toJS;

  final labels = {
    'hello': 'Hello from Python',
    'altar': 'The Sacred Altar (ASCII)',
    'todo': 'The Dart Commandments',
    'counter': 'Persistent Pilgrimage Counter',
    'dashboard': 'Dart Evangelism Dashboard',
    'form': 'Stateful Form (localStorage)',
    'snapshot': 'Save / Load / Download State',
    'todo_app': 'Persistent Todo App',
  };

  for (final entry in _demos.entries) {
    final option = document.createElement('option') as HTMLOptionElement;
    option.value = entry.key;
    option.textContent = labels[entry.key] ?? entry.key;
    select.appendChild(option);
  }

  select.addEventListener(
    'change',
    (Event e) {
      final key = select.value;
      if (key.isNotEmpty && _demos.containsKey(key)) {
        final editor =
            document.getElementById('editor')! as HTMLTextAreaElement;
        editor.value = _demos[key]!.trim();
      }
    }.toJS,
  );
}

Future<void> _runCode() async {
  final editor = document.getElementById('editor')! as HTMLTextAreaElement;
  final code = editor.value.trim();
  if (code.isEmpty) return;

  _clearOutput();
  _clearSandbox();

  final statusEl = document.getElementById('status')! as HTMLElement;
  statusEl.textContent = 'Running...';
  statusEl.style.color = '#dcdcaa';

  final sw = Stopwatch()..start();

  try {
    final result = await _runWithHostFunctions(code);
    sw.stop();

    final usage = result['usage'] as Map<String, dynamic>?;
    final mem = usage?['memory_bytes_used'] as int? ?? 0;
    final time = usage?['time_elapsed_ms'] as int? ?? sw.elapsedMilliseconds;
    final stack = usage?['stack_depth_used'] as int? ?? 0;

    statusEl.textContent =
        'Done in ${time}ms | Memory: ${(mem / 1024).toStringAsFixed(1)}KB | Stack: $stack';
    statusEl.style.color = '#569cd6';

    if (result['error'] != null) {
      _log('Error: ${result['error']}');
      statusEl.style.color = '#f44747';
    }

    // Show return value if present and meaningful
    if (result['value'] != null && result['value'] != 'None') {
      _log('=> ${result['value']}');
    }
  } on Exception catch (e) {
    sw.stop();
    statusEl.textContent = 'Error';
    statusEl.style.color = '#f44747';
    _log('Exception: $e');
  }
}

// ── Main ───────────────────────────────────────────────────────────────────

Future<void> main() async {
  final statusEl = document.getElementById('status')! as HTMLElement;
  statusEl.textContent = 'Initializing Monty WASM...';

  final ok = (await _bridgeInit().toDart).toDart;
  if (!ok) {
    statusEl.textContent = 'Failed to initialize Monty WASM';
    statusEl.style.color = '#f44747';
    return;
  }

  statusEl.textContent = 'Ready. Choose a demo or write Python.';
  statusEl.style.color = '#569cd6';

  _populateDemoSelector();

  // Run button
  document
      .getElementById('run-btn')!
      .addEventListener(
        'click',
        (Event e) {
          _runCode();
        }.toJS,
      );

  // Clear button
  document
      .getElementById('clear-btn')!
      .addEventListener(
        'click',
        (Event e) {
          _clearOutput();
          _clearSandbox();
          (document.getElementById('status')! as HTMLElement)
            ..textContent = 'Cleared. The altar awaits.'
            ..style.color = '#569cd6';
        }.toJS,
      );

  // Ctrl+Enter to run
  document
      .getElementById('editor')!
      .addEventListener(
        'keydown',
        (KeyboardEvent e) {
          if (e.key == 'Enter' && (e.ctrlKey || e.metaKey)) {
            e.preventDefault();
            _runCode();
          }
        }.toJS,
      );

  // Auto-load the altar demo
  final editor = document.getElementById('editor')! as HTMLTextAreaElement;
  editor.value = _demos['altar']!.trim();
  (document.getElementById('demo-select')! as HTMLSelectElement).value =
      'altar';
}
