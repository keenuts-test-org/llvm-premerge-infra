# Setup

- install terraform (https://developer.hashicorp.com/terraform/install?product_intent=terraform(
- get the GCP tokens: `gcloud auth application-default login`
- initialize terraform: `terraform init`
- setup the cluster: `terraform apply`
- terraform will list the list of proposed changes.
- enter 'yes' when prompted.

# Debug

## Error: Get "http://localhost/api/v1/namespaces/...": dial tcp 127.0.0.1:80: connect: connection refused

Don't know why this happened. I deleted the `.tfstate*` and the `.terraform` and re-did `terraform init`.
