# Changelog

## 0.1.4

Documentation only: README rewritten, a runnable example (`example/main.dart`), dartdoc on the `Request`,
`Response` and `PayloadTooLargeException` constructors. No API change.

## 0.1.3

First release on pub.dev. No API change.

## 0.1.2

Renamed from `dart_backend_framework` to `orbiter`; the repository moved with it. No API change: only the package
name, the library import (`package:orbiter/orbiter.dart`) and the dependency key change.

## 0.1.1

Documentation only; no code change.

- README: new sections "Writing an interceptor" (function and class forms, short-circuit, typed request context,
  cleanup hooks) and "Errors and logging" (`errorHandler` versus `onError`, why a custom `errorHandler` must answer
  `413` itself, `requestLogger(logFn:)`).
- README: the PostgreSQL package is described as the database kit it is (`rlsTransaction` and `prefixTsQuery`),
  one kit per database.

## 0.1.0

First public release, consumed by `git` reference to the tag `v0.1.0`.

- `BackendServer` over `dart:io`, with a request body limit (`maxBodySize`), an error boundary that answers a
  generic `500`, `onError` reporting and a graceful `close()` that waits for in-flight requests and their hooks.
- `Request` / `Response` with typed per-request context (`RequestContext`, no `Zone`) and LIFO cleanup hooks
  that run after the response is fully written, including streamed bodies and client disconnects.
- `Pipeline` of interceptors, folded once at startup, with short-circuit.
- Radix/trie `Router`: static routes, `:param`, `*wildcard`, `404` and `405` with `Allow`.
- Middlewares: `cors()`, `requestLogger()`, `securityHeaders()`.
- No database dependency.
