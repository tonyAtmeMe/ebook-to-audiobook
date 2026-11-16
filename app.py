import os
import sys
from pathlib import Path

# --- ROBUST MULTI-FOLDER DLL & PATH INJECTION FOR WINDOWS SESSION 0 ---
_current_dir = Path(__file__).parent.resolve()
_site_packages = _current_dir / ".venv" / "Lib" / "site-packages"
_torch_dir = _site_packages / "torch"
_torch_lib = _site_packages / "torch" / "lib"

for _p in [_torch_lib, _torch_dir, _site_packages]:
    if _p.exists():
        if hasattr(os, "add_dll_directory"):
            try:
                os.add_dll_directory(str(_p))
            except Exception:
                pass
        current_path = os.environ.get("PATH", "")
        os.environ["PATH"] = str(_p) + ";" + current_path

# Force Hugging Face cache to short root path to prevent Windows MAX_PATH length crashes
os.environ["HF_HOME"] = str(_current_dir / ".cache")
Path(os.environ["HF_HOME"]).mkdir(parents=True, exist_ok=True)

# Force unbuffered standard output and error for real-time NSSM logging without NUL padding
try:
    sys.stdout.reconfigure(line_buffering=True)
    sys.stderr.reconfigure(line_buffering=True)
except Exception:
    pass

import time
import re
import threading
import queue
import shutil
import subprocess

from fastapi import FastAPI
from fastapi.responses import HTMLResponse, JSONResponse
import uvicorn

from pypdf import PdfReader
import ebooklib
from ebooklib import epub
from docx import Document

from kokoro import KPipeline
import soundfile as sf
import numpy as np

# Folder Configurations (Absolute Root Isolation)
INBOX_FOLDER = Path(r"C:\AudiobookInbox")
ARCHIVE_FOLDER = Path(r"C:\AudiobookInbox\archive")
PROCESSING_STAGE_FOLDER = Path(r"C:\AudiobookInbox\processing")
OUTPUT_FOLDER = Path(r"C:\AudiobookCloud")

INBOX_FOLDER.mkdir(parents=True, exist_ok=True)
ARCHIVE_FOLDER.mkdir(parents=True, exist_ok=True)
PROCESSING_STAGE_FOLDER.mkdir(parents=True, exist_ok=True)
OUTPUT_FOLDER.mkdir(parents=True, exist_ok=True)

CALIBRE_PATH = r"C:\Program Files\Calibre2\ebook-convert.exe"

# --- WEB DASHBOARD FASTAPI APP (Instantiated early so Uvicorn finds it) ---
app = FastAPI()

# Global reference for TTS pipeline
tts_pipeline = None

# Shared Thread-Safe Global State for Dashboard
STATE = {
    "is_paused": False,
    "total_converted": 0,
    "pending_queue": [],
    "active_queue": [],
    "recent_jobs": []
}
STATE_LOCK = threading.Lock()

# Sequential Processing Queue & Worker
PROCESSING_QUEUE = queue.Queue()
PROCESSED_HISTORY = set()
HISTORY_LOCK = threading.Lock()

# Cancellation tracking
CANCELLED_JOBS = set()
CANCELLED_LOCK = threading.Lock()

