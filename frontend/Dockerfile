# =============================================
# Stage 1: Build React application
# =============================================
FROM node:20-alpine AS builder

WORKDIR /app

COPY package*.json ./
RUN npm ci

COPY . .

RUN npm run build

# =============================================
# Stage 2: Serve with Nginx
# =============================================
FROM nginx:1.25-alpine

COPY --from=builder /app/dist /usr/share/nginx/html

COPY nginx.conf /etc/nginx/templates/default.conf.template

# Default backend upstream authority (host:port). Docker Compose uses this
# value as-is; the Kubernetes frontend Deployment overrides it with the
# fully-qualified backend Service name.
ENV BACKEND_UPSTREAM=backend:8080

# Restrict envsubst to the resolver variable and the backend upstream authority
# so native Nginx variables (e.g. $host, $uri, $http_upgrade, $backend_upstream)
# are preserved in the rendered config; the filter is name-anchored so only
# NGINX_LOCAL_RESOLVERS and BACKEND_UPSTREAM are expanded.
ENV NGINX_ENTRYPOINT_LOCAL_RESOLVERS=1
ENV NGINX_ENVSUBST_FILTER=^(NGINX_LOCAL_RESOLVERS|BACKEND_UPSTREAM)$

EXPOSE 80

CMD ["nginx", "-g", "daemon off;"]