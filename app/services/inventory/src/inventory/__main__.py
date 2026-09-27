"""Entry point: `opentelemetry-instrument python -m inventory`."""

import os

import uvicorn

from inventory import logs

logs.setup()

if __name__ == "__main__":
    # log_config=None keeps our JSON handler; the access log is off because spans cover requests.
    uvicorn.run(
        "inventory.main:app",
        host="0.0.0.0",
        port=int(os.environ.get("PORT", "8080")),
        log_config=None,
        access_log=False,
        timeout_graceful_shutdown=20,
    )
