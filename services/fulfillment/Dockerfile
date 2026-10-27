# The build stage runs on the builder's own CPU and cross-compiles, so multi-arch builds need no emulation.
FROM --platform=$BUILDPLATFORM golang:1.27-alpine AS build
ARG TARGETOS TARGETARCH
WORKDIR /src
COPY . .
RUN CGO_ENABLED=0 GOOS=$TARGETOS GOARCH=$TARGETARCH go build -trimpath -ldflags="-s -w" -o /out/fulfillment .

FROM gcr.io/distroless/static-debian13:nonroot
COPY --from=build /out/fulfillment /fulfillment
EXPOSE 8080
ENTRYPOINT ["/fulfillment"]
