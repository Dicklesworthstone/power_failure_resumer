#!/usr/bin/env python3
"""Unit tests for title/preview extraction from session transcripts."""

from __future__ import annotations

import json
import sys
import unittest
import uuid
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
sys.path.insert(0, str(ROOT / "lib"))

from discover import (  # noqa: E402
    _head_lines,
    extract_claude_identity,
    extract_codex_first_user,
    extract_codex_last_user,
)

WORK = ROOT / "tests" / "logs" / "state"


def tmp_jsonl(label: str, lines: list) -> Path:
    d = WORK / f"titles-{label}-{uuid.uuid4().hex}"
    d.mkdir(parents=True)
    p = d / "session.jsonl"
    p.write_text("\n".join(json.dumps(x) for x in lines) + "\n", encoding="utf-8")
    return p


def user_line(text: str) -> dict:
    return {"type": "user", "message": {"role": "user", "content": text}}


class ClaudeTitleTest(unittest.TestCase):
    def test_priority_custom_over_ai_over_summary_over_user(self):
        p = tmp_jsonl("prio", [
            user_line("first real question"),
            {"type": "summary", "summary": "the summary"},
            {"type": "ai-title", "aiTitle": "the ai title"},
            {"type": "custom-title", "customTitle": "the custom title"},
        ])
        title, preview = extract_claude_identity(p)
        self.assertEqual(title, "the custom title")
        self.assertEqual(preview, "first real question")

    def test_ai_title_used_when_no_custom(self):
        p = tmp_jsonl("ai", [
            {"type": "ai-title", "aiTitle": "Review project for bugs"},
            user_line("look for bugs please"),
        ])
        title, preview = extract_claude_identity(p)
        self.assertEqual(title, "Review project for bugs")
        self.assertEqual(preview, "look for bugs please")

    def test_title_appended_after_head_scan_is_found(self):
        p = tmp_jsonl("late-title", [
            user_line("first question"),
            *({"type": "progress", "n": i} for i in range(250)),
            {"type": "custom-title", "customTitle": "late custom title"},
        ])
        title, preview = extract_claude_identity(p)
        self.assertEqual(title, "late custom title")
        self.assertEqual(preview, "first question")

    def test_non_string_title_is_ignored(self):
        p = tmp_jsonl("bad-title", [
            {"type": "custom-title", "customTitle": {"not": "text"}},
            user_line("usable title"),
        ])
        title, preview = extract_claude_identity(p)
        self.assertEqual(title, "usable title")
        self.assertEqual(preview, "usable title")

    def test_falls_back_to_first_user_and_skips_boilerplate(self):
        p = tmp_jsonl("fallback", [
            user_line("<system-reminder>ignore me</system-reminder>"),
            user_line("Caveat: local command noise"),
            user_line("actual request here"),
        ])
        title, preview = extract_claude_identity(p)
        self.assertEqual(title, "actual request here")
        self.assertEqual(preview, "actual request here")

    def test_preview_prefers_last_real_user_message(self):
        p = tmp_jsonl("last", [
            user_line("first question remains the title fallback"),
            user_line("last question shows where work stopped"),
            user_line("<system-reminder>trailing noise</system-reminder>"),
        ])
        title, preview = extract_claude_identity(p)
        self.assertEqual(title, "first question remains the title fallback")
        self.assertEqual(preview, "last question shows where work stopped")

    def test_preview_falls_back_to_first_message_outside_tail(self):
        p = tmp_jsonl("tail-fallback", [
            user_line("first question outside the bounded tail"),
            *({"type": "progress", "padding": "x" * 1024} for _ in range(300)),
        ])
        title, preview = extract_claude_identity(p)
        self.assertEqual(title, "first question outside the bounded tail")
        self.assertEqual(preview, "first question outside the bounded tail")

    def test_content_block_list_and_truncation(self):
        long_text = "x" * 500
        p = tmp_jsonl("blocks", [
            {"type": "user", "message": {"role": "user",
             "content": [{"type": "text", "text": long_text}]}},
        ])
        title, preview = extract_claude_identity(p)
        self.assertLessEqual(len(title), 80)
        self.assertLessEqual(len(preview), 160)
        self.assertTrue(preview.endswith("…"))

    def test_unreadable_or_garbage_file(self):
        p = tmp_jsonl("garbage", [])
        p.write_text("not json\n{{{\n", encoding="utf-8")
        self.assertEqual(extract_claude_identity(p), ("", ""))


class CodexPreviewTest(unittest.TestCase):
    def test_head_scan_is_bounded_when_first_record_is_huge(self):
        p = tmp_jsonl("huge-head", [])
        p.write_bytes(b"x" * (300 * 1024))
        lines = _head_lines(p, 200)
        self.assertEqual(len(lines), 1)
        self.assertEqual(len(lines[0]), 256 * 1024)

    def test_skips_agents_md_and_finds_real_message(self):
        p = tmp_jsonl("codex", [
            {"type": "session_meta", "payload": {"id": "x"}},
            {"type": "response_item", "payload": {
                "type": "message", "role": "user",
                "content": [{"type": "input_text",
                             "text": "# AGENTS.md instructions for /x\n<INSTRUCTIONS>"}]}},
            {"type": "response_item", "payload": {
                "type": "message", "role": "user",
                "content": [{"type": "input_text", "text": "fix the flaky test"}]}},
        ])
        self.assertEqual(extract_codex_first_user(p), "fix the flaky test")

    def test_event_msg_user_message(self):
        p = tmp_jsonl("evt", [
            {"type": "event_msg", "payload": {"type": "user_message",
                                              "message": "resume the run"}},
        ])
        self.assertEqual(extract_codex_first_user(p), "resume the run")

    def test_last_user_message_is_preferred_over_first(self):
        p = tmp_jsonl("last", [
            {"type": "response_item", "payload": {
                "type": "message", "role": "user",
                "content": "first request"}},
            {"type": "event_msg", "payload": {
                "type": "user_message", "message": "last request"}},
            {"type": "event_msg", "payload": {
                "type": "user_message",
                "message": "<system-reminder>trailing noise</system-reminder>"}},
        ])
        self.assertEqual(extract_codex_last_user(p), "last request")

    def test_last_user_message_falls_back_to_first_outside_tail(self):
        p = tmp_jsonl("tail-fallback", [
            {"type": "response_item", "payload": {
                "type": "message", "role": "user",
                "content": "first request outside the bounded tail"}},
            *({"type": "progress", "padding": "x" * 1024} for _ in range(300)),
        ])
        self.assertEqual(
            extract_codex_last_user(p),
            "first request outside the bounded tail",
        )


if __name__ == "__main__":
    unittest.main(verbosity=2)
