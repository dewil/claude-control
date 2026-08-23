#!/usr/bin/env python3
"""voice-report - озвучить текст отчета и (по флагу) отправить голосовым в Telegram.

Зачем: результат работы читается глазами, а слушать его можно на ходу - за
рулем, на велосипеде, в дороге. Голосовое сообщение снимает необходимость
останавливаться и открывать экран.

Движок - Silero TTS v4 (русский, offline, CPU). Модель (39 МБ) лежит в
~/.cache/silero-tts/v4_ru.pt и скачивается при первом запуске. torch берется из
venv ~/.venvs/asr (тот же, что у local-transcription): своего venv скрипт не
заводит и в систему ничего не ставит.

    python3 scripts/voice-report.py --file итог.txt --send bot --caption "проект: итог"
    echo "..." | python3 scripts/voice-report.py --out /tmp/итог.ogg
    python3 scripts/voice-report.py --file итог.txt --send me   # запасной путь, нужен telethon

Адресат - только свой: "bot" (свой Telegram-бот, stdlib, работает везде) или
"me" (Избранное, нужна сессия Telethon). Голосовое третьему лицу - через
telegram-send-one.py: там дефолтный dry-run и сверка получателя.

Текст пишется ДЛЯ ПРОИЗНЕСЕНИЯ: без разметки, путей, латиницы и цифр -
подробности в скилле voice-report. Скрипт снимает markdown, но не переписывает
за автора.

Зависимости: torch (в venv), ffmpeg с libopus (оба уже стоят на машине).
"""
from __future__ import annotations

import argparse
import os
import re
import shutil
import subprocess
import sys
import tempfile
import urllib.request
import wave
from pathlib import Path

MODEL_URL = "https://models.silero.ai/models/tts/ru/v4_ru.pt"
MODEL_PATH = Path(os.environ.get("SILERO_TTS_MODEL", Path.home() / ".cache" / "silero-tts" / "v4_ru.pt"))
VENV_PYTHON = Path(os.environ.get("VOICE_REPORT_PYTHON", Path.home() / ".venvs" / "asr" / "bin" / "python"))
SAMPLE_RATE = 48000
# Silero режет длинный вход, поэтому дробим сами. Порог с запасом от лимита
# модели: лучше лишний стык между фразами, чем молча потерянный хвост.
CHUNK_LIMIT = 800
# Первым идет голос по умолчанию. Женский - выбор dwl 23.08.2026 после
# прослушивания обоих: на скорости 1,5 он разборчивее мужского.
SPEAKERS = ("xenia", "baya", "kseniya", "eugene", "aidar")
# Слушатель держит в клиенте скорость 1,5 и переключать ее ради наших сообщений
# не станет, поэтому синтез замедляется под нее. Чистая арифметика дала бы
# 1/1.5 = 0.67, но на слух это медленно (две проверки dwl 23.08.2026):
# Silero и без того говорит размеренно, и компенсировать скорость плеера
# полностью не нужно - 0.92 почти не замедляет.
# Слушать на 1x специально не предполагается.
DEFAULT_TEMPO = 0.92
LISTENING_SPEED = 1.5
HERE = Path(__file__).resolve().parent


def strip_markup(text: str) -> str:
    """Снять разметку, которую диктор прочитал бы вслух как мусор."""
    text = re.sub(r"```.*?```", " ", text, flags=re.S)
    text = re.sub(r"`([^`]*)`", r"\1", text)
    text = re.sub(r"^\s{0,3}#{1,6}\s*", "", text, flags=re.M)
    text = re.sub(r"\*\*([^*]*)\*\*", r"\1", text)
    text = re.sub(r"\*([^*]*)\*", r"\1", text)
    text = re.sub(r"^\s*[-*]\s+", "", text, flags=re.M)
    text = re.sub(r"\[([^\]]*)\]\([^)]*\)", r"\1", text)
    text = re.sub(r"[ \t]+", " ", text)
    return re.sub(r"\n{2,}", "\n", text).strip()


def split_chunks(text: str, limit: int = CHUNK_LIMIT) -> list[str]:
    """Резать по границам предложений, а не по символам: разрыв посреди фразы
    слышен как сбой дыхания."""
    parts: list[str] = []
    current = ""

    def flush() -> None:
        nonlocal current
        if current:
            parts.append(current)
            current = ""

    for sentence in re.split(r"(?<=[.!?…])\s+", text):
        sentence = sentence.strip()
        if not sentence:
            continue
        if len(sentence) > limit:
            # ДО дробления длинного предложения выкладываем накопленное: иначе
            # его куски встанут в очередь раньше предыдущей фразы, и отчет
            # прозвучит с переставленными местами кусками - валидное голосовое
            # с искаженным смыслом
            flush()
            while len(sentence) > limit:
                cut = sentence.rfind(" ", 0, limit)
                cut = cut if cut > 0 else limit
                parts.append(sentence[:cut].strip())
                sentence = sentence[cut:].strip()
        if len(current) + len(sentence) + 1 > limit:
            flush()
            current = sentence
        else:
            current = f"{current} {sentence}".strip()
    flush()
    return parts


