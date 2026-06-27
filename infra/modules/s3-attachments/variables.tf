variable "prefix" {
  type = string
}

variable "cors_origins" {
  type    = list(string)
  default = ["*"]
}

variable "tags" {
  type    = map(string)
  default = {}
}
