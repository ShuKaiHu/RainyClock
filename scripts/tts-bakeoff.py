#!/usr/bin/env python3
"""Generate the same wake-up lines through every candidate TTS vendor, for blind comparison.

The decision this settles: which vendor can be *energetic* (激昂) in Mandarin without
sounding like it learned Chinese in Beijing or in California. Both halves matter and no
vendor obviously wins both, so listen before committing.

Set whichever keys you have; missing ones are skipped.

    OPENAI_API_KEY        gpt-4o-mini-tts, free-text `instructions`
    GEMINI_API_KEY        Gemini-TTS via the Gemini API (aistudio.google.com/apikey)
    ELEVENLABS_API_KEY    eleven_v3, inline [excited] audio tags
    MINIMAX_API_KEY + MINIMAX_GROUP_ID   speech-2.8-hd, discrete emotion enum

    python3 scripts/tts-bakeoff.py out/tts-bakeoff
"""

import base64
import io
import json
import os
import random
import sys
import urllib.error
import urllib.request
import wave

# Three lines covering the range an alarm actually needs: energy, the rain
# announcement that is this app's whole point, and escalation on the third snooze.
LINES = [
    ("energetic", "起床囉！現在七點整，再賴下去就要遲到了！"),
    ("rain", "早安，今天路上會下雨，記得帶傘，早點出門比較保險。"),
    ("urgent", "喂，醒醒！鬧鐘已經響第三次了，你真的該起來了！"),
]

STYLE = "用非常有精神、充滿活力的語氣說，音量大、語速稍快，像是在叫醒一個賴床的人。請用台灣口音的中文。"


def post(url, body, headers, binary=False):
    req = urllib.request.Request(
        url, data=json.dumps(body).encode(), headers={"Content-Type": "application/json", **headers}
    )
    with urllib.request.urlopen(req, timeout=120) as r:
        return r.read() if binary else json.loads(r.read())


def openai(text):
    key = os.environ.get("OPENAI_API_KEY")
    if not key:
        return None
    audio = post(
        "https://api.openai.com/v1/audio/speech",
        {
            "model": "gpt-4o-mini-tts",
            "voice": "nova",
            "input": text,
            "instructions": STYLE,
            "response_format": "wav",
        },
        {"Authorization": f"Bearer {key}"},
        binary=True,
    )
    return audio, "wav"


def wrap_pcm(pcm, rate=24000):
    """Gemini returns headerless 16-bit mono PCM; nothing will play it without a RIFF header."""
    buf = io.BytesIO()
    with wave.open(buf, "wb") as w:
        w.setnchannels(1)
        w.setsampwidth(2)
        w.setframerate(rate)
        w.writeframes(pcm)
    return buf.getvalue()


def find_audio(obj):
    """The interactions and generateContent APIs bury the audio at different paths, but both
    hide exactly one long base64 blob. Take the longest string rather than guess the schema."""
    best, stack = None, [obj]
    while stack:
        cur = stack.pop()
        if isinstance(cur, dict):
            stack.extend(cur.values())
        elif isinstance(cur, list):
            stack.extend(cur)
        elif isinstance(cur, str) and len(cur) > 1000 and (best is None or len(cur) > len(best)):
            best = cur
    return base64.b64decode(best) if best else None


def google(text):
    """Gemini API, not Cloud TTS: Cloud TTS rejects API keys and wants a service account,
    which is too much ceremony for a bake-off. The trade-off is that there is no `cmn-TW`
    locale field here — the Taiwanese accent has to come out of the prompt."""
    key = os.environ.get("GEMINI_API_KEY") or os.environ.get("GOOGLE_API_KEY")
    if not key:
        return None
    res = post(
        "https://generativelanguage.googleapis.com/v1beta/interactions",
        {
            "model": os.environ.get("GEMINI_TTS_MODEL", "gemini-3.1-flash-tts-preview"),
            "input": f"{STYLE}\n\n{text}",
            "response_format": {"type": "audio"},
            "generation_config": {"speech_config": [{"voice": os.environ.get("GEMINI_VOICE", "Zephyr")}]},
        },
        {"x-goog-api-key": key},
    )
    pcm = find_audio(res)
    if pcm is None:
        raise RuntimeError(f"no audio in response: {json.dumps(res)[:300]}")
    return wrap_pcm(pcm), "wav"


