module "stack" {
  source            = "../../modules/stack"
  env               = "prod"
  region            = var.region
  project           = var.project
  cors_origins      = var.cors_origins
  backend_dist_path = "${path.root}/../../../backend/dist"
}
