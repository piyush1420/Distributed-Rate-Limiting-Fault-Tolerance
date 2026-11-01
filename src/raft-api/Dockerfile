FROM golang:1.25-alpine AS builder
WORKDIR /app
COPY go.mod go.sum* ./
RUN go mod download || true
COPY *.go ./
RUN go mod tidy
RUN CGO_ENABLED=0 go build -o raft-api .

FROM alpine:3.19
RUN apk add --no-cache ca-certificates curl
WORKDIR /app
COPY --from=builder /app/raft-api .
ENTRYPOINT ["./raft-api"]






