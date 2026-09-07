# React + Vite

This template provides a minimal setup to get React working in Vite with HMR and some ESLint rules.

Currently, two official plugins are available:

- [@vitejs/plugin-react](https://github.com/vitejs/vite-plugin-react/blob/main/packages/plugin-react) uses [Babel](https://babeljs.io/) (or [oxc](https://oxc.rs) when used in [rolldown-vite](https://vite.dev/guide/rolldown)) for Fast Refresh
- [@vitejs/plugin-react-swc](https://github.com/vitejs/vite-plugin-react/blob/main/packages/plugin-react-swc) uses [SWC](https://swc.rs/) for Fast Refresh

## React Compiler

The React Compiler is not enabled on this template because of its impact on dev & build performances. To add it, see [this documentation](https://react.dev/learn/react-compiler/installation).

## Expanding the ESLint configuration

If you are developing a production application, we recommend using TypeScript with type-aware lint rules enabled. Check out the [TS template](https://github.com/vitejs/vite/tree/main/packages/create-vite/template-react-ts) for information on how to integrate TypeScript and [`typescript-eslint`](https://typescript-eslint.io) in your project.

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

### Remaining live validation

Static tests cannot cover in-cluster DNS. After deploying to a cluster:

- From the frontend Pod, verify `wget -qO- http://localhost/api/sensors/latest`
  (or the real health path) returns success.
- Verify a `/ws/sensors` upgrade succeeds.
- Run `nginx -T` in the Pod and confirm `proxy_pass` targets the FQDN authority
  and `resolver` is the Pod's CoreDNS ClusterIP, with no hardcoded IP in the
  committed template.
