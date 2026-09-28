"""Unit tests for the JSON log formatter: the trace-to-logs links depend on every line carrying the active
span's trace_id/span_id (Loki structured metadata, "Logs for this span") and a lowercase level the agent
maps to severity.

    cd app/services/inventory && uv run python -m unittest discover -s tests -v
"""

import json
import logging
import unittest

from opentelemetry.sdk.trace import TracerProvider

from inventory.logs import JsonFormatter


def render(msg: str, level: int = logging.INFO, **extra) -> dict:
    record = logging.LogRecord("inventory", level, __file__, 1, msg, None, None)
    record.__dict__.update(extra)
    return json.loads(JsonFormatter().format(record))


class JsonFormatterTest(unittest.TestCase):
    def test_line_carries_the_active_span_ids(self):
        tracer = TracerProvider().get_tracer("test")
        with tracer.start_as_current_span("POST /v1/reservations") as span:
            line = render("stock reserved")
            ctx = span.get_span_context()
        self.assertEqual(line["trace_id"], format(ctx.trace_id, "032x"))
        self.assertEqual(line["span_id"], format(ctx.span_id, "016x"))

    def test_no_ids_outside_a_span(self):
        line = render("inventory started")
        self.assertNotIn("trace_id", line)
        self.assertNotIn("span_id", line)

    def test_level_and_extra_fields(self):
        logging.addLevelName(logging.WARNING, "WARN")  # as logs.setup() does
        line = render("db pool exhausted", logging.WARNING, order_id="o-1", db_pool_max=2)
        self.assertEqual(line["level"], "warn")  # same names as Go's slog, mapped by the agent
        self.assertEqual(line["msg"], "db pool exhausted")
        self.assertEqual((line["order_id"], line["db_pool_max"]), ("o-1", 2))
        self.assertNotIn("color_message", line)


if __name__ == "__main__":
    unittest.main()
