# Find the root of the repo as we use cd a lot and just can run in subdirs
# unlike Make so ensure we're always cding into the right dir
_root := `git rev-parse --show-toplevel 2>/dev/null`

## Private helpers
_default:
  @just --list

_init-tf:
  @cd {{_root}}/terraform && terraform init

# Test the deployed app
validate:
    cd {{_root}}/app && uv run --python "${PYTHON_VERSION}" python tests/validate.py

## Terraform targets

bootstrap:
  cd {{_root}}/terraform/bootstrap && ./bootstrap.sh

plan: _init-tf
  cd {{_root}}/terraform && terraform plan

_build:
  cd {{_root}}/app && ./build.sh "${PYTHON_VERSION}"

apply: _init-tf _build
  cd {{_root}}/terraform && terraform apply -auto-approve

deploy: bootstrap apply

# Normally i'd leave this out of a prod script, here for convenience
destroy *args:
  cd {{_root}}/terraform/bootstrap && ./destroy.sh {{args}}

# clean up build files
clean:
    rm -rf \
      {{_root}}/terraform/.terraform \
      {{_root}}/terraform/bootstrap/.terraform \
      {{_root}}/terraform/bootstrap/terraform.tfstate*
