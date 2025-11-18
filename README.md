# GEL Take Home

## Assumptions

1. Terraform has unrestricted permissions for deployment
   - Uses the user's configured local AWS credentials
2. Deployed in a single AWS account using `AdministratorAccess` permissions
3. No use of external terraform modules (eg: [s3-bucket](https://github.com/terraform-aws-modules/terraform-aws-s3-bucket))
   so you can evaluate my code rather than just calling libs
4. This single AWS account has no running workloads and is used purely for
   evaluation of this test
   - While the code in the repo should not touch any other resources and uses
     what I assume are unique prefixes I don't want to accidentally blast
     anything you already have!
5. The uploaded files should not be kept in the ingest bucket
   - Saves on costs
   - Prevents storing images with exif data which may contain sensitive
     information
6. `eu-west-2` (London) as the AWS region
7. No public access on any buckets, assumes the website process has the required
   IAM perms to read the images from the bucket and serves them to the user
8. You are running `bash`/`zsh` on `linux`/`macos`
   - This has only been tested on `linux` with `bash`, should work with `zsh`
   - It should work on MacOS
     - You may need to ensure you have a modern version of bash installed, MacOS
       comes with a version from 2007
   - I do not expect it to work on Windows directly, it should work in WSL fine.
     - You will need to run all commands bundled in the `justfile` manually
       replacing the linux calls to ENVARS with Windows equivalents
     - For a real version of this I would work with a Windows user to
       get it working. As I don't have any Windows machines I can't easily
       test

## Requirements

### Local Dependencies

Install the following dependencies if not already installed and ensure they are
available in your `PATH`:

- [git-lfs](https://docs.github.com/en/repositories/working-with-files/managing-large-files/installing-git-large-file-storage) (as not to store binary files in git directly)
- [terraform](https://developer.hashicorp.com/terraform/install)
- [just](https://github.com/casey/just?tab=readme-ov-file#installation)
- [uv](https://docs.astral.sh/uv/getting-started/installation)
- [aws cli](https://docs.aws.amazon.com/cli/latest/userguide/getting-started-install.html) (v2)

### AWS Account

1. Empty AWS Account
   - While none of this code should affect any existing resources the safest
     way to test this code is to use an empty AWS account so there are no
     conflicts.
2. Local AWS User configured in your environment and usable by Terraform/scripts
3. Local AWS User configured with `AdministratorAccess` permissions
   - This is bad practice but for this test creating IAM permissions for
     Terraform/Testing is out of scope IMO
4. Local AWS User configured to use `eu-west-2` (used by `aws` cli tool)

### Quick Start

1. Run `just deploy`
   - Bootstraps the terraform state resources
   - Uploads state to s3 bucket
   - Runs `terraform apply` to deploy the app
2. Run `just validate`
   - Runs `app/tests/validate.py` to validate the app works
     - Uploads some test files to the ingest bucket
     - Check the files end up in the expected buckets
3. Run `just destroy`
   - Destroys all AWS resources created by terraform
   - WARNING: This uses the `aws` cli to do this as we set `prevent_delete` on a
     lot of resources. While this should only delete resources we have created
     review the output of what will be deleted then confirm.

### Not so Quick Start

1. Run `just bootstrap`
   - Runs `terraform/bootstrap/bootstrap.sh`
     - Runs the `terraform/modules/bootstrap` module with local state
       - Calls the `terraform/modules/core` module which creates the
         bucket/dynamodb used for remote state (and all other `core` resources)
     - Uses `aws` cli tool to upload the state to the bucket so we can use
       remote state in subsiquent runs.
2. Run `just plan`
   - Runs `terraform plan`
3. Run `just apply`
   - Runs `terraform apply`
4. Run `just validate`
   - Runs the test script for the app (`app/tests/validate.py`):
     - Uploads test images to the `gel-exifstrip-ingest` bucket.
     - Monitors `gel-exifstrip-processed` for valid JPEG files
     - Downloads valid files and tests for absence of EXIF data
5. Run `just destroy`
   - Destroys all AWS resources created by terraform
   - WARNING: This uses the `aws` cli to do this as we set `prevent_delete` on a
     lot of resources. While this should only delete resources we have created
     please carefully review the output of what will be deleted before
     confirming.

## Documentation

### Overview

I have added a 3rd bucket (`gel-exiftext-deployment`) which is used for storing
the lambda, this prevents `user_a` from accessing the archives of the code.

The `gel-exifstrip-ingest` bucket has what I would consider reasonable lifecycle
rules for objects given the purpose so we don't hang onto files with potential
PII/sensitive data for too long.

### Lambda Function

- Uses Python 3.14
- Uses `uv` for dependency management
  - Allows easy pinning of python versions
  - Better dependency handling than pip
  - Personal Preference, any Python dependency manager could be used
- Logic:
  - Processes all files uploaded to `gel-exifstrip-ingest`
  - Checks ingested files is a JPEG file
  - Uses the [Pillow](https://github.com/python-pillow/Pillow) lib for image
    processing
  - Validates EXIF data has been removed from image
  - If not a valid JPEG file/fails processing/is too large
    - Remove file from bucket `gel-exifstrip-ingest`
  - If JPEG file & processing successful
    - Upload processed JPEG file to `gel-exifstrip-processed`
    - Remove source file from bucket `gel-exifstrip-ingest`
  - Logs to CloudWatch
    - View logs with `aws logs tail /aws/lambda/gel-exifstrip-image-processor --follow`

### Terraform

- All S3 buckets have public access blocked
- KMS encryption enabled on all data at rest
- Automatic KMS key rotation configured
- Critical resources protected from accidental deletion

## Future Improvement

These are some things I would do for a prod codebase but seemed out of scope for
the test.

### Improved failed file handling

At present just delete the file if it doesn't meet out needs. This could be
sending them to another bucket for further inspection, creating CloudWatch
metrics to allow monitoring of the number of processed/failed files over time
etc. This would really depend on the needs of the website.

### Add tests

Adding tests for both the app and terraform code would allow for more confidence
in making changes. I considered adding these but decided against it due to time
constraints.

### CI/CD

For a production codebase I'd expect this to all be deployed using CI/CD rather
than a manual process. It was kept as a manual process for this test.
