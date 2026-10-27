# The SDK runs on the builder's own CPU and publishes for the target one (-a accepts amd64/arm64),
# so multi-arch builds need no emulation.
FROM --platform=$BUILDPLATFORM mcr.microsoft.com/dotnet/sdk:10.0 AS build
ARG TARGETARCH
WORKDIR /src
COPY Cart.csproj ./
RUN dotnet restore -a $TARGETARCH
COPY . .
RUN dotnet publish -c Release -a $TARGETARCH -o /out --no-restore

FROM mcr.microsoft.com/dotnet/aspnet:10.0-noble-chiseled
WORKDIR /app
COPY --from=build /out .
EXPOSE 8080
ENTRYPOINT ["dotnet", "Cart.dll"]
