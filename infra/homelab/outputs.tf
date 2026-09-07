output "omnivise_iot_url" {
  description = "Homelab LAN URL for the OmniVise IoT frontend via Traefik."
  value       = "http://${var.ingress_host}"
}
