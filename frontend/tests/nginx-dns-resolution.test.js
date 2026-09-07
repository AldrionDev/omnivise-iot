// @vitest-environment node

// Static source-contract assertions for the Nginx DNS resolution fix (#37).
//
// These tests read frontend/nginx.conf and frontend/Dockerfile as raw text
// and assert on their literal content. They prove the committed
// template/Dockerfile *contract* (no hardcoded Docker embedded-DNS IP, the
// config is installed as an entrypoint template, the entrypoint's
// local-resolver discovery is enabled) but they do NOT exercise real
// envsubst/entrypoint substitution inside a running container. That
// end-to-end behavior can only be verified by actually starting the
// container (e.g. via docker compose) and inspecting the rendered
// /etc/nginx/conf.d/default.conf.

import { readFileSync } from 'node:fs'
import { fileURLToPath } from 'node:url'
import { describe, expect, it } from 'vitest'

const nginxConfPath = fileURLToPath(new URL('../nginx.conf', import.meta.url))
const dockerfilePath = fileURLToPath(new URL('../Dockerfile', import.meta.url))
const workloadsTfPath = fileURLToPath(
  new URL('../../infra/modules/application/workloads.tf', import.meta.url),
)

const nginxConf = readFileSync(nginxConfPath, 'utf-8')
const dockerfile = readFileSync(dockerfilePath, 'utf-8')
const workloadsTf = readFileSync(workloadsTfPath, 'utf-8')

function extractLocationBlock(text, locationPath) {
  const startMarker = `location ${locationPath} {`
  const startIndex = text.indexOf(startMarker)
  if (startIndex === -1) {
    throw new Error(`location block "${locationPath}" not found in nginx.conf`)
  }
  const blockStart = startIndex + startMarker.length
  const nextLocationIndex = text.indexOf('location ', blockStart)
  const blockEnd = nextLocationIndex === -1 ? text.length : nextLocationIndex
  return text.slice(blockStart, blockEnd)
}

describe('nginx.conf DNS resolver contract', () => {
  it('does not hardcode the Docker embedded-DNS resolver IP', () => {
    expect(nginxConf).not.toContain('127.0.0.11')
  })

  it('resolves DNS via the entrypoint-populated NGINX_LOCAL_RESOLVERS variable', () => {
    expect(nginxConf).toMatch(/resolver\s+\$\{NGINX_LOCAL_RESOLVERS\}/)
  })

  it('keeps the runtime re-resolution TTL on the resolver directive', () => {
    expect(nginxConf).toMatch(/resolver\s+\$\{NGINX_LOCAL_RESOLVERS\}\s+valid=10s;/)
  })

  it('keeps native Nginx variables untouched (not turned into ${...} placeholders)', () => {
    const nativeVars = [
      '$uri',
      '$host',
      '$http_upgrade',
      '$remote_addr',
      '$proxy_add_x_forwarded_for',
      '$scheme',
      '$backend_upstream',
    ]

    for (const nativeVar of nativeVars) {
      expect(nginxConf).toContain(nativeVar)
      expect(nginxConf).not.toContain(`$\{${nativeVar.slice(1)}}`)
    }
  })
})

describe('nginx.conf backend upstream contract', () => {
  it('does not hardcode the backend upstream authority', () => {
    expect(nginxConf).not.toContain('http://backend:8080')
  })

  it('does not pin a fixed resolver IP', () => {
    expect(nginxConf).not.toMatch(/resolver\s+\d{1,3}\.\d{1,3}\.\d{1,3}\.\d{1,3}/)
  })

  it('does not bake Kubernetes identity into the image config', () => {
    expect(nginxConf).not.toContain('omnivise-iot')
    expect(nginxConf).not.toContain('svc.cluster.local')
  })

  it('preserves runtime DNS re-resolution on the resolver directive', () => {
    expect(nginxConf).toMatch(/resolver\s+\$\{NGINX_LOCAL_RESOLVERS\}\s+valid=10s;/)
  })

  it('uses the same templated upstream in both proxy blocks', () => {
    const apiBlock = extractLocationBlock(nginxConf, '/api/')
    const wsBlock = extractLocationBlock(nginxConf, '/ws/')
    expect(apiBlock).toContain('http://${BACKEND_UPSTREAM}')
    expect(wsBlock).toContain('http://${BACKEND_UPSTREAM}')
  })
})

