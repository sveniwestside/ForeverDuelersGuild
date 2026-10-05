"""Standard-library tests for the safe SavedVariables-to-JSON bridge."""

import contextlib
import importlib.util
import io
import json
from pathlib import Path
import tempfile
import unittest


ROOT = Path(__file__).resolve().parents[1]
SPEC = importlib.util.spec_from_file_location("export_history", ROOT / "tools" / "export-history.py")
EXPORTER = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(EXPORTER)


def identity(guid, name, class_file):
    return {
        "guid": guid, "name": name, "fullName": f"{name}-Everlook", "realm": "Everlook",
        "classFile": class_file, "level": 60, "maxLevel": 60,
        "specId": 71, "specName": "Private spec metadata",
    }


def record(index=1, mirrored=False):
    own = identity("Player-1-AAA", "Ärger", "WARRIOR")
    opponent = identity("Player-1-BBB", "Rival", "MAGE")
    if mirrored:
        own, opponent = opponent, own
    return {
        "schemaVersion": 2, "protocolVersion": 2, "addonVersion": "0.4.5",
        "bracket": "MAX_LEVEL", "matchId": f"match-{index}", "player": own, "opponent": opponent,
        "startedAt": 1720000005, "endedAt": 1720000030, "countdownAt": 1720000002,
        "confirmedAt": 1720000001, "startSource": "localized-countdown-plus-timer",
        "resultSource": "localized-result", "winnerGUID": "Player-1-AAA", "loserGUID": "Player-1-BBB",
        "result": "LOSS" if mirrored else "WIN", "ratingBefore": 1500,
        "ratingAfter": 1484 if mirrored else 1516, "ratingDelta": -16 if mirrored else 16,
        "opponentRatingBefore": 1500, "ratedConfirmed": True,
        "evidence": {"agreedBeforeStart": True, "localResult": True, "peerResult": True, "privateNote": "omit"},
        "nonce": "never export", "extraPrivateField": {"nested": "never export"},
    }


def lua_string(value):
    return '"' + value.replace("\\", "\\\\").replace('"', '\\"').replace("\n", "\\n").replace("\r", "\\r").replace("\t", "\\t") + '"'


def lua_value(value):
    if value is None:
        return "nil"
    if value is True:
        return "true"
    if value is False:
        return "false"
    if isinstance(value, str):
        return lua_string(value)
    if isinstance(value, (int, float)):
        return str(value)
    if isinstance(value, list):
        return "{\n" + "\n".join(f"[{index}] = {lua_value(child)}, -- [{index}]" for index, child in enumerate(value, 1)) + "\n}"
    if isinstance(value, dict):
        return "{\n" + "\n".join(f"[{lua_value(key)}] = {lua_value(child)}," for key, child in value.items()) + "\n}"
    raise TypeError(value)


def saved_variables(matches=None, mirrored=False):
    matches = [record(mirrored=mirrored)] if matches is None else matches
    database = {
        "schemaVersion": 2,
        "player": {"guid": "Player-1-BBB" if mirrored else "Player-1-AAA", "ratings": {"MAX_LEVEL": {"rating": 1516, "wins": 1, "losses": 0}}},
        "matches": matches, "settings": {"debug": False}, "nonceCounter": 100,
        "finalized": {"match-1": True}, "legacy": {"schemaVersion": 1, "matches": []},
    }
    return "-- WoW SavedVariables\n--[=[ comments do not execute: os.execute('bad') ]=]\nForeverDuelDB = " + lua_value(database) + "\n"


