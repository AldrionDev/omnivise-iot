resource "kubernetes_ingress_v1" "frontend" {
  wait_for_load_balancer = true

  metadata {
    name      = "frontend"
    namespace = local.namespace

    annotations = {
      "alb.ingress.kubernetes.io/scheme"           = "internet-facing"
      "alb.ingress.kubernetes.io/target-type"      = "ip"
      "alb.ingress.kubernetes.io/healthcheck-path" = "/"
    }
  }

  spec {
    ingress_class_name = "alb"

    rule {
      http {
        path {
          path      = "/"
          path_type = "Prefix"

          backend {
            service {
              name = "frontend"

              port {
                number = 80
              }
            }
          }
        }
      }
    }
  }

  depends_on = [
    module.application,
  ]
}