describe('nginx.conf location /api/ block', () => {
  const apiBlock = extractLocationBlock(nginxConf, '/api/')

  it('proxies to the backend upstream', () => {
    expect(apiBlock).toContain('set $backend_upstream http://${BACKEND_UPSTREAM};')
    expect(apiBlock).toContain('proxy_pass $backend_upstream;')
  })
})

describe('nginx.conf location /ws/ block', () => {
  const wsBlock = extractLocationBlock(nginxConf, '/ws/')

  it('proxies to the backend upstream', () => {
    expect(wsBlock).toContain('set $backend_upstream http://${BACKEND_UPSTREAM};')
    expect(wsBlock).toContain('proxy_pass $backend_upstream;')
  })

  it('upgrades the connection for WebSocket support', () => {
    expect(wsBlock).toContain('proxy_set_header Upgrade $http_upgrade;')
    expect(wsBlock).toMatch(/proxy_set_header Connection\s+["']?Upgrade["']?;/i)
  })

  it('uses HTTP/1.1 to the upstream, required for the WebSocket upgrade', () => {
    expect(wsBlock).toContain('proxy_http_version 1.1;')
  })
})

describe('Dockerfile Nginx template contract', () => {
  it('installs nginx.conf as the default.conf.template entrypoint template, not directly into conf.d', () => {
    // Must render to /etc/nginx/conf.d/default.conf specifically: any other
    // template name leaves the base image's stock default.conf in place,
    // producing a conflicting default server.
    expect(dockerfile).toMatch(/COPY\s+nginx\.conf\s+\/etc\/nginx\/templates\/default\.conf\.template/)
    expect(dockerfile).not.toMatch(/COPY\s+nginx\.conf\s+\/etc\/nginx\/conf\.d\//)
  })

  it('enables the official entrypoint local-resolver discovery', () => {
    expect(dockerfile).toMatch(/ENV\s+NGINX_ENTRYPOINT_LOCAL_RESOLVERS=(1|true|"true"|'true')/i)
  })

  it('restricts envsubst to the resolver and backend upstream variables so native Nginx variables survive', () => {
    expect(dockerfile).toMatch(/ENV\s+NGINX_ENVSUBST_FILTER=\^\(NGINX_LOCAL_RESOLVERS\|BACKEND_UPSTREAM\)\$/)
  })

  it('keeps the Docker Compose default backend upstream authority', () => {
    expect(dockerfile).toMatch(/ENV\s+BACKEND_UPSTREAM=backend:8080/)
  })

  it('does not override the official image entrypoint', () => {
    expect(dockerfile).not.toMatch(/^\s*ENTRYPOINT\b/m)
  })
})

describe('Terraform frontend workload backend upstream wiring', () => {
  it('injects the backend upstream env var into the frontend container', () => {
    expect(workloadsTf).toMatch(/name\s*=\s*"BACKEND_UPSTREAM"/)
  })

  it('builds a namespaced FQDN from the module input, not a literal namespace or IP', () => {
    expect(workloadsTf).toMatch(
      /backend\.\$\{local\.app_namespace\}\.svc\.cluster\.local:\$\{local\.backend_port\}/,
    )
  })

  it('does not inject any resolver / DNS-server config from Terraform', () => {
    expect(workloadsTf).not.toMatch(/resolver/i)
  })

  it('contains no dotted-quad IP literal', () => {
    expect(workloadsTf).not.toMatch(/\b\d{1,3}\.\d{1,3}\.\d{1,3}\.\d{1,3}\b/)
  })
})
