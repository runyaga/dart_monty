#!/usr/bin/env python3
"""
CLI wrapper for the MontyWasm fuzz harness.
Runs headless Chrome to execute a Monty script in the WASM interpreter.
"""

import sys
import os
import base64
import subprocess
import time
import json
import http.server
import threading
import socket
import shutil
from pathlib import Path

# Paths
# We define PKG_ROOT based on where the tool lives
PKG_ROOT = Path(__file__).parent.parent.resolve()
INTEG_WEB = PKG_ROOT / "test" / "integration" / "web"
ASSETS_DIR = PKG_ROOT / "assets"

# Detect actual project prefix (e.g. dart_monty or dart_monty_core)
# We use the name of the package directory
PROJECT_PREFIX = PKG_ROOT.name

def get_free_port():
    with socket.socket(socket.AF_INET, socket.SOCK_STREAM) as s:
        s.bind(('', 0))
        return s.getsockname()[1]

class CoopCoepHandler(http.server.SimpleHTTPRequestHandler):
    def end_headers(self):
        self.send_header('Cross-Origin-Opener-Policy', 'same-origin')
        self.send_header('Cross-Origin-Embedder-Policy', 'require-corp')
        self.send_header('Access-Control-Allow-Origin', '*')
        self.send_header('Cache-Control', 'no-store')
        super().end_headers()

    def log_message(self, format, *args):
        pass

def start_server(port):
    # Important: server runs relative to the WEB directory
    os.chdir(INTEG_WEB)
    server = http.server.HTTPServer(('127.0.0.1', port), CoopCoepHandler)
    thread = threading.Thread(target=server.serve_forever, daemon=True)
    thread.start()
    return server

def find_chrome():
    candidates = [
        "google-chrome-stable",
        "google-chrome",
        "/Applications/Google Chrome.app/Contents/MacOS/Google Chrome",
        "chromium",
        "chromium-browser"
    ]
    for c in candidates:
        if subprocess.run(["which", c], capture_output=True).returncode == 0:
            return c
        if os.path.exists(c):
            return c
    return None

def run_fuzz(code_str, chrome_path, port):
    encoded_code = base64.b64encode(code_str.encode('utf-8')).decode('utf-8')
    url = f"http://127.0.0.1:{port}/fuzz.html#{encoded_code}"
    
    cmd = [
        chrome_path,
        "--headless=new",
        "--disable-gpu",
        "--no-sandbox",
        "--enable-logging=stderr",
        "--v=0",
        url
    ]
    
    process = subprocess.Popen(cmd, stderr=subprocess.PIPE, text=True)
    
    result = None
    try:
        for line in process.stderr:
            if "FUZZ_RESULT:" in line:
                content = line.split("FUZZ_RESULT:")[1].strip()
                if content.startswith('"'): content = content[1:]
                if content.endswith('"'): content = content[:-1]
                content = content.replace('\\"', '"')
                
                try:
                    start = content.find('{')
                    end = content.rfind('}')
                    if start != -1 and end != -1:
                        result = json.loads(content[start:end+1])
                except Exception as e:
                    print(f"DEBUG: Error parsing JSON: {e}", file=sys.stderr)
            if "FUZZ_DONE" in line:
                break
    finally:
        process.terminate()
        process.wait()
        
    return result

def main():
    if len(sys.argv) < 2:
        print("Usage: fuzz_wasm.py '<python code>'")
        sys.exit(1)
        
    code = sys.argv[1]
    
    # Asset Management: Sync correctly prefixed files to generic 'bridge.js' etc.
    # Ensure assets are present in the web dir
    asset_map = {
        f"{PROJECT_PREFIX}_bridge.js": "bridge.js",
        f"{PROJECT_PREFIX}_worker.js": "worker.js",
        f"{PROJECT_PREFIX}_native.wasm": f"{PROJECT_PREFIX}_native.wasm" 
    }

    INTEG_WEB.mkdir(parents=True, exist_ok=True)

    for src_name, dst_name in asset_map.items():
        src = ASSETS_DIR / src_name

        # Core Fallback (if main package is missing assets)
        if not src.exists() and PROJECT_PREFIX == "dart_monty":
            # Main PROJECT_PREFIX might be 'dart_monty', but assets might be in 'dart_monty_core'
            # We try BOTH names in our LOCAL assets folder first
            alt_src_name = src_name.replace("dart_monty", "dart_monty_core")
            alt_src = ASSETS_DIR / alt_src_name
            if alt_src.exists():
                src = alt_src
            else:
                # If STILL not found locally, try the sibling dart_monty_core directory
                sibling_core_assets = PKG_ROOT.parent / "dart_monty_core" / "assets"
                if sibling_core_assets.exists():
                    sibling_src = sibling_core_assets / alt_src_name
                    if sibling_src.exists():
                        src = sibling_src

        if not src.exists():
            print(f"ERROR: Asset {src_name} not found in {ASSETS_DIR} or sibling core. Build the project first.")
            sys.exit(77) # Special code for configuration failure

        dst = INTEG_WEB / dst_name
        if not dst.exists() or src.stat().st_mtime > dst.stat().st_mtime:
            shutil.copy2(src, dst)
    # Compile the harness (if needed)
    harness_js = INTEG_WEB / "wasm_fuzz_harness.dart.js"
    # Try project-specific harness first
    harness_dart = PKG_ROOT / "test" / "integration" / f"{PROJECT_PREFIX}_wasm_fuzz_harness.dart"
    if not harness_dart.exists():
        harness_dart = PKG_ROOT / "test" / "integration" / "wasm_fuzz_harness.dart"

    if not harness_js.exists() or harness_dart.stat().st_mtime > harness_js.stat().st_mtime:
        print(f"Compiling {harness_dart.name}...")
        subprocess.run([
            "dart", "compile", "js", str(harness_dart),
            "-o", str(harness_js), "--no-source-maps"
        ], check=True)

    chrome = find_chrome()
    if not chrome:
        print("ERROR: Chrome/Chromium not found.")
        sys.exit(1)
        
    port = get_free_port()
    server = start_server(port)
    
    try:
        result = run_fuzz(code, chrome, port)
        if result:
            print(json.dumps(result, indent=2))
        else:
            print("ERROR: No result captured from Chrome.")
            sys.exit(1)
    finally:
        server.shutdown()

if __name__ == "__main__":
    main()
