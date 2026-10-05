#!/usr/bin/env python3
"""Export schema-2 ForeverDuel history without executing SavedVariables Lua.

Usage: python tools/export-history.py ForeverDuel.lua --output history.json
The output contains only public match data. Existing output files are replaced
atomically; the source is never overwritten. Histories exceeding --batch-size
(default 200) produce history.part-001.json, history.part-002.json, and so on.
Only the Python standard library is required.
"""

import argparse
import json
import math
import os
from pathlib import Path
import re
import tempfile


MAX_SOURCE_BYTES = 8 * 1024 * 1024
MAX_DEPTH = 32
MAX_VALUES = 250_000
MAX_SAFE_INTEGER = 9_007_199_254_740_991
MAX_BATCH_SIZE = 200
IDENTIFIER = re.compile(r"[A-Za-z_][A-Za-z_0-9]*")
NUMBER = re.compile(
    r"[+-]?(?:0[xX][0-9A-Fa-f]+|(?:[0-9]+(?:\.[0-9]*)?|\.[0-9]+)(?:[eE][+-]?[0-9]+)?)"
)
LONG_OPEN = re.compile(r"\[(=*)\[")
IDENTITY_FIELDS = ("guid", "name", "fullName", "realm", "classFile", "level", "maxLevel")
MATCH_FIELDS = (
    "schemaVersion", "protocolVersion", "addonVersion", "bracket", "matchId",
    "startedAt", "endedAt", "countdownAt", "confirmedAt", "startSource", "resultSource",
    "winnerGUID", "loserGUID", "result", "ratingBefore", "ratingAfter", "ratingDelta",
    "opponentRatingBefore", "ratedConfirmed",
)
EVIDENCE_FIELDS = ("agreedBeforeStart", "localResult", "peerResult")


class ExportError(ValueError):
    """An unsupported or unsafe SavedVariables input."""


