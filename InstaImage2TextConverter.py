# -------------------------------------------------------
# InstaImage2TextConverter.py  (v1.6 - CLI mode, no UI)
# -------------------------------------------------------
# Mode 1 - OCR (default):
#   python InstaImage2TextConverter.py [--tesseract "path"] "file1.png" ...
#   Prints OCR text to stdout, one --- filename --- block per file.
#
# Mode 2 - Direct vision (--direct):
#   python InstaImage2TextConverter.py --direct --apikey "sk-..." --apiurl "https://..." --model "model-id" --prompt "..." "file1.png" ...
#   Base64-encodes images, calls OpenRouter vision API, prints response text to stdout.
#
# Requirements:
#   pip install pytesseract pillow requests
#   Tesseract installed (OCR mode only)
# -------------------------------------------------------

import sys
import os
import re
import base64
import json

DEFAULT_TESSERACT = r"C:\Program Files\Tesseract-OCR\tesseract.exe"
DEFAULT_API_URL   = "https://openrouter.ai/api/v1/chat/completions"

MIME_MAP = {
    "jpg": "image/jpeg", "jpeg": "image/jpeg",
    "png": "image/png",  "bmp": "image/bmp",
    "gif": "image/gif",  "tiff": "image/tiff",
    "tif": "image/tiff", "webp": "image/webp",
}

def natural_sort_key(path):
    name = os.path.basename(path)
    return [int(c) if c.isdigit() else c.lower() for c in re.split(r'(\d+)', name)]

def pop_arg(args, flag):
    """Remove flag + next value from args list, return (value, remaining_args)."""
    if flag in args:
        idx = args.index(flag)
        if idx + 1 < len(args):
            val = args[idx + 1]
            return val, args[:idx] + args[idx + 2:]
    return None, args

def ocr_mode(args):
    import pytesseract
    from PIL import Image

    tesseract_path, args = pop_arg(args, "--tesseract")
    if tesseract_path:
        pytesseract.pytesseract.tesseract_cmd = tesseract_path
    else:
        pytesseract.pytesseract.tesseract_cmd = DEFAULT_TESSERACT

    files = args
    if not files:
        print("ERROR: No files provided.")
        sys.exit(1)

    for image_path in sorted(files, key=natural_sort_key):
        filename = os.path.basename(image_path)
        if not os.path.isfile(image_path):
            print(f"\n--- {filename} ---\nERROR: File not found: {image_path}")
            continue
        try:
            img  = Image.open(image_path)
            text = pytesseract.image_to_string(img).strip()
            print(f"\n--- {filename} ---\n{text}")
        except Exception as e:
            print(f"\n--- {filename} ---\nERROR: {e}")

def direct_mode(args):
    import requests

    api_key, args = pop_arg(args, "--apikey")
    api_url, args = pop_arg(args, "--apiurl")
    model,   args = pop_arg(args, "--model")
    prompt,  args = pop_arg(args, "--prompt")

    if not api_key:
        print("ERROR: --apikey required for direct mode.")
        sys.exit(1)
    if not model:
        print("ERROR: --model required for direct mode.")
        sys.exit(1)
    if not prompt:
        prompt = "Extract all text from this image exactly as written."

    api_url = api_url or DEFAULT_API_URL
    files   = args

    if not files:
        print("ERROR: No image files provided.")
        sys.exit(1)

    content = []
    for image_path in sorted(files, key=natural_sort_key):
        if not os.path.isfile(image_path):
            print(f"ERROR: File not found: {image_path}")
            sys.exit(1)
        ext  = os.path.splitext(image_path)[1].lstrip(".").lower()
        mime = MIME_MAP.get(ext, "image/jpeg")
        with open(image_path, "rb") as f:          # rb = binary, no EOL translation
            b64 = base64.b64encode(f.read()).decode("ascii")
        content.append({
            "type": "image_url",
            "image_url": {"url": f"data:{mime};base64,{b64}"}
        })

    content.append({"type": "text", "text": prompt})

    payload = {
        "model": model,
        "messages": [{"role": "user", "content": content}]
    }
    headers = {
        "Content-Type":  "application/json",
        "Authorization": f"Bearer {api_key}",
        "HTTP-Referer":  "https://ahk-tool.local",
        "X-Title":       "AHK Image Chat",
    }

    try:
        resp = requests.post(api_url, headers=headers, json=payload, timeout=60)
        data = resp.json()
        text = data["choices"][0]["message"]["content"]
        print(text)
    except Exception as e:
        print(f"ERROR: {e}\nRaw: {resp.text if 'resp' in dir() else ''}")
        sys.exit(1)

def main():
    args = sys.argv[1:]
    if "--direct" in args:
        args.remove("--direct")
        direct_mode(args)
    else:
        ocr_mode(args)

if __name__ == "__main__":
    main()
