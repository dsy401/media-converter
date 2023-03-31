provider "aws" {
  region = "us-east-1"
}


module "video" {
  source = "./modules/video"
}