class SavedVariablesParser:
    """A bounded parser for one Lua table assignment, never a Lua interpreter."""

    def __init__(self, source):
        if len(source.encode("utf-8")) > MAX_SOURCE_BYTES:
            raise ExportError("SavedVariables exceeds the 8 MiB input limit")
        self.source = source
        self.position = 0
        self.values = 0

    def fail(self, message):
        line = self.source.count("\n", 0, self.position) + 1
        raise ExportError(f"{message} (line {line})")

    def skip(self):
        while self.position < len(self.source):
            if self.source[self.position].isspace():
                self.position += 1
                continue
            if not self.source.startswith("--", self.position):
                return
            self.position += 2
            opening = LONG_OPEN.match(self.source, self.position)
            if opening:
                closing = "]" + opening.group(1) + "]"
                end = self.source.find(closing, opening.end())
                if end < 0:
                    self.fail("Unterminated block comment")
                self.position = end + len(closing)
            else:
                end = self.source.find("\n", self.position)
                self.position = len(self.source) if end < 0 else end + 1

    def consume(self, token):
        self.skip()
        if not self.source.startswith(token, self.position):
            self.fail(f"Expected {token!r}")
        self.position += len(token)

    def identifier(self):
        self.skip()
        match = IDENTIFIER.match(self.source, self.position)
        if not match:
            self.fail("Expected a name")
        self.position = match.end()
        return match.group()

    def parse(self):
        if self.identifier() != "ForeverDuelDB":
            self.fail("Expected the single ForeverDuelDB assignment")
        self.consume("=")
        result = self.value(0)
        if not isinstance(result, dict):
            self.fail("ForeverDuelDB must be a table")
        self.skip()
        if self.source.startswith(";", self.position):
            self.position += 1
            self.skip()
        if self.position != len(self.source):
            self.fail("Trailing code or additional assignments are not supported")
        return result

    def value(self, depth):
        self.skip()
        self.values += 1
        if self.values > MAX_VALUES:
            self.fail("Too many SavedVariables values")
        if self.position >= len(self.source):
            self.fail("Expected a value")
        character = self.source[self.position]
        if character == "{":
            if depth >= MAX_DEPTH:
                self.fail("SavedVariables nesting limit exceeded")
            return self.table(depth + 1)
        if character in "\"'":
            return self.string()
        opening = LONG_OPEN.match(self.source, self.position)
        if opening:
            closing = "]" + opening.group(1) + "]"
            end = self.source.find(closing, opening.end())
            if end < 0:
                self.fail("Unterminated long string")
            result = self.source[opening.end():end].replace("\r\n", "\n").replace("\r", "\n")
            if result.startswith("\n"):
                result = result[1:]
            self.position = end + len(closing)
            return result
        number = NUMBER.match(self.source, self.position)
        if number:
            self.position = number.end()
            text = number.group()
            try:
                if "x" in text.lower():
                    result = int(text, 16)
                elif any(character in text for character in ".eE"):
                    result = float(text)
                else:
                    result = int(text)
            except ValueError:
                self.fail("Invalid numeric value")
            if isinstance(result, float) and not math.isfinite(result):
                self.fail("Non-finite numeric value")
            return result
        name = self.identifier()
        if name == "true":
            return True
        if name == "false":
            return False
        if name == "nil":
            return None
        self.fail("Only table data and literal values are supported")

    def table(self, depth):
        self.consume("{")
        result = {}
        positional_key = 1
        while True:
            self.skip()
            if self.source.startswith("}", self.position):
                self.position += 1
                return result
            if self.source.startswith("[", self.position) and not LONG_OPEN.match(self.source, self.position):
                self.position += 1
                key = self.value(depth)
                if type(key) not in (str, int, float):
                    self.fail("Table keys must be strings or numbers")
                self.consume("]")
                self.consume("=")
            else:
                start = self.position
                name = IDENTIFIER.match(self.source, self.position)
                if name:
                    self.position = name.end()
                    self.skip()
                if name and self.source.startswith("=", self.position):
                    key = name.group()
                    if key in ("true", "false", "nil"):
                        self.fail("Invalid named table key")
                    self.position += 1
                else:
                    self.position = start
                    key = positional_key
                    positional_key += 1
            if key in result:
                self.fail("Duplicate table key")
            result[key] = self.value(depth)
            self.skip()
            if self.source.startswith("}", self.position):
                continue
            if self.position < len(self.source) and self.source[self.position] in ",;":
                self.position += 1
            else:
                self.fail("Expected a comma, semicolon, or closing brace")

    def string(self):
        quote = self.source[self.position]
        self.position += 1
        chunks = []
        escapes = {"a": b"\a", "b": b"\b", "f": b"\f", "n": b"\n", "r": b"\r", "t": b"\t", "v": b"\v"}
        while self.position < len(self.source):
            start = self.position
            while self.position < len(self.source) and self.source[self.position] not in (quote, "\\", "\r", "\n"):
                self.position += 1
            chunks.append(self.source[start:self.position].encode("utf-8"))
            if self.position >= len(self.source):
                break
            character = self.source[self.position]
            self.position += 1
            if character == quote:
                try:
                    return b"".join(chunks).decode("utf-8")
                except UnicodeDecodeError:
                    self.fail("String contains invalid UTF-8 bytes")
            if character in "\r\n":
                self.fail("Unescaped newline in quoted string")
            if self.position >= len(self.source):
                break
            character = self.source[self.position]
            self.position += 1
            if character in escapes:
                chunks.append(escapes[character])
            elif character in "\\\"'":
                chunks.append(character.encode("ascii"))
            elif character in "\r\n":
                if character == "\r" and self.source.startswith("\n", self.position):
                    self.position += 1
                chunks.append(b"\n")
            elif "0" <= character <= "9":
                digits = character
                while len(digits) < 3 and self.position < len(self.source) and "0" <= self.source[self.position] <= "9":
                    digits += self.source[self.position]
                    self.position += 1
                if int(digits) > 255:
                    self.fail("Decimal string escape exceeds 255")
                chunks.append(bytes([int(digits)]))
            else:
                self.fail("Unsupported string escape")
        self.fail("Unterminated quoted string")


def require_table(value, label):
    if not isinstance(value, dict):
        raise ExportError(f"{label} must be a table")
    return value