def ensure_model() -> Path:
    if MODEL_PATH.exists():
        return MODEL_PATH
    MODEL_PATH.parent.mkdir(parents=True, exist_ok=True)
    sys.stderr.write(f"качаю модель Silero (39 МБ) -> {MODEL_PATH}\n")
    tmp = MODEL_PATH.with_suffix(".part")
    try:
        urllib.request.urlretrieve(MODEL_URL, tmp)
        tmp.replace(MODEL_PATH)
    except Exception as exc:
        tmp.unlink(missing_ok=True)
        sys.exit(f"не удалось скачать модель: {exc}")
    return MODEL_PATH


def reexec_in_venv() -> None:
    """torch живет в venv; свой интерпретатор ему не нужен, чужой - не подходит.

    Маркер в окружении обязателен: venv, в котором torch тоже нет, вызывал бы
    сам себя без конца - процесс живет, работа не идет, в логе тишина.
    """
    if os.environ.get("VOICE_REPORT_REEXEC"):
        sys.exit(
            f"в {VENV_PYTHON} нет torch (перезапуск уже был). Поставь его туда "
            "или укажи другой интерпретатор через VOICE_REPORT_PYTHON"
        )
    if not VENV_PYTHON.exists():
        sys.exit(
            f"нет torch в текущем python и нет venv {VENV_PYTHON}.\n"
            "Укажи интерпретатор с torch через VOICE_REPORT_PYTHON."
        )
    os.environ["VOICE_REPORT_REEXEC"] = "1"
    os.execv(str(VENV_PYTHON), [str(VENV_PYTHON), str(Path(__file__).resolve()), *sys.argv[1:]])


def synthesize(chunks: list[str], speaker: str, threads: int) -> "list":
    import torch

    torch.set_num_threads(threads)
    model = torch.package.PackageImporter(str(ensure_model())).load_pickle("tts_models", "model")
    model.to(torch.device("cpu"))
    pieces = []
    pause = torch.zeros(int(SAMPLE_RATE * 0.25))
    for i, chunk in enumerate(chunks, 1):
        sys.stderr.write(f"  синтез {i}/{len(chunks)} ({len(chunk)} симв.)\n")
        audio = model.apply_tts(
            text=chunk, speaker=speaker, sample_rate=SAMPLE_RATE, put_accent=True, put_yo=True
        )
        pieces.extend([audio, pause])
    return torch.cat(pieces) if pieces else torch.zeros(0)


def write_wav(audio, path: Path) -> float:
    import numpy as np

    samples = (audio.numpy() * 32767).clip(-32768, 32767).astype(np.int16)
    with wave.open(str(path), "wb") as w:
        w.setnchannels(1)
        w.setsampwidth(2)
        w.setframerate(SAMPLE_RATE)
        w.writeframes(samples.tobytes())
    return len(samples) / SAMPLE_RATE


def find_ffmpeg() -> str:
    ffmpeg = shutil.which("ffmpeg") or str(Path.home() / ".local" / "bin" / "ffmpeg")
    if not Path(ffmpeg).exists():
        sys.exit("нужен ffmpeg с libopus - без него Telegram не примет файл как голосовое")
    probe = subprocess.run([ffmpeg, "-hide_banner", "-encoders"], capture_output=True, text=True)
    if "libopus" not in probe.stdout:
        sys.exit(f"{ffmpeg} собран без libopus - голосовое из него не соберется")
    return ffmpeg


def to_opus(wav: Path, out: Path, tempo: float = DEFAULT_TEMPO) -> None:
    ffmpeg = find_ffmpeg()
    # 32 кбит/с моно - формат голосовых Telegram; больше не нужно, речь не музыка
    filters = [] if abs(tempo - 1.0) < 0.01 else [f"atempo={tempo:.3f}"]
    cmd = [ffmpeg, "-y", "-loglevel", "error", "-i", str(wav)]
    if filters:
        cmd += ["-filter:a", ",".join(filters)]
    cmd += ["-c:a", "libopus", "-b:a", "32k", "-ac", "1", "-ar", "48000", str(out)]
    res = subprocess.run(cmd, capture_output=True, text=True)
    if res.returncode != 0:
        sys.exit(f"ffmpeg не смог собрать ogg: {res.stderr.strip()[:300]}")


def send(path: Path, chat: str, caption: str, silent: bool, account: str) -> int:
    sender = HERE / "telegram-send-one.py"
    if not sender.exists():
        sys.exit(f"нет {sender} - отправка невозможна, файл остался в {path}")
    # НЕ sys.executable: синтез идет под venv с torch, а telethon стоит в
    # системном python. Унаследованный интерпретатор давал "telethon не
    # установлен" уже после того, как файл озвучен
    sender_python = os.environ.get("VOICE_REPORT_SENDER_PYTHON") or shutil.which("python3") or "python3"
    cmd = [sender_python, str(sender), chat, "--file", str(path), "--voice", "--send",
           "--text", caption, "--account", account]
    if silent:
        cmd.append("--silent")
    return subprocess.run(cmd).returncode