class EbookProcessor:
    @staticmethod
    def preprocess_file(file_path: Path) -> Path:
        ext = file_path.suffix.lower()
        supported_convert_formats = {".mobi", ".azw3", ".fb2", ".djvu", ".prc"}
        if ext in supported_convert_formats:
            out_epub = file_path.with_suffix(".epub")
            print(f"[*] Converting {ext.upper()[1:]} to EPUB via Calibre: {file_path.name}")
            try:
                subprocess.run(
                    [CALIBRE_PATH, str(file_path), str(out_epub)],
                    check=True,
                    stdout=subprocess.DEVNULL,
                    stderr=subprocess.DEVNULL
                )
                file_path.unlink(missing_ok=True)
                return out_epub
            except Exception as e:
                print(f"[!] Calibre conversion failed: {e}")
                raise e
        return file_path

    @staticmethod
    def extract_text(file_path: Path) -> str:
        ext = file_path.suffix.lower()
        text = ""
        if ext == ".txt":
            with open(file_path, "r", encoding="utf-8", errors="ignore") as f:
                text = f.read()
        elif ext == ".pdf":
            reader = PdfReader(str(file_path))
            for page in reader.pages:
                t = page.extract_text()
                if t: text += t + "\n"
        elif ext == ".epub":
            book = epub.read_epub(str(file_path))
            for item in book.get_items():
                if item.get_type() == ebooklib.ITEM_DOCUMENT:
                    raw = item.get_content().decode("utf-8", errors="ignore")
                    text += re.sub(r'<[^>]+>', ' ', raw) + "\n"
        elif ext == ".docx":
            doc = Document(str(file_path))
            text = "\n".join([p.text for p in doc.paragraphs])
        return text

    @staticmethod
    def clean_noise(text: str) -> str:
        if not text:
            return ""

        # Filter out spurious "m13" / "M13" markers and non-word artifacts
        text = re.sub(r'\b[mM]13\b', '', text)

        def filter_artifact_token(match):
            token = match.group(0)
            allowed_tokens = {'1st', '2nd', '3rd', '4th', 'mm', 'cm', 'kg', 'ml', 'kb', 'gb'}
            if token.lower() in allowed_tokens:
                return token
            has_alpha = any(c.isalpha() for c in token)
            has_digit = any(c.isdigit() for c in token)
            if has_alpha and has_digit:
                return ""
            return token

        text = re.sub(r'\b[a-zA-Z0-9]+\b', filter_artifact_token, text)

        copyright_pattern = re.compile(r'(all rights reserved|copyright ©|isbn|published by)', re.IGNORECASE)
        page_num_pattern = re.compile(r'^(page\s*)?\d+$', re.IGNORECASE)
        cleaned = []
        for line in text.splitlines():
            s = line.strip()
            if not s or s.lower() == 'm13' or page_num_pattern.match(s) or (copyright_pattern.search(s) and len(s) < 120):
                continue
            cleaned.append(s)
        
        result_text = "\n".join(cleaned)
        result_text = re.sub(r'[ \t]+', ' ', result_text)
        return result_text

    @classmethod
    def process_file(cls, job_id: str, original_file_path: Path):
        global tts_pipeline
        if tts_pipeline is None:
            raise RuntimeError("TTS Pipeline is not initialized.")

        with CANCELLED_LOCK:
            if job_id in CANCELLED_JOBS:
                CANCELLED_JOBS.remove(job_id)
                return

        job_info = {
            "id": job_id,
            "title": original_file_path.name,
            "format": original_file_path.suffix.upper().replace('.', ''),
            "status": "processing",
            "progress": 10,
            "size": f"{round(original_file_path.stat().st_size / (1024*1024), 2)} MB"
        }
        
        with STATE_LOCK:
            STATE["pending_queue"] = [j for j in STATE["pending_queue"] if j["id"] != job_id]
            STATE["active_queue"].append(job_info)
            
        try:
            file_path = cls.preprocess_file(original_file_path)
            
            with CANCELLED_LOCK:
                if job_id in CANCELLED_JOBS:
                    raise InterruptedError("Job cancelled by user.")

            raw_text = cls.extract_text(file_path)
            with STATE_LOCK: job_info["progress"] = 30
            
            with CANCELLED_LOCK:
                if job_id in CANCELLED_JOBS:
                    raise InterruptedError("Job cancelled by user.")

            clean_text = cls.clean_noise(raw_text)
            with STATE_LOCK: job_info["progress"] = 50
            
            if not clean_text.strip():
                raise ValueError("Extracted text is empty after cleaning.")

            temp_wav = OUTPUT_FOLDER / f"{file_path.stem}_temp.wav"
            out_file = OUTPUT_FOLDER / f"{file_path.stem}.mp3"
            
            generator = tts_pipeline(clean_text, voice='af_heart', speed=1.0)
            
            chunk_count = 0
            with sf.SoundFile(str(temp_wav), mode='w', samplerate=24000, channels=1) as sf_writer:
                for gs, ps, audio in generator:
                    with CANCELLED_LOCK:
                        if job_id in CANCELLED_JOBS:
                            raise InterruptedError("Job cancelled by user.")

                    if audio is not None and len(audio) > 0:
                        if hasattr(audio, "detach"):
                            audio = audio.detach().cpu().numpy()
                        elif not isinstance(audio, np.ndarray):
                            audio = np.array(audio)
                        
                        sf_writer.write(audio)
                        chunk_count += 1
                        if chunk_count % 20 == 0:
                            sf_writer.flush()
                            with STATE_LOCK:
                                if job_info["progress"] < 80:
                                    job_info["progress"] = min(80, job_info["progress"] + 1)
                
            with STATE_LOCK:
                job_info["progress"] = 85
                job_info["status"] = "compressing..."

            print(f"[*] Compressing audio to MP3: {out_file.name}")
            try:
                subprocess.run(
                    ["ffmpeg", "-y", "-i", str(temp_wav), "-codec:a", "libmp3lame", "-b:a", "192k", str(out_file)],
                    check=True,
                    stdout=subprocess.DEVNULL,
                    stderr=subprocess.DEVNULL
                )
                temp_wav.unlink(missing_ok=True)
            except Exception as ffmpeg_err:
                print(f"[!] FFmpeg compression failed ({ffmpeg_err}), falling back to WAV format.")
                fallback_wav = OUTPUT_FOLDER / f"{file_path.stem}.wav"
                if temp_wav.exists():
                    shutil.move(str(temp_wav), str(fallback_wav))
                out_file = fallback_wav

            with STATE_LOCK:
                job_info["status"] = "completed"
                job_info["progress"] = 100
                STATE["total_converted"] += 1
                STATE["active_queue"] = [j for j in STATE["active_queue"] if j["id"] != job_id]
                STATE["recent_jobs"].insert(0, job_info)
            print(f"[*] Successfully completed: {original_file_path.name} -> {out_file.name}")

            # Archive original file out of staging to archive folder
            try:
                if original_file_path.exists():
                    target_archive = ARCHIVE_FOLDER / original_file_path.name
                    if target_archive.exists():
                        target_archive.unlink(missing_ok=True)
                    shutil.move(str(original_file_path), str(target_archive))
                    print(f"[*] Archived file to: {target_archive}")
            except Exception as arch_err:
                print(f"[!] Warning: Could not archive file: {arch_err}")

        except InterruptedError:
            print(f"[*] Job {job_id} ({original_file_path.name}) was cancelled.")
            with STATE_LOCK:
                job_info["status"] = "cancelled"
                job_info["progress"] = 0
                STATE["active_queue"] = [j for j in STATE["active_queue"] if j["id"] != job_id]
                STATE["recent_jobs"].insert(0, job_info)
            temp_wav = OUTPUT_FOLDER / f"{file_path.stem}_temp.wav"
            if temp_wav.exists():
                temp_wav.unlink(missing_ok=True)
        except Exception as e:
            print(f"[!] Error processing {original_file_path.name}: {e}")
            with STATE_LOCK:
                job_info["status"] = "failed"
                job_info["error"] = str(e)
                STATE["active_queue"] = [j for j in STATE["active_queue"] if j["id"] != job_id]
                STATE["recent_jobs"].insert(0, job_info)
        finally:
            with CANCELLED_LOCK:
                if job_id in CANCELLED_JOBS:
                    CANCELLED_JOBS.remove(job_id)

