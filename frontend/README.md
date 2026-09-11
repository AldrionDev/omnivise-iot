# OmniVise IoT -- Frontend

React 19 + TypeScript dashboard, built with Vite and served by Nginx. Issue #74
laid the foundation (routing, a dark-first design-token layer, a handful of
headless UI primitives, and a resilient typed WebSocket client); #75 added the
Devices/Device-detail views; #76 added the Overview landing page and the
Alerts view.

## Stack

- React 19, TypeScript (strict), Vite 7
- `react-router` for client-side routing
- Tailwind CSS v4 (CSS-first config, tokens wired into `@theme`)
- Vitest + Testing Library
- `recharts` for `TimeSeriesChart` (#75) and the compact `Sparkline` (#76)

## Local development

```
npm ci
npm run dev      # Vite dev server
npm run lint
npm test
npm run build
```

## Routing

`react-router` in plain declarative mode (`BrowserRouter`/`Routes`/`Route`, no
loaders/actions). All routes render inside `AppShell` via `<Outlet/>`:

| Route | Renders |
| --- | --- |
| `/` | Overview: status roll-up, headline metrics, active alerts, device grid |
| `/devices` | Device registry, filterable by kind/location/status |
| `/devices/:deviceId` | Device detail: channel history, alert rules, recent alerts |
| `/alerts` | Alert history, filterable by state/severity/device |
| anything else | Not-found placeholder |

Nginx already serves the SPA with `try_files ... /index.html` (see `nginx.conf`),
so client-side routes need no server change.

## Device status (Overview / Devices)

`device_status` is **not** a backend concept -- there is no
`GET /api/devices/:id/status` endpoint, and #76 deliberately did not add one.
It is computed client-side, once, in `src/lib/deviceStatus.ts`
(`deriveDeviceStatus`): a device is `critical` if it has an active critical
alert, `warning`/`degraded` if it has an active warning alert, else `ok`. The
inputs are exactly `GET /api/devices` (the registry) and
`GET /api/alerts/active` (state=firing alerts) -- both already-public REST
contracts.

The Overview roll-up tiles use the issue-specified wording `ok` / `degraded` /
`critical` (see `src/lib/rollup.ts`); the Devices/Device-detail pages (#75)
use `ok` / `warning` / `critical`. Both wordings are presentation labels over
the same `deriveDeviceStatus` call -- the derivation itself is not duplicated.

## Theming

Dark is the unconditional default. `ThemeProvider` (`src/theme/ThemeProvider.tsx`)
reads a persisted choice from `localStorage` (`omnivise-theme`); anything other
than exactly `"light"` falls back to dark. Toggling writes
`document.documentElement.dataset.theme` and persists the choice. The OS
`prefers-color-scheme` setting is intentionally not consulted for the initial
theme -- only an explicit stored/toggled choice can turn the page light.

Design tokens are raw CSS custom properties in `src/styles/tokens.css`
(`--ov-color-*`, `--ov-space-*`, `--ov-radius-*`, `--ov-font-*`, `--ov-text-*`),
mapped into Tailwind's `@theme` in `src/index.css` so components use ordinary
utilities (`bg-surface`, `text-status-critical`, `rounded-md`, ...) instead of
hard-coded colors.

## Live data (`useLiveStream`)

`useLiveStream` (`src/hooks/useLiveStream.ts`) owns the app's single WebSocket
connection to the backend's `/ws/sensors` endpoint. It is called exactly once,
inside `AppShell`, and its state is shared to the rest of the tree through
`LiveStreamContext` -- no other component should call `useLiveStream` directly,
or a second, redundant socket opens.

Behavior:

- Parses each frame as a typed `{ kind: "reading" | "alert", payload }`
  envelope via a small dependency-free runtime type guard
  (`src/lib/parseLiveEnvelope.ts`); malformed JSON, a malformed known-kind
  payload, or an unrecognised `kind` are all ignored safely, with no state
  change and no reconnect.
- Reconnects on an unexpected close with deterministic exponential backoff:
  1s, 2s, 4s, 8s, capped at 10s. The delay resets to 1s after a successful
  reconnect. No jitter.
- On any unexpected disconnect, `latestReadings` is cleared and
  `connectionState` moves to `"reconnecting"`. Alert frames are delivered
  directly through a stable subscription owned by this single socket; they are
  never transported through a bounded React array.
- Cleans up on unmount: cancels any pending reconnect timer and closes the
  socket without scheduling a further reconnect.

The connection state (`connecting` / `connected` / `reconnecting` /
`disconnected`) is shown in `AppShell`'s top bar.

### Authoritative alert state (`useAlertsSnapshot`)

Every alert-consuming view is backed by `useAlertsSnapshot`, which combines an
authoritative REST snapshot with direct WebSocket transitions. Each persisted
firing/resolved transition has a global `sequence`; each alert REST response
has an `X-Alert-Watermark` read from the same MongoDB snapshot as its array
body. The hook installs the snapshot and replays only journal entries newer
than that watermark. Merge is monotonic per `alert.id`, while resolved records
remain hidden tombstones for active views.

The pending journal belongs to the alert query scope rather than an individual
request. Reconnects start an abortable, generation-guarded REST resync without
clearing that journal, so overlapping, stale, lower-watermark, and failed
requests cannot consume newer synchronization state. Loaded state continues to
receive pure functional updates during a resync; a successful REST result is
authoritative and a failed resync preserves the live-patched state.

## Runtime reverse proxy (backend upstream)

The frontend image serves the SPA and reverse-proxies `/api/*` and `/ws/*` to
the backend over Nginx.

The `BACKEND_UPSTREAM` env var holds the backend `host:port` authority. It is
substituted into the Nginx config at container start by the official Nginx
entrypoint's `envsubst`. Default: `backend:8080`, which Docker Compose uses
as-is.

In Kubernetes the frontend Deployment sets
`BACKEND_UPSTREAM=backend.<namespace>.svc.cluster.local:8080`. The
fully-qualified name is required because Nginx's runtime `resolver` (in effect
because `proxy_pass` references a variable, which also preserves the
`valid=10s` re-resolution) does not apply `/etc/resolv.conf` `search`/`ndots`,
so a short Service name would return NXDOMAIN in-cluster.

No cluster DNS server / CoreDNS / node IP is hardcoded anywhere; the resolver
address is still discovered at runtime from the container's `/etc/resolv.conf`
by the image entrypoint.

### Environment variables

| Variable | Used by | Purpose |
| --- | --- | --- |
| `VITE_API_URL` | built frontend bundle (dev & prod) | Frontend REST API base URL, including the `/api` prefix (e.g. `http://localhost:8080/api`) -- `lib/api.ts` appends each call's path (`/devices`, `/alerts/active`, ...) directly onto it |
| `VITE_WS_URL` | dev build only | Explicit WebSocket URL override; when unset, `useLiveStream` derives `ws(s)://<current origin>/ws/sensors` from the browser location |
| `BACKEND_UPSTREAM` | Nginx (runtime) | Backend `host:port` the container's reverse proxy targets |

`.env.development` sets the first two for local `npm run dev` against a
directly-reachable backend; `.env.production` only sets `VITE_API_URL=/api`,
since the production bundle always goes through the same-origin Nginx proxy.

### Remaining live validation

Static tests cannot cover in-cluster DNS. After deploying to a cluster:

- From the frontend Pod, verify `wget -qO- http://localhost/api/sensors/latest`
  (or the real health path) returns success.
- Verify a `/ws/sensors` upgrade succeeds.
- Run `nginx -T` in the Pod and confirm `proxy_pass` targets the FQDN authority
  and `resolver` is the Pod's CoreDNS ClusterIP, with no hardcoded IP in the
  committed template.