class ParserTests(unittest.TestCase):
    def parse(self, table):
        return EXPORTER.SavedVariablesParser("ForeverDuelDB = " + table).parse()

    def test_named_bracket_and_positional_entries(self):
        self.assertEqual(self.parse('{ named = true; ["bracket"] = false, 7, [2] = 8, [3.5] = -2.5e1, nothing = nil }'), {
            "named": True, "bracket": False, 1: 7, 2: 8, 3.5: -25.0, "nothing": None,
        })

    def test_lua_decimal_utf8_and_quoted_escapes(self):
        parsed = self.parse(r'''{ value = "\195\132rger\032\"quoted\"\\path\n\t", single = 'it\'s fine', nul = "\000" }''')
        self.assertEqual(parsed["value"], 'Ärger "quoted"\\path\n\t')
        self.assertEqual(parsed["single"], "it's fine")
        self.assertEqual(parsed["nul"], "\0")

    def test_escaped_real_newline_and_long_strings(self):
        parsed = self.parse('{ value = "first\\\r\nsecond", long = [=[\r\nline\r\nend]=] }')
        self.assertEqual(parsed, {"value": "first\nsecond", "long": "line\nend"})

    def test_comments_and_one_optional_semicolon(self):
        source = "-- header\nForeverDuelDB -- name\n= { --[[comment }]]\n a --[==[ comment ]=] ]==]\n= 0x10 } ; -- tail\n"
        self.assertEqual(EXPORTER.SavedVariablesParser(source).parse(), {"a": 16})

    def test_executable_and_additional_assignments_rejected(self):
        sources = [
            'ForeverDuelDB = {}; os.execute("touch danger")',
            'ForeverDuelDB = {}; ForeverDuelDB = {}',
            'OtherDB = {}',
            'ForeverDuelDB = setmetatable({}, {})',
            'ForeverDuelDB = { x = (function() return 1 end)() }',
            'ForeverDuelDB = { x = require("module") }',
        ]
        for source in sources:
            with self.subTest(source=source), self.assertRaises(EXPORTER.ExportError):
                EXPORTER.SavedVariablesParser(source).parse()

    def test_duplicate_keys_even_nil_or_implicit_rejected(self):
        for table in ('{ a = 1, ["a"] = 2 }', '{ [1] = 1, 2 }', '{ a = nil, a = 2 }', '{ [1] = 1, [1.0] = 2 }'):
            with self.subTest(table=table), self.assertRaises(EXPORTER.ExportError):
                self.parse(table)

    def test_invalid_strings_comments_and_numbers_rejected(self):
        for table in ('{x="\\256"}', '{x="\\255"}', '{x="\\q"}', '{x="raw\nnewline"}', '{x="unfinished}', '{x=1e99999}', '{ --[=[ unfinished }', '{ [true] = 1 }'):
            with self.subTest(table=table), self.assertRaises(EXPORTER.ExportError):
                self.parse(table)

    def test_depth_and_size_limits(self):
        with self.assertRaisesRegex(EXPORTER.ExportError, "nesting"):
            self.parse("{" * (EXPORTER.MAX_DEPTH + 1) + "}" * (EXPORTER.MAX_DEPTH + 1))
        with self.assertRaisesRegex(EXPORTER.ExportError, "8 MiB"):
            EXPORTER.SavedVariablesParser(" " * (EXPORTER.MAX_SOURCE_BYTES + 1))

    def test_value_count_limit(self):
        original = EXPORTER.MAX_VALUES
        try:
            EXPORTER.MAX_VALUES = 4
            with self.assertRaisesRegex(EXPORTER.ExportError, "Too many"):
                self.parse("{1,2,3,4}")
        finally:
            EXPORTER.MAX_VALUES = original


