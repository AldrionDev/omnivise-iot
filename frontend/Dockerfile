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

# Restrict envsubst to the resolver variable so native Nginx variables
# (e.g. $host, $uri, $http_upgrade) are preserved in the rendered config.
ENV NGINX_ENTRYPOINT_LOCAL_RESOLVERS=1
ENV NGINX_ENVSUBST_FILTER=^NGINX_LOCAL_RESOLVERS$

EXPOSE 80

CMD ["nginx", "-g", "daemon off;"]