def require_string(value, label):
    if not isinstance(value, str) or not value:
        raise ExportError(f"{label} must be a nonempty string")
    return value


def require_integer(value, label, minimum=-MAX_SAFE_INTEGER, maximum=MAX_SAFE_INTEGER):
    if type(value) not in (int, float) or not minimum <= value <= maximum or int(value) != value:
        raise ExportError(f"{label} must be an integer between {minimum} and {maximum}")
    return int(value)


def project_identity(value, label):
    value = require_table(value, label)
    result = {field: value[field] for field in IDENTITY_FIELDS if value.get(field) is not None}
    for field in ("guid", "name", "realm", "classFile"):
        require_string(result.get(field), f"{label}.{field}")
    if "fullName" in result:
        require_string(result["fullName"], f"{label}.fullName")
    for field in ("level", "maxLevel"):
        result[field] = require_integer(result.get(field), f"{label}.{field}", 1, 255)
    if result["level"] > result["maxLevel"]:
        raise ExportError(f"{label}.level exceeds maxLevel")
    return result


def public_history(database):
    """Validate schema/reporter relationships and select the upload contract."""
    database = require_table(database, "ForeverDuelDB")
    if require_integer(database.get("schemaVersion"), "schemaVersion") != 2:
        raise ExportError("Only schemaVersion 2 can be exported; legacy history is excluded")
    player = require_table(database.get("player"), "player")
    reporter = require_string(player.get("guid"), "player.guid")
    history = require_table(database.get("matches"), "matches")
    if any(type(key) not in (int, float) or key < 1 or int(key) != key for key in history):
        raise ExportError("matches must have sequential numeric indices starting at 1")
    if any(index not in history for index in range(1, len(history) + 1)):
        raise ExportError("matches must not contain gaps")
    records = []
    seen = set()
    for index in range(1, len(history) + 1):
        label = f"matches[{index}]"
        record = require_table(history[index], label)
        result = {field: record[field] for field in MATCH_FIELDS if record.get(field) is not None}
        for field in ("schemaVersion", "protocolVersion"):
            result[field] = require_integer(result.get(field), f"{label}.{field}")
        if result["schemaVersion"] != 2 or result["protocolVersion"] not in (2, 3):
            raise ExportError(f"{label} requires schemaVersion 2 and protocolVersion 2 or 3")
        match_id = require_string(result.get("matchId"), f"{label}.matchId")
        if match_id in seen:
            raise ExportError(f"{label} has a duplicate matchId")
        seen.add(match_id)
        result["player"] = project_identity(record.get("player"), f"{label}.player")
        result["opponent"] = project_identity(record.get("opponent"), f"{label}.opponent")
        own, other = result["player"], result["opponent"]
        if own["guid"] != reporter or own["guid"] == other["guid"]:
            raise ExportError(f"{label} has an invalid reporter or opponent GUID")
        bracket = "MAX_LEVEL" if own["level"] == own["maxLevel"] else "LEVELING"
        other_bracket = "MAX_LEVEL" if other["level"] == other["maxLevel"] else "LEVELING"
        if result.get("bracket") != bracket or bracket != other_bracket or own["maxLevel"] != other["maxLevel"] or abs(own["level"] - other["level"]) > 5:
            raise ExportError(f"{label} has an invalid rating bracket or level pair")
        for field in ("addonVersion", "startSource", "resultSource"):
            if field in result:
                require_string(result[field], f"{label}.{field}")
        for field in ("startedAt", "endedAt"):
            result[field] = require_integer(result.get(field), f"{label}.{field}", 0)
        for field in ("countdownAt", "confirmedAt"):
            if field in result:
                result[field] = require_integer(result[field], f"{label}.{field}", 0)
        if result["endedAt"] < result["startedAt"]:
            raise ExportError(f"{label}.endedAt precedes startedAt")
        outcome = result.get("result")
        if outcome not in ("WIN", "LOSS"):
            raise ExportError(f"{label}.result must be WIN or LOSS")
        winner, loser = (own["guid"], other["guid"]) if outcome == "WIN" else (other["guid"], own["guid"])
        if result.get("winnerGUID") != winner or result.get("loserGUID") != loser:
            raise ExportError(f"{label} has contradictory winner/loser GUIDs")
        for field in ("ratingBefore", "ratingAfter", "ratingDelta", "opponentRatingBefore"):
            result[field] = require_integer(result.get(field), f"{label}.{field}")
        if result["ratingAfter"] != result["ratingBefore"] + result["ratingDelta"]:
            raise ExportError(f"{label} has inconsistent ratingAfter/ratingDelta")
        evidence = require_table(record.get("evidence"), f"{label}.evidence")
        if result.get("ratedConfirmed") is not True or any(evidence.get(field) is not True for field in EVIDENCE_FIELDS):
            raise ExportError(f"{label} is missing mutually confirmed result evidence")
        result["evidence"] = {field: True for field in EVIDENCE_FIELDS}
        records.append(result)
    return {"schemaVersion": 2, "player": {"guid": reporter}, "matches": records}


