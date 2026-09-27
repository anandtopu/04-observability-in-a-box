"""JSON logs on stdout with trace_id and span_id (ADR-P04-2: the node agent collects stdout).

The OTel Python logs SDK is still "Development", so logs do not go over OTLP from here.
The P04 agent parses these lines and lifts trace_id/span_id into Loki structured metadata.
"""

import json
import logging
import sys
from datetime import UTC, datetime

from opentelemetry import trace

# Standard LogRecord attributes, plus uvicorn's ANSI-coloured duplicate of msg.
_RESERVED = set(vars(logging.makeLogRecord({}))) | {"message", "asctime", "taskName", "color_message"}


class JsonFormatter(logging.Formatter):
    def format(self, record: logging.LogRecord) -> str:
        line = {
            "time": datetime.fromtimestamp(record.created, UTC).isoformat(timespec="milliseconds"),
            "level": record.levelname.lower(),  # same level names as Go's slog: info, warn, error
            "msg": record.getMessage(),
            "logger": record.name,
        }
        ctx = trace.get_current_span().get_span_context()
        if ctx.is_valid:
            line["trace_id"] = format(ctx.trace_id, "032x")
            line["span_id"] = format(ctx.span_id, "016x")
        # Anything passed as logging's extra={...} becomes a top-level field.
        line.update({k: v for k, v in vars(record).items() if k not in _RESERVED})
        if record.exc_info:
            line["exc"] = self.formatException(record.exc_info)
        return json.dumps(line, default=str)


def setup() -> None:
    logging.addLevelName(logging.WARNING, "WARN")
    handler = logging.StreamHandler(sys.stdout)
    handler.setFormatter(JsonFormatter())
    root = logging.getLogger()
    root.handlers[:] = [handler]
    root.setLevel(logging.INFO)
    # Uvicorn's own loggers propagate to root; its access log is off (spans cover requests).
    for name in ("uvicorn", "uvicorn.error"):
        logging.getLogger(name).handlers[:] = []
        logging.getLogger(name).propagate = True
