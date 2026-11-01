FROM golang:1.21-alpine AS builder
WORKDIR /app
COPY go.mod go.sum ./
RUN go mod download
COPY *.go ./
RUN CGO_ENABLED=0 go build -o raft-limiter .

FROM alpine:3.19
RUN apk add --no-cache ca-certificates curl
WORKDIR /app
COPY --from=builder /app/raft-limiter .
ENTRYPOINT ["./raft-limiter"]