def load_history(source):
    with Path(source).open("rb") as stream:
        data = stream.read(MAX_SOURCE_BYTES + 1)
    if len(data) > MAX_SOURCE_BYTES:
        raise ExportError("SavedVariables exceeds the 8 MiB input limit")
    try:
        text = data.decode("utf-8-sig")
    except UnicodeDecodeError as error:
        raise ExportError("SavedVariables must be UTF-8") from error
    return public_history(SavedVariablesParser(text).parse())


def export_history(source, output, batch_size=MAX_BATCH_SIZE):
    if type(batch_size) is not int or not 1 <= batch_size <= MAX_BATCH_SIZE:
        raise ExportError("batch_size must be between 1 and 200")
    source = Path(source).resolve()
    output = Path(output).resolve()
    if output == source or (output.exists() and os.path.samefile(output, source)):
        raise ExportError("Output must not overwrite the SavedVariables source")
    payload = load_history(source)
    matches = payload["matches"]
    batches = [matches[start:start + batch_size] for start in range(0, len(matches), batch_size)] or [[]]
    targets = [output] if len(batches) == 1 else [
        output.with_name(f"{output.stem}.part-{index:03d}{output.suffix or '.json'}")
        for index in range(1, len(batches) + 1)
    ]
    for target in targets:
        if target == source or (target.exists() and os.path.samefile(target, source)):
            raise ExportError("Output batch must not overwrite the SavedVariables source")
        if target.exists() and not target.is_file():
            raise ExportError(f"Output is not a file: {target}")
    output.parent.mkdir(parents=True, exist_ok=True)
    written = []
    for target, batch in zip(targets, batches):
        temporary = None
        try:
            with tempfile.NamedTemporaryFile(mode="w", encoding="utf-8", newline="\n", dir=target.parent, prefix=f".{target.stem}.", suffix=".tmp", delete=False) as stream:
                temporary = Path(stream.name)
                json.dump({**payload, "matches": batch}, stream, ensure_ascii=False, indent=2, allow_nan=False)
                stream.write("\n")
                stream.flush()
                os.fsync(stream.fileno())
            os.replace(temporary, target)
            written.append((target, len(batch)))
        finally:
            if temporary is not None and temporary.exists():
                temporary.unlink()
    return written


def batch_size_argument(value):
    try:
        result = int(value)
    except ValueError as error:
        raise argparse.ArgumentTypeError("must be an integer between 1 and 200") from error
    if not 1 <= result <= MAX_BATCH_SIZE:
        raise argparse.ArgumentTypeError("must be an integer between 1 and 200")
    return result


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("source", type=Path, help="WoW SavedVariables ForeverDuel.lua (not an addon source file)")
    parser.add_argument("--output", required=True, type=Path, help="JSON output path; existing outputs are replaced atomically")
    parser.add_argument("--batch-size", type=batch_size_argument, default=MAX_BATCH_SIZE, help="matches per output file, 1–200 (default: 200)")
    arguments = parser.parse_args(argv)
    try:
        outputs = export_history(arguments.source, arguments.output, arguments.batch_size)
    except (ExportError, OSError) as error:
        parser.exit(2, f"export-history: error: {error}\n")
    for path, count in outputs:
        print(f"Exported {count} matches: {path}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
