# Lagezentrum-API: Gerätenamen aus dem Dashboard speichern (config/hosts.csv)
FROM golang:1.27-alpine AS build
WORKDIR /src
COPY go.mod *.go ./
RUN CGO_ENABLED=0 go build -trimpath -ldflags="-s -w" -o /lz-api .

FROM scratch
COPY --from=build /lz-api /lz-api
ENTRYPOINT ["/lz-api"]
