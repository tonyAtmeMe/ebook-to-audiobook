# Ebook-to-Audiobook Local Pipeline & Web Dashboard

An automated background service for Windows that monitors an inbox folder, extracts text from multiple e-book formats (`.epub`, `.pdf`, `.docx`, `.txt`), cleans extraneous noise (page numbers, copyright notices, metadata blocks), converts the text to natural speech using **Kokoro-82M**, exports the audio to a cloud folder, and provides a lightweight real-time monitoring web dashboard.

---

## System Requirements & Downloads

1. **Python 3.10+**: Download and install from [python.org](https://www.python.org/). Ensure you check **"Add Python to PATH"** during installation.
2. **eSpeak-NG (System Dependency for Kokoro)**: 
   * Kokoro relies on `espeak-ng` for text-to-phoneme tokenization.
   * Download the Windows installer from the [eSpeak NG GitHub Releases page](https://github.com/espeak-ng/espeak-ng/releases) and install it (ensure it is added to your system path, or install via chocolatey: `choco install espeak-ng`).
3. **NSSM (Non-Sucking Service Manager)**: Download from [nssm.cc](https://nssm.cc/) to wrap the script into a native Windows background service.

---

## Directory Structure

Create a root directory for your application (e.g., `C:\EbookAutomation`):
```text
C:\EbookAutomation\
│
├── app.py              # Main background script & web server
└── requirements.txt    # Python dependencies