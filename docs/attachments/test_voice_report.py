#!/usr/bin/env python3
"""Тесты voice-report: подготовка текста к синтезу. stdlib-only (unittest).

Запуск: python3 tests/test_voice_report.py

Синтез и отправку не трогаем - они требуют torch, модели и живой сессии
Telegram. Проверяются чистые функции: снятие разметки и дробление на куски.
Обе решают одну задачу - диктор не должен читать вслух мусор и не должен
терять хвост длинного текста.
"""
from __future__ import annotations

import importlib.util
import unittest
from pathlib import Path

SCRIPTS = Path(__file__).resolve().parent.parent / "scripts"
spec = importlib.util.spec_from_file_location("voice_report", SCRIPTS / "voice-report.py")
VR = importlib.util.module_from_spec(spec)
spec.loader.exec_module(VR)


class StripMarkupTest(unittest.TestCase):
    def test_headers_and_bold_dropped(self):
        got = VR.strip_markup("## Итог\n\n**Готово**, тесты зеленые.")
        self.assertEqual(got, "Итог\nГотово, тесты зеленые.")

    def test_code_fence_dropped_entirely(self):
        """Блок кода диктор прочитал бы как поток символов."""
        got = VR.strip_markup("Запусти:\n```bash\ngit push --force\n```\nи все.")
        self.assertNotIn("git", got)
        self.assertIn("Запусти", got)

    def test_inline_code_keeps_content(self):
        self.assertEqual(VR.strip_markup("правило `docs-maintenance`"), "правило docs-maintenance")

    def test_list_markers_dropped(self):
        self.assertEqual(VR.strip_markup("- первое\n- второе"), "первое\nвторое")

    def test_link_keeps_text_drops_url(self):
        got = VR.strip_markup("см. [правило](https://example.com/x)")
        self.assertEqual(got, "см. правило")


class SplitChunksTest(unittest.TestCase):
    def test_short_text_stays_one_chunk(self):
        self.assertEqual(VR.split_chunks("Готово."), ["Готово."])

    def test_nothing_is_lost(self):
        """Потерянный хвост - тихий отказ: голосовое приходит, а половины
        отчета в нем нет, и заметить это можно только дослушав."""
        text = " ".join(f"Предложение номер {i} про работу." for i in range(120))
        chunks = VR.split_chunks(text, limit=200)
        self.assertEqual(" ".join(chunks), text)

    def test_limit_respected(self):
        text = " ".join(f"Фраза {i} тут." for i in range(200))
        for chunk in VR.split_chunks(text, limit=150):
            self.assertLessEqual(len(chunk), 150)

    def test_splits_on_sentence_boundary(self):
        text = "Первое предложение. Второе предложение. Третье предложение."
        chunks = VR.split_chunks(text, limit=40)
        for chunk in chunks:
            self.assertTrue(chunk.endswith(".") or chunk.endswith("предложение"))

    def test_very_long_sentence_split_by_words(self):
        """Предложение длиннее лимита резать все равно надо - но по словам,
        а не посреди слова."""
        text = "слово " * 100
        chunks = VR.split_chunks(text.strip(), limit=50)
        self.assertTrue(all(len(c) <= 50 for c in chunks))
        self.assertEqual("".join(chunks).replace(" ", ""), text.replace(" ", ""))

    def test_empty_text_gives_no_chunks(self):
        self.assertEqual(VR.split_chunks("   "), [])


if __name__ == "__main__":
    unittest.main(verbosity=2)
