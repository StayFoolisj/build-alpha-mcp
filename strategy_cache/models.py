"""Pydantic model that validates form-reader output before any DB write.

Tag-feeding fields are required and normalised with the same helpers the hash
uses, so model and tag can never disagree. Unknown form-reader fields are kept
(``extra="allow"``) so new captures do not break ingest.
"""
from __future__ import annotations

import re

from pydantic import BaseModel, ConfigDict, ValidationError, field_validator

from .normalize import normalize_date, normalize_number, normalize_symbol, normalize_text

_ISO_DATE = re.compile(r"^\d{4}-\d{2}-\d{2}$")

__all__ = ["Settings", "ValidationError"]


def _normalize_kv(text: str) -> str:
    """Normalise the numeric parts of a 'key=value;key=value' settings string."""
    out = []
    for segment in text.split(";"):
        if "=" in segment:
            key, value = segment.split("=", 1)
            normalized = normalize_number(value)
            out.append(f"{key.strip()}={normalized if normalized != '' else value.strip()}")
        else:
            out.append(segment.strip())
    return ";".join(out)


class Settings(BaseModel):
    model_config = ConfigDict(extra="allow", str_strip_whitespace=True)

    # tag-feeding fields (strict)
    symbol: str
    strategy_type: str
    start_date: str
    stop_date: str
    costs: str
    sizing: str
    fitness: str
    entry_rules: str
    exit_params: str
    is_oos: str = ""

    @field_validator("symbol")
    @classmethod
    def _symbol(cls, value: str) -> str:
        normalized = normalize_symbol(value)
        if "|" not in normalized:
            raise ValueError(f"symbol is not parseable as SYMBOL|timeframe: {value!r}")
        return normalized

    @field_validator("strategy_type")
    @classmethod
    def _strategy_type(cls, value: str) -> str:
        normalized = normalize_text(value)
        if not normalized:
            raise ValueError("strategy_type is required")
        return normalized

    @field_validator("start_date", "stop_date")
    @classmethod
    def _date(cls, value: str, info) -> str:
        normalized = normalize_date(value)
        if not _ISO_DATE.match(normalized):
            raise ValueError(f"{info.field_name} is not parseable: {value!r}")
        return normalized

    @field_validator("costs", "sizing", "is_oos")
    @classmethod
    def _numeric_kv(cls, value: str) -> str:
        return _normalize_kv(value or "")

    @field_validator("fitness", "entry_rules", "exit_params")
    @classmethod
    def _required_text(cls, value: str, info) -> str:
        normalized = normalize_text(value)
        if not normalized:
            raise ValueError(f"{info.field_name} is required")
        return normalized

    @classmethod
    def from_json(cls, payload: str | bytes | dict) -> "Settings":
        """Typed access to a stored ``settings_json`` (no validation on DB read)."""
        if isinstance(payload, (str, bytes)):
            return cls.model_validate_json(payload)
        return cls.model_validate(payload)
