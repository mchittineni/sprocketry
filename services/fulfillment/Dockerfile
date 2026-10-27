FROM golang:1.23-alpine AS build
WORKDIR /src
COPY . .
RUN CGO_ENABLED=0 go build -trimpath -ldflags="-s -w" -o /out/fulfillment .

FROM gcr.io/distroless/static-debian12:nonroot
COPY --from=build /out/fulfillment /fulfillment
EXPOSE 8080
ENTRYPOINT ["/fulfillment"]
