# Homelab LAN exposure for the OmniVise IoT frontend.
#
# Exactly ONE application-owned Traefik IngressRoute. It matches the canonical
# OmniVise hostname on the plain-HTTP 'web' entrypoint and sends every matching
# request to the cluster-internal frontend Service on port 80. The frontend
# Nginx keeps sole responsibility for /api/* and /ws/* routing, so the browser
# stays same-origin. Backend, MongoDB and the simulator get no route here.
#
# All ingress configuration lives in this environment root, never in
# ../modules/application, so the shared module stays environment-neutral and
# free of homelab.home.arpa.

locals {
  ingress_name = "omnivise-iot-frontend"

  # Reuse the application label convention. The shared module's label locals are
  # not visible from the root, so the stable keys are restated here; part-of is
  # sourced from the existing root local.
  ingress_labels = {
    "app.kubernetes.io/name"       = "frontend"
    "app.kubernetes.io/component"  = "web"
    "app.kubernetes.io/part-of"    = local.application
    "app.kubernetes.io/managed-by" = "terraform"
  }
}

resource "kubernetes_manifest" "frontend_ingressroute" {
  manifest = {
    apiVersion = "traefik.io/v1alpha1"
    kind       = "IngressRoute"

    metadata = {
      name      = local.ingress_name
      namespace = local.namespace
      labels    = local.ingress_labels
    }

    spec = {
      entryPoints = [var.traefik_entrypoint]

      routes = [
        {
          kind  = "Rule"
          match = "Host(`${var.ingress_host}`)"

          services = [
            {
              name = "frontend"
              port = 80
            }
          ]
        }
      ]
    }
  }
}
