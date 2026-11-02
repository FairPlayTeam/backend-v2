![TypeScript](https://img.shields.io/badge/TypeScript-3178C6)
![License](https://img.shields.io/badge/License-GNU%20AGPLv3-blue.svg)

# FairPlay API v2

> [!NOTE]
> Work in progress rewrite of the FairPlay backend

## What is FairPlay?

FairPlay is an experimental ethical video platform focused on giving control back to creators and users.

More info on our project documentation: [docs.fairplayvideo.org](https://docs.fairplayvideo.org)

This repository contains the backend API, currently being rebuilt for v2.

## Tech stack

Here's what's currently powering the backend:

- **TypeScript**: the language (obviously)
- **Express.js**: HTTP API
- **PostgreSQL**: database
- **Prisma**: database access and migrations
- **Garage**: local S3-compatible object storage (we're using backblaze in production)
- **FFmpeg / ffprobe**: video processing and inspection
- **Bun**: runtime and package manager
- **Pino**: logging

## New V2 features and improvements

- OpenAPI schema generation from Zod schemas and route definitions.
- Centralized logging with Pino.
- More consistent validation and error handling.
- A cleaner project structure, with clearer boundaries between responsibilities.

## Getting it running

There are two ways to run FairPlay locally.

I'd recommend running Bun directly on your machine and using Docker only for the services the API depends on. It's a little easier to work with when you're actively changing code.

If you prefer keeping everything containerized, there's a Docker Compose setup too.

### Option 1

First, install the dependencies and start the services:

```bash
bun install
cp .env.example .env
docker compose up -d postgres redis object-storage
```

Then apply the database migrations and start the API:

```bash
bunx prisma migrate dev
bun run dev
```

The API should now be available at [http://localhost:3000](http://localhost:3000).

A couple of things to keep in mind:

- Development logs are automatically pretty-printed.
- Garage exposes its local S3 endpoint at [http://localhost:9000](http://localhost:9000).
- If Bun is running directly on your machine, make sure `ffmpeg` and `ffprobe` are installed and available in your `PATH`.

The local Compose image and production transcoder image already include both FFmpeg tools, so you don't need to worry about installing them separately when using those images.

### Option 2

If you prefer not to install the runtime locally:

```bash
docker compose up --build
```

Compose will build the local combined image, start PostgreSQL, Redis and Garage, run the Prisma migrations through the `migrate` service, and finally start the API.

Everything runs on the same Docker network.

Once it's ready, you'll find the API at [http://localhost:3000](http://localhost:3000).

For a more detailed walkthrough, check out [CONTRIBUTING.md](CONTRIBUTING.md). It also covers the environment variables and other setup details.

If you're wiring up multipart video uploads, call the `parts/sign` endpoint between completed part transfers, even if you already have a batch of URLs. Only newly verified uploaded bytes renew the reservation; signing alone doesn't. Leave at least 5 seconds for a suppressed progress check to become eligible again, plus network, storage and database time, before expiry. If `expiresAt` hasn't advanced, retry while that margin is still available. Slow connections, storage outages and existing cooldowns during a rollout need more room. The [upload reservation notes](docs/ARCHITECTURE.md#idle-upload-reservations) cover the details.

## Deployment

Deployment is a little more involved, mostly because the API and video processing are kept separate.

I didn't want FFmpeg sitting inside the API container doing work that really belongs to a dedicated worker. So the Dockerfile provides three production targets:

- `runtime`: the actual API
- `transcoder`: the isolated video processing worker
- `migrator`: runs database migrations

Build them with:

```bash
docker build --target runtime -t fairplay-backend:production-api .
docker build --target transcoder -t fairplay-backend:production-transcoder .
docker build --target migrator -t fairplay-backend-migrator:<tag> .
```

The migrator should be run once per release, before starting the new application version.

One migration needs extra care: the [upload reservation deadline migration](docs/ARCHITECTURE.md#idle-upload-reservations) requires stopping old API writers before applying it. Reopen uploads with the updated API and deploy client renewal support alongside it; old and new API writers can't share the migrated schema.

For the runtime itself:

**API instance**

Run with:

```text
RUNTIME_ROLE=api
VIDEO_TRANSCODE_MAX_CONCURRENT_JOBS=0
```

It should sit behind a reverse proxy.

**Transcoder worker**

Run a separate instance with:

```text
RUNTIME_ROLE=transcoder
```

The worker currently uses one processing slot.

A few details that are easy to miss:

- The API image doesn't include FFmpeg.
- The transcoder doesn't expose an HTTP port.
- The transcoder image has no Docker HTTP healthcheck.

The first production deployment is designed around a DL360 server, without an orchestrator. For now, we're using systemd to manage the services. The example units are in [deploy/systemd](deploy/systemd).

Resource limits and temporary filesystem requirements are documented in [ARCHITECTURE.md](docs/ARCHITECTURE.md).

### Production configuration

The production environment needs a few external services:

- Shared cloud PostgreSQL
- Redis (API only)
- S3-compatible object storage
- SMTP configuration for the API

And, of course, a few secrets:

- `RATE_LIMIT_KEY_SECRET`: a strong secret for rate-limit key generation.
- `AUTH_CODE_PEPPER`: a strong secret used when hashing email verification and password reset codes.
- `FOLLOWING_CURSOR_ENCRYPTION_KEY`: a random 64-character hexadecimal key, identical across every API replica.

One important detail about the last one: rotating `FOLLOWING_CURSOR_ENCRYPTION_KEY` invalidates followed-profile cursors that clients haven't consumed yet. So don't rotate it casually.

For a fully public Bearer-token API, set:

```text
CORS_ORIGINS=*
```

Storage is split into two buckets:

- `user-media` for profile pictures and other user media.
- `videos` for video sources and generated artifacts.

Don't forget the video bucket's own CORS rules: `CORS_ORIGINS` only configures the API. Public playback needs a separate `GET`/`HEAD` rule allowing `*` because browser redirects can send `Origin: null`; keep upload `PUT` restricted to your frontend origins and the bucket private. See the [playback storage notes](docs/ARCHITECTURE.md#public-hls-reads) for headers and browser checks.

Managed PostgreSQL, Redis and S3-compatible storage providers are supported. The initial production setup uses cloud PostgreSQL and Redis, with Backblaze B2 for object storage.

The B2 upload contract still needs production qualification. Before deploying, run `bun scripts/verify-b2-upload-contract.ts` against an isolated test bucket and complete the remaining provider checks in the [reservation notes](docs/ARCHITECTURE.md#idle-upload-reservations), including in-flight PUT/abort races and physical retention. Passing the local Garage tests doesn't cover those checks.

If you're deploying behind Cloudflare Tunnel, there's another small detail worth mentioning.

When `cloudflared` forwards requests to the backend through `127.0.0.1:3000`, `TRUST_PROXY=loopback` is the preferred setting.

For origin health checks, use:

```text
/health/ready
```

There's more about the reasoning behind this deployment model in [ARCHITECTURE.md](docs/ARCHITECTURE.md). Environment variables are also covered in [CONTRIBUTING.md](CONTRIBUTING.md).

## Note about dependencies

You might notice a couple of dependency overrides in `package.json`.

They're there for security reasons. Sometimes a transitive dependency needs a patch before the package that pulls it in updates its own dependency range. Overrides let us deal with that in the meantime.

They're not meant to stay forever though. We'll review them periodically and remove them once upstream dependencies include the fixes themselves.

The current overrides are:

- `deepmerge-ts@8.0.2`, pulled in by Prisma through `@prisma/config`
- `mysql2@3.24.5`, pulled in directly by the Prisma CLI

Other patched transitive dependencies already resolve through their parent packages' declared semver ranges, so they don't need explicit overrides:

`@grpc/grpc-js`, `brace-expansion`, `fast-uri`, `fast-copy`, `ip-address`, `nanoid`, `proxy-addr`, `qs`, `source-map-js` and `undici`.

If you're wondering how Bun handles this, the relevant documentation is [here](https://bun.sh/docs/pm/overrides).

## API documentation

You don't need to dig through the source code to explore the API.

Once the backend is running, the generated documentation is available at:

- [Open the API docs](http://localhost:3000/docs)
- [Download the OpenAPI schema](http://localhost:3000/openapi.json)

The schema is generated from the API definitions, so it stays close to the actual implementation.

## Running checks

There are quite a few checks in the project. You don't necessarily need to run them all individually though.

Here are the available scripts:

```bash
bun run typecheck
bun run build
bun run lint
bun run lint:fix
bun run format:check
bun run format
bun run test:unit
bun run test:integration
```

If you just want to make sure everything is still in a good state, run:

```bash
bun run check
```

This runs the standard verification suite in order:

1. TypeScript typechecking
2. Linting
3. Formatting
4. Prisma schema formatting
5. Prisma validation
6. Unit tests with bounded concurrency
7. Integration tests using Testcontainers
8. Dependency audit
9. Production build

The test scripts set `SHARP_CONCURRENCY=1` by default. This keeps image-processing tests reproducible. If you need a different value, you can override it by setting `SHARP_CONCURRENCY` to a positive integer.

### Integration tests

The integration tests deserve a small explanation because they do a bit more than just mock a database.

They use Vitest and Testcontainers to start actual PostgreSQL and Redis containers, along with Garage.

Prisma migrations are applied automatically, and the tests then exercise the runtime services and HTTP API against those real dependencies.

In other words, you'll need Docker running locally.

```bash
bun run test:integration
```

## Routes

The API currently has nine HTTP modules, mounted under seven distinct prefixes. Comments, video uploads and videos share `/videos`.

They're all registered explicitly in `src/routes/registry.ts`. This file is the single source of truth for mount paths, mount order and OpenAPI documentation.

The current mount prefixes are:

```text
/admin
/auth
/health
/moderation
/profiles
/videos
/
```

Keeping them in one place makes it easier to see how the API is structured without having to hunt through the codebase.

## License

FairPlay is licensed under the GNU AGPLv3.

See [LICENSE](LICENSE) for the full license text.
