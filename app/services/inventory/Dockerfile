# ghcr.io, not Docker Hub: the uv image ships a final CPython 3.14 and avoids Docker Hub's
# anonymous pull limit from the cloud VM (DEVIATIONS D-05).
FROM ghcr.io/astral-sh/uv:python3.14-bookworm-slim
ENV UV_COMPILE_BYTECODE=1 UV_LINK_MODE=copy UV_PYTHON_DOWNLOADS=never PYTHONUNBUFFERED=1
WORKDIR /app
# Dependencies first so code edits do not re-download them. The optional "ca" secret is
# the cloud session's TLS-inspecting proxy CA (or a customer's): used at build time only,
# never copied into a layer. Without it (a laptop) the mount is simply absent.
COPY pyproject.toml uv.lock ./
RUN --mount=type=secret,id=ca,required=false \
    if [ -s /run/secrets/ca ]; then export SSL_CERT_FILE=/run/secrets/ca; fi; \
    uv sync --frozen --no-dev --no-install-project
COPY src ./src
RUN --mount=type=secret,id=ca,required=false \
    if [ -s /run/secrets/ca ]; then export SSL_CERT_FILE=/run/secrets/ca; fi; \
    uv sync --frozen --no-dev
ENV PATH=/app/.venv/bin:$PATH
USER 10001:10001
EXPOSE 8080
# The wrapper instruments FastAPI and psycopg from the OTEL_* environment before import.
CMD ["opentelemetry-instrument", "python", "-m", "inventory"]