def elevenlabs(text):
    key = os.environ.get("ELEVENLABS_API_KEY")
    if not key:
        return None
    voice_id = os.environ.get("ELEVENLABS_VOICE_ID", "21m00Tcm4TlvDq8ikWAM")
    audio = post(
        f"https://api.elevenlabs.io/v1/text-to-speech/{voice_id}?output_format=mp3_44100_128",
        {"text": f"[excited] {text}", "model_id": "eleven_v3"},
        {"xi-api-key": key},
        binary=True,
    )
    return audio, "mp3"


def minimax(text):
    key, group = os.environ.get("MINIMAX_API_KEY"), os.environ.get("MINIMAX_GROUP_ID")
    if not (key and group):
        return None
    res = post(
        f"https://api.minimax.io/v1/t2a_v2?GroupId={group}",
        {
            "model": "speech-2.8-hd",
            "text": text,
            "stream": False,
            "output_format": "hex",
            "language_boost": "Chinese",
            "voice_setting": {
                "voice_id": os.environ.get("MINIMAX_VOICE_ID", "Chinese (Mandarin)_Warm_Bestie"),
                "speed": 1.1,
                "vol": 1,
                "pitch": 0,
                "emotion": "happy",
            },
            "audio_setting": {"sample_rate": 32000, "bitrate": 128000, "format": "mp3", "channel": 1},
        },
        {"Authorization": f"Bearer {key}"},
    )
    return bytes.fromhex(res["data"]["audio"]), "mp3"


VENDORS = [("openai", openai), ("google", google), ("elevenlabs", elevenlabs), ("minimax", minimax)]


def main():
    outdir = sys.argv[1] if len(sys.argv) > 1 else "out/tts-bakeoff"
    os.makedirs(outdir, exist_ok=True)

    produced = []
    for line_name, text in LINES:
        for vendor_name, fn in VENDORS:
            try:
                result = fn(text)
            except urllib.error.HTTPError as e:
                print(f"  {vendor_name:11s} {line_name:10s} HTTP {e.code}: {e.read()[:300].decode(errors='replace')}")
                continue
            except Exception as e:
                print(f"  {vendor_name:11s} {line_name:10s} failed: {e}")
                continue
            if result is None:
                continue
            audio, ext = result
            produced.append((line_name, vendor_name, audio, ext))
            print(f"  {vendor_name:11s} {line_name:10s} ok, {len(audio) // 1024} KB")

    if not produced:
        print("\nNothing generated — no API keys set. See the docstring.")
        return 1

    # Blind labels: you should not know who is speaking until after you have judged.
    random.shuffle(produced)
    key_lines = []
    for i, (line_name, vendor_name, audio, ext) in enumerate(produced, 1):
        label = f"sample-{i:02d}.{ext}"
        with open(os.path.join(outdir, label), "wb") as f:
            f.write(audio)
        key_lines.append(f"{label}\t{vendor_name}\t{line_name}")

    with open(os.path.join(outdir, "_key.txt"), "w") as f:
        f.write("\n".join(sorted(key_lines)) + "\n")

    print(f"\n{len(produced)} samples in {outdir}/. Judge before opening _key.txt:")
    print("  1. Does it sound Taiwanese, or Beijing / foreign-accented?")
    print("  2. Is it genuinely energetic, or polite-flat pretending?")
    print("  3. Would it actually wake you up?")
    return 0


if __name__ == "__main__":
    sys.exit(main())
