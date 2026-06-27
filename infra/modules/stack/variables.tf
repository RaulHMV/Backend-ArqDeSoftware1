variable "env" {
  description = "Ambiente (dev/prod)."
  type        = string
}

variable "region" {
  type    = string
  default = "us-east-1"
}

variable "project" {
  type    = string
  default = "ticketsys"
}

variable "cors_origins" {
  description = "Origenes permitidos para CORS (HTTP API y S3). '*' mientras no haya frontend."
  type        = list(string)
  default     = ["*"]
}

variable "backend_dist_path" {
  description = "Ruta a backend/dist (donde esbuild deja los bundles)."
  type        = string
}