def background_worker():
    while True:
        item = PROCESSING_QUEUE.get()
        job_id, file_path = item
        try:
            with CANCELLED_LOCK:
                if job_id in CANCELLED_JOBS:
                    CANCELLED_JOBS.remove(job_id)
                    continue
            
            staged_path = PROCESSING_STAGE_FOLDER / file_path.name
            if file_path.exists():
                if staged_path.exists():
                    staged_path.unlink(missing_ok=True)
                shutil.move(str(file_path), str(staged_path))
            else:
                staged_path = file_path

            EbookProcessor.process_file(job_id, staged_path)
        except Exception as e:
            print(f"[!] Worker error processing {file_path}: {e}")
        finally:
            PROCESSING_QUEUE.task_done()
            with HISTORY_LOCK:
                PROCESSED_HISTORY.discard(file_path.name)

def poll_inbox_directory():
    print(f"[*] Polling thread active. Scanning directory: {INBOX_FOLDER}")
    supported_extensions = {".epub", ".pdf", ".docx", ".txt", ".mobi", ".azw3", ".fb2", ".djvu", ".prc"}
    while True:
        try:
            if not INBOX_FOLDER.exists():
                print(f"[!] Inbox folder does not exist: {INBOX_FOLDER}")
            elif not STATE["is_paused"]:
                for fp in INBOX_FOLDER.iterdir():
                    if fp.is_dir():
                        continue
                        
                    if fp.is_file() and fp.suffix.lower() in supported_extensions:
                        # File stability check (ensures copy is fully complete before processing)
                        try:
                            size1 = fp.stat().st_size
                            time.sleep(0.3)
                            size2 = fp.stat().st_size
                            if size1 != size2 or size1 == 0:
                                continue
                        except Exception:
                            continue

                        try:
                            with open(fp, "rb"):
                                pass
                        except IOError:
                            continue

                        with HISTORY_LOCK:
                            if fp.name in PROCESSED_HISTORY:
                                continue
                            PROCESSED_HISTORY.add(fp.name)

                        with STATE_LOCK:
                            if any(j["title"] == fp.name for j in STATE["active_queue"] + STATE["pending_queue"]):
                                with HISTORY_LOCK:
                                    PROCESSED_HISTORY.discard(fp.name)
                                continue

                        print(f"[PollingWatcher] Detected & Queued file: {fp.name}")
                        job_id = f"job-{int(time.time())}-{os.urandom(2).hex()}"
                        job_meta = {
                            "id": job_id,
                            "title": fp.name,
                            "format": fp.suffix.upper().replace('.', ''),
                            "status": "queued",
                            "progress": 0,
                            "size": f"{round(fp.stat().st_size / (1024*1024), 2)} MB"
                        }
                        with STATE_LOCK:
                            STATE["pending_queue"].append(job_meta)

                        PROCESSING_QUEUE.put((job_id, fp))
        except Exception as e:
            import traceback
            print(f"[!] Polling watcher exception: {e}")
            traceback.print_exc()
        
        time.sleep(3.0)

