FROM python:3.13-slim AS build
WORKDIR /app
COPY pyproject.toml ./
COPY payment ./payment
RUN pip install --no-cache-dir --prefix=/install .

FROM python:3.13-slim
RUN useradd --uid 10001 --no-create-home app
WORKDIR /app
COPY --from=build /install /usr/local
USER 10001
EXPOSE 8080
CMD ["uvicorn", "payment.main:app", "--host", "0.0.0.0", "--port", "8080"]