class ExportTests(unittest.TestCase):
    def setUp(self):
        self.directory = tempfile.TemporaryDirectory()
        self.addCleanup(self.directory.cleanup)
        self.root = Path(self.directory.name)
        self.source = self.root / "ForeverDuel.lua"
        self.output = self.root / "history.json"

    def write(self, source=None):
        text = saved_variables() if source is None else source
        self.source.write_text(text, encoding="utf-8")
        return text

    def test_real_savedvariables_projection_and_source_preservation(self):
        original = self.write()
        outputs = EXPORTER.export_history(self.source, self.output)
        self.assertEqual(outputs, [(self.output, 1)])
        payload = json.loads(self.output.read_text(encoding="utf-8"))
        self.assertEqual(set(payload), {"schemaVersion", "player", "matches"})
        self.assertEqual(payload["player"], {"guid": "Player-1-AAA"})
        expected = record()
        for field in ("nonce", "extraPrivateField"):
            del expected[field]
        for field in ("player", "opponent"):
            for private_field in ("specId", "specName"):
                del expected[field][private_field]
        del expected["evidence"]["privateNote"]
        self.assertEqual(payload["matches"], [expected])
        self.assertIn("Ärger", self.output.read_text(encoding="utf-8"))
        self.assertEqual(self.source.read_text(encoding="utf-8"), original)

    def test_mirrored_report_preserves_identical_match_and_winner(self):
        self.write(saved_variables(mirrored=True))
        payload = EXPORTER.load_history(self.source)
        self.assertEqual(payload["player"]["guid"], "Player-1-BBB")
        match = payload["matches"][0]
        self.assertEqual((match["matchId"], match["result"], match["winnerGUID"], match["ratingDelta"]), ("match-1", "LOSS", "Player-1-AAA", -16))

    def test_empty_history_is_a_json_list(self):
        self.write(saved_variables(matches=[]))
        EXPORTER.export_history(self.source, self.output)
        self.assertEqual(json.loads(self.output.read_text())["matches"], [])

    def test_utf8_bom_and_decimal_identity_escapes(self):
        self.write("\ufeff" + saved_variables().replace("Ärger", r"\195\132rger"))
        self.assertEqual(EXPORTER.load_history(self.source)["matches"][0]["player"]["name"], "Ärger")

    def test_rejects_unsupported_schema_and_reporter_mismatch(self):
        cases = []
        for field, value in (("schemaVersion", 1), ("protocolVersion", 1), ("ratedConfirmed", False), ("ratingAfter", 9999), ("winnerGUID", "Player-1-BBB"), ("bracket", "LEVELING"), ("endedAt", 1), ("ratingBefore", True)):
            match = record()
            match[field] = value
            cases.append(saved_variables([match]))
        mismatch = record()
        mismatch["player"]["guid"] = "Player-1-CCC"
        cases.append(saved_variables([mismatch]))
        evidence = record()
        evidence["evidence"]["peerResult"] = False
        cases.append(saved_variables([evidence]))
        cases.append(saved_variables().replace('["schemaVersion"] = 2,', '["schemaVersion"] = 1,', 1))
        for text in cases:
            with self.subTest(text=text), self.assertRaises(EXPORTER.ExportError):
                self.write(text)
                EXPORTER.load_history(self.source)

    def test_accepts_protocol_three_records_and_rejects_unknown_protocols(self):
        current = record()
        current["protocolVersion"] = 3
        current["rules"] = {"version": 1, "k": 32}
        self.write(saved_variables([current]))
        exported = EXPORTER.load_history(self.source)["matches"][0]
        self.assertEqual(exported["protocolVersion"], 3)
        self.assertNotIn("rules", exported, "only allowlisted fields are exported")
        future = record()
        future["protocolVersion"] = 4
        with self.assertRaises(EXPORTER.ExportError):
            self.write(saved_variables([future]))
            EXPORTER.load_history(self.source)

    def test_rejects_nonsequential_and_duplicate_history(self):
        for matches in ({2: record()}, {"1": record()}, [record(), record()]):
            with self.subTest(matches=matches), self.assertRaises(EXPORTER.ExportError):
                self.write(saved_variables(matches))
                EXPORTER.load_history(self.source)

    def test_accepts_positional_matches(self):
        self.write(saved_variables().replace("[1] = {", "{"))
        self.assertEqual(len(EXPORTER.load_history(self.source)["matches"]), 1)

    def test_large_history_is_split_into_upload_batches(self):
        self.write(saved_variables([record(index) for index in range(1, 202)]))
        outputs = EXPORTER.export_history(self.source, self.output)
        self.assertEqual(outputs, [(self.root / "history.part-001.json", 200), (self.root / "history.part-002.json", 1)])
        self.assertFalse(self.output.exists())
        self.assertEqual(json.loads(outputs[1][0].read_text())["matches"][0]["matchId"], "match-201")

    def test_custom_batch_limit_and_normalized_integer_versions(self):
        first = record(1)
        first["schemaVersion"] = 2.0
        first["protocolVersion"] = 2.0
        self.write(saved_variables([first, record(2)]))
        outputs = EXPORTER.export_history(self.source, self.output, 1)
        self.assertEqual([count for path, count in outputs], [1, 1])
        payload = json.loads(outputs[0][0].read_text())
        self.assertIs(type(payload["matches"][0]["schemaVersion"]), int)
        for invalid in (0, 201, True):
            with self.subTest(invalid=invalid), self.assertRaises(EXPORTER.ExportError):
                EXPORTER.export_history(self.source, self.output, invalid)

    def test_never_overwrites_source_or_colliding_batch(self):
        original = self.write()
        with self.assertRaisesRegex(EXPORTER.ExportError, "overwrite"):
            EXPORTER.export_history(self.source, self.source)
        self.assertEqual(self.source.read_text(encoding="utf-8"), original)
        self.source = self.root / "history.part-001.json"
        original = self.write(saved_variables([record(1), record(2)]))
        with self.assertRaisesRegex(EXPORTER.ExportError, "overwrite"):
            EXPORTER.export_history(self.source, self.output, 1)
        self.assertEqual(self.source.read_text(encoding="utf-8"), original)
        self.assertFalse((self.root / "history.part-002.json").exists())

    def test_replaces_existing_output_atomically_without_temp_remains(self):
        self.write()
        self.output.write_text("old")
        EXPORTER.export_history(self.source, self.output)
        self.assertEqual(len(json.loads(self.output.read_text())["matches"]), 1)
        self.assertEqual(list(self.root.glob("*.tmp")), [])

    def test_invalid_input_does_not_replace_existing_output(self):
        self.write(saved_variables() + 'os.execute("not data")')
        self.output.write_text("keep this")
        with self.assertRaises(EXPORTER.ExportError):
            EXPORTER.export_history(self.source, self.output)
        self.assertEqual(self.output.read_text(), "keep this")

    def test_file_size_and_invalid_encoding_rejected(self):
        self.source.write_bytes(b" " * (EXPORTER.MAX_SOURCE_BYTES + 1))
        with self.assertRaisesRegex(EXPORTER.ExportError, "8 MiB"):
            EXPORTER.load_history(self.source)
        self.source.write_bytes(b"\xff")
        with self.assertRaisesRegex(EXPORTER.ExportError, "UTF-8"):
            EXPORTER.load_history(self.source)

    def test_cli_output_and_invalid_batch_argument(self):
        self.write()
        captured = io.StringIO()
        with contextlib.redirect_stdout(captured):
            self.assertEqual(EXPORTER.main([str(self.source), "--output", str(self.output)]), 0)
        self.assertIn("Exported 1 matches", captured.getvalue())
        with contextlib.redirect_stderr(io.StringIO()), self.assertRaises(SystemExit) as error:
            EXPORTER.main([str(self.source), "--output", str(self.output), "--batch-size", "201"])
        self.assertEqual(error.exception.code, 2)


if __name__ == "__main__":
    unittest.main()
