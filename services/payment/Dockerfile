# The build stage runs on the builder's own CPU. Dependencies with compiled extensions (pydantic-core,
# uvloop, httptools, watchfiles) are fetched as prebuilt wheels for the target CPU instead of being built,
# so multi-arch builds need no emulation. A dependency without a matching wheel fails the build loudly.
FROM --platform=$BUILDPLATFORM python:3.14-slim AS build
ARG TARGETARCH
WORKDIR /app
COPY pyproject.toml ./
COPY payment ./payment
RUN pip wheel --no-cache-dir --no-deps -w /wheels . \
 && case "$TARGETARCH" in amd64) arch=x86_64 ;; arm64) arch=aarch64 ;; *) echo "unsupported arch $TARGETARCH" >&2; exit 1 ;; esac \
 && pip install --no-cache-dir --target /install --only-binary=:all: \
      --implementation cp --python-version 3.14 \
      --platform "manylinux2014_$arch" --platform "manylinux_2_28_$arch" \
      /wheels/*.whl

FROM python:3.14-slim
WORKDIR /app
COPY --from=build /install /opt/payment
ENV PYTHONPATH=/opt/payment PYTHONDONTWRITEBYTECODE=1
# Numeric uid needs no passwd entry, so the runtime stage has no RUN step.
USER 10001
EXPOSE 8080
CMD ["python", "-m", "uvicorn", "payment.main:app", "--host", "0.0.0.0", "--port", "8080"]
