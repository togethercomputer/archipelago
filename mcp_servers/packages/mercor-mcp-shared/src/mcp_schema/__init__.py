"""Schema flattening utilities for MCP servers."""

from .schema import (
    FlatBaseModel,
    GeminiBaseModel,
    GeminiSchemaGenerator,
    OutputBaseModel,
    flatten_schema,
    get_gemini_schema,
)

__all__ = [
    "FlatBaseModel",
    "GeminiBaseModel",
    "GeminiSchemaGenerator",
    "OutputBaseModel",
    "flatten_schema",
    "get_gemini_schema",
]