def send_via_bot(path: Path, caption: str, silent: bool) -> int:
    """Транспорт через своего бота: не требует telethon и пользовательской
    сессии, поэтому работает в проекте любого типа - в отличие от пути "me"."""
    sender = HERE / "tg-bot-voice.py"
    if not sender.exists():
        sys.exit(f"нет {sender} - отправка невозможна, файл остался в {path}")
    sender_python = os.environ.get("VOICE_REPORT_SENDER_PYTHON") or shutil.which("python3") or "python3"
    cmd = [sender_python, str(sender), "send", str(path), "--caption", caption]
    if silent:
        cmd.append("--silent")
    return subprocess.run(cmd).returncode


def main() -> int:
    parser = argparse.ArgumentParser(description="Озвучить отчет и отправить голосовым в Telegram.")
    src = parser.add_mutually_exclusive_group()
    src.add_argument("--text", help="текст для озвучки; без него и без --file читается stdin")
    src.add_argument("--file", help="файл с текстом")
    parser.add_argument("--out", help="куда положить ogg (по умолчанию - временный файл)")
    parser.add_argument("--speaker", default="xenia", choices=SPEAKERS,
                        help="голос диктора (по умолчанию xenia)")
    parser.add_argument("--tempo", type=float, default=DEFAULT_TEMPO,
                        help=f"замедление речи (по умолчанию {DEFAULT_TEMPO}: рассчитано на "
                             f"прослушивание в клиенте на скорости {LISTENING_SPEED}x). "
                             "1.0 - нормальный темп для прослушивания на 1x")
    parser.add_argument("--threads", type=int, default=4, help="потоков CPU на синтез")
    parser.add_argument("--send", metavar="CHAT",
                        help="отправить голосовым САМОМУ СЕБЕ: \"me\" (Избранное) или \"bot\" "
                             "(свой Telegram-бот, работает без telethon). Чужой чат сюда не "
                             "принимается: у отправки третьему лицу свой гейт подтверждения, "
                             "и она делается через telegram-send-one.py напрямую")
    parser.add_argument("--caption", default="", help="подпись к голосовому (что за сессия, проект)")
    parser.add_argument("--silent", action="store_true", help="отправить без звука")
    parser.add_argument("--account", default="default", help="аккаунт из auth.json")
    parser.add_argument("--keep-wav", action="store_true", help="не удалять промежуточный wav")
    args = parser.parse_args()

    target = args.send.strip().lower() if args.send else None
    if target and target not in ("me", "bot"):
        sys.exit(
            f"--send {args.send!r}: принимаются только \"me\" и \"bot\" - свои адреса. "
            "Голосовое третьему лицу отправляй через telegram-send-one.py: там дефолт dry-run "
            "и сверка получателя, которых у этого пути нет"
        )

    if args.text is not None:
        if not args.text.strip():
            sys.exit("--text задан пустой строкой - проверь переменную с текстом")
        raw = args.text
    elif args.file is not None:
        if not args.file:
            sys.exit("--file задан пустой строкой - проверь переменную с путем")
        source = Path(args.file).expanduser()
        if not source.is_file():
            sys.exit(f"файл не найден: {source}")
        raw = source.read_text(encoding="utf-8")
    else:
        raw = sys.stdin.read()
    text = strip_markup(raw)
    if not text.strip():
        sys.exit("пустой текст - озвучивать нечего")
    if not re.search(r"\w", text):
        sys.exit("в тексте нет ни одного слова - озвучивать нечего")
    if not 0.5 <= args.tempo <= 2.0:
        sys.exit(f"--tempo {args.tempo}: ffmpeg принимает множитель от 0.5 до 2.0")
    find_ffmpeg()

    try:
        import torch  # noqa: F401
    except ImportError:
        reexec_in_venv()

    chunks = split_chunks(text)
    audio = synthesize(chunks, args.speaker, args.threads)
    if args.out:
        out = Path(args.out).expanduser()
        out.parent.mkdir(parents=True, exist_ok=True)
    else:
        out = Path(tempfile.mkdtemp(prefix="voice-report-")) / "итог.ogg"
    wav = out.with_suffix(".wav")
    seconds = write_wav(audio, wav)
    to_opus(wav, out, args.tempo)
    if not args.keep_wav:
        wav.unlink(missing_ok=True)
    seconds = seconds / args.tempo
    mins, secs = divmod(int(seconds + 0.5), 60)
    print(f"OK: {out} ({mins}:{secs:02d}, {out.stat().st_size // 1024} КБ)")

    if target:
        if target == "bot":
            return send_via_bot(out, args.caption, args.silent)
        return send(out, "me", args.caption, args.silent, args.account)
    return 0


if __name__ == "__main__":
    sys.exit(main())