@app.on_event("startup")
def startup_event():
    global tts_pipeline
    print("[*] Initializing Kokoro TTS Pipeline during application startup...")
    try:
        tts_pipeline = KPipeline(lang_code='a')
        print("[+] Kokoro TTS Pipeline initialized successfully.")
    except Exception as e:
        print(f"[!] Critical Error initializing Kokoro TTS Pipeline: {e}")

    worker_thread = threading.Thread(target=background_worker, daemon=True)
    worker_thread.start()

    poller_thread = threading.Thread(target=poll_inbox_directory, daemon=True)
    poller_thread.start()
    print("[*] Background worker and inbox polling scanner started successfully.")

@app.get("/api/status")
def get_status():
    total, used, free = shutil.disk_usage(OUTPUT_FOLDER)
    with STATE_LOCK:
        return JSONResponse({
            "is_paused": STATE["is_paused"],
            "total_converted": STATE["total_converted"],
            "inbox_path": str(INBOX_FOLDER),
            "pending": STATE["pending_queue"],
            "active": STATE["active_queue"],
            "recent": STATE["recent_jobs"][:10],
            "disk": {
                "used_gb": round(used / (1024**3), 2),
                "free_gb": round(free / (1024**3), 2),
                "total_gb": round(total / (1024**3), 2)
            }
        })

@app.post("/api/toggle-watcher")
def toggle_watcher():
    with STATE_LOCK:
        STATE["is_paused"] = not STATE["is_paused"]
        return JSONResponse({"is_paused": STATE["is_paused"]})

@app.post("/api/cancel/{job_id}")
def cancel_job(job_id: str):
    with CANCELLED_LOCK:
        CANCELLED_JOBS.add(job_id)
    
    with STATE_LOCK:
        for job in STATE["active_queue"]:
            if job["id"] == job_id:
                job["status"] = "cancelling..."
        STATE["pending_queue"] = [j for j in STATE["pending_queue"] if j["id"] != job_id]
    return {"status": "success", "cancelled_job": job_id}

@app.get("/", response_class=HTMLResponse)
def index():
    html_path = Path(__file__).parent / "audiobook_pipeline_dashboard.html"
    if html_path.exists():
        return html_path.read_text(encoding="utf-8")
    return "<h3>Dashboard HTML file not found. Make sure audiobook_pipeline_dashboard.html is placed in C:\\EbookAutomation</h3>"

if __name__ == "__main__":
    uvicorn.run("app:app", host="127.0.0.1", port=8000, reload=False)