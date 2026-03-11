#!/usr/bin/env python3
"""LLM API caller — supports Ollama, OpenAI-compatible, and Gemini backends.

Usage:
    python3 tool/llm_call.py \
        --provider ollama \
        --model qwen2.5-coder:14b \
        --system-file system_prompt.txt \
        --turns-dir artifacts/turns/ \
        --output response.md

Providers:
    ollama   — Local Ollama server (default: http://localhost:11434)
               Uses /api/chat endpoint.
               Env: OLLAMA_HOST (optional, default localhost:11434)

    openai   — Any OpenAI-compatible endpoint (Ollama /v1, LM Studio, vLLM, etc.)
               Env: OPENAI_API_KEY (optional), OPENAI_BASE_URL (default: http://localhost:11434/v1)

    gemini   — Google Gemini API
               Env: GEMINI_API_KEY (required)

The script reads system_prompt.txt and all turn_*.json files from turns_dir,
builds a multi-turn conversation, calls the LLM, and writes the response text
to the output file.

Turn files are JSON: {"role": "user"|"model"|"assistant", "parts": [{"text": "..."}]}
(Gemini format — converted to OpenAI format internally for openai/ollama providers.)
"""

import argparse
import glob
import json
import os
import sys
import urllib.request
import urllib.error


def load_turns(turns_dir: str) -> list[dict]:
    """Load ordered turn files from the turns directory."""
    turn_files = sorted(glob.glob(os.path.join(turns_dir, 'turn_*.json')))
    turns = []
    for tf in turn_files:
        with open(tf) as f:
            turns.append(json.load(f))
    return turns


def gemini_to_openai_role(role: str) -> str:
    """Convert Gemini role names to OpenAI role names."""
    return {'model': 'assistant', 'user': 'user', 'assistant': 'assistant'}.get(
        role, role
    )


def turns_to_openai_messages(
    system_text: str, turns: list[dict]
) -> list[dict]:
    """Convert Gemini-format turns to OpenAI chat messages."""
    messages = [{'role': 'system', 'content': system_text}]
    for turn in turns:
        role = gemini_to_openai_role(turn['role'])
        text = turn['parts'][0]['text']
        messages.append({'role': role, 'content': text})
    return messages


def call_ollama(
    model: str,
    system_text: str,
    turns: list[dict],
    host: str,
) -> str:
    """Call Ollama's /api/chat endpoint (native format)."""
    messages = turns_to_openai_messages(system_text, turns)
    # Ollama native /api/chat uses the same message format as OpenAI.
    payload = {
        'model': model,
        'messages': messages,
        'stream': False,
        'options': {
            'temperature': 0.2,
            'num_predict': 16384,
        },
    }

    url = f'{host}/api/chat'
    req = urllib.request.Request(
        url,
        data=json.dumps(payload).encode(),
        headers={'Content-Type': 'application/json'},
    )

    try:
        with urllib.request.urlopen(req, timeout=600) as resp:
            data = json.load(resp)
    except urllib.error.HTTPError as e:
        body = e.read().decode()
        print(f'ERROR: Ollama returned HTTP {e.code}: {body}', file=sys.stderr)
        sys.exit(1)
    except urllib.error.URLError as e:
        print(f'ERROR: Cannot connect to Ollama at {host}: {e.reason}', file=sys.stderr)
        print('Is Ollama running? Start with: ollama serve', file=sys.stderr)
        sys.exit(1)

    return data['message']['content']


def call_openai(
    model: str,
    system_text: str,
    turns: list[dict],
    base_url: str,
    api_key: str | None,
) -> str:
    """Call any OpenAI-compatible /v1/chat/completions endpoint."""
    messages = turns_to_openai_messages(system_text, turns)
    payload = {
        'model': model,
        'messages': messages,
        'temperature': 0.2,
        'max_tokens': 16384,
    }

    url = f'{base_url}/chat/completions'
    headers = {'Content-Type': 'application/json'}
    if api_key:
        headers['Authorization'] = f'Bearer {api_key}'

    req = urllib.request.Request(
        url,
        data=json.dumps(payload).encode(),
        headers=headers,
    )

    try:
        with urllib.request.urlopen(req, timeout=600) as resp:
            data = json.load(resp)
    except urllib.error.HTTPError as e:
        body = e.read().decode()
        print(f'ERROR: OpenAI-compatible API returned HTTP {e.code}: {body}', file=sys.stderr)
        sys.exit(1)

    return data['choices'][0]['message']['content']


def call_gemini(
    model: str,
    system_text: str,
    turns: list[dict],
    api_key: str,
) -> str:
    """Call Google Gemini generateContent API."""
    # Convert turns to Gemini format (they're already in Gemini format).
    contents = []
    for turn in turns:
        contents.append(turn)

    payload = {
        'system_instruction': {'parts': [{'text': system_text}]},
        'contents': contents,
        'generationConfig': {
            'temperature': 0.2,
            'maxOutputTokens': 16384,
        },
    }

    url = (
        f'https://generativelanguage.googleapis.com/v1beta/models'
        f'/{model}:generateContent?key={api_key}'
    )
    req = urllib.request.Request(
        url,
        data=json.dumps(payload).encode(),
        headers={'Content-Type': 'application/json'},
    )

    try:
        with urllib.request.urlopen(req, timeout=600) as resp:
            data = json.load(resp)
    except urllib.error.HTTPError as e:
        body = e.read().decode()
        print(f'ERROR: Gemini API returned HTTP {e.code}: {body}', file=sys.stderr)
        sys.exit(1)

    try:
        return data['candidates'][0]['content']['parts'][0]['text']
    except (KeyError, IndexError):
        print('ERROR: Unexpected Gemini response structure:', file=sys.stderr)
        json.dump(data, sys.stderr, indent=2)
        sys.exit(1)


def main():
    parser = argparse.ArgumentParser(description='Call LLM API (Ollama/OpenAI/Gemini)')
    parser.add_argument('--provider', required=True, choices=['ollama', 'openai', 'gemini'])
    parser.add_argument('--model', required=True)
    parser.add_argument('--system-file', required=True)
    parser.add_argument('--turns-dir', required=True)
    parser.add_argument('--output', required=True)
    args = parser.parse_args()

    with open(args.system_file) as f:
        system_text = f.read()

    turns = load_turns(args.turns_dir)

    if args.provider == 'ollama':
        host = os.environ.get('OLLAMA_HOST', 'http://localhost:11434')
        result = call_ollama(args.model, system_text, turns, host)

    elif args.provider == 'openai':
        base_url = os.environ.get('OPENAI_BASE_URL', 'http://localhost:11434/v1')
        api_key = os.environ.get('OPENAI_API_KEY')
        result = call_openai(args.model, system_text, turns, base_url, api_key)

    elif args.provider == 'gemini':
        api_key = os.environ.get('GEMINI_API_KEY')
        if not api_key:
            print('ERROR: GEMINI_API_KEY not set', file=sys.stderr)
            sys.exit(1)
        result = call_gemini(args.model, system_text, turns, api_key)

    with open(args.output, 'w') as f:
        f.write(result)

    print(f'OK: Response written to {args.output} ({len(result)} chars)')


if __name__ == '__main__':
    main()
