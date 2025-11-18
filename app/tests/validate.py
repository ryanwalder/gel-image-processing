#!/usr/bin/env python3
"""
Validation script for the image processing Lambda function and IAM user permissions.

This script performs three phases of testing:
1. Lambda Processing Tests: Upload files and validate Lambda processes them correctly
2. User A Permission Tests: Verify user_a can read/write (but not delete) to ingest bucket
3. User B Permission Tests: Verify user_b can read (but not write) from processed bucket

The script reads configuration from Terraform outputs.
"""

import json
import subprocess
import sys
import time
from pathlib import Path

import boto3
from botocore.exceptions import ClientError
from PIL import Image

# Test files to upload
FILES = [
    "test_image_no_exif.jpg",  # Valid JPEG without EXIF
    "test_image_with_exif.jpg",  # Valid JPEG with EXIF
    "test_image_renamed_ext.jpg",  # .gif renamed to .jpg (invalid)
    "test_image_wrong_ext.jpg",  # PNG with .jpg extension (invalid)
    "test_image_wrong_format.png",  # PNG file (not JPEG)
    "large_junkfile_named_jpg.jpg",  # Large file (may exceed size limit)
    "large_junkfile_named_exe.exe",  # EXE file (not an image)
]

EXPECTED_PROCESSED = [
    "test_image_no_exif.jpg",
    "test_image_with_exif.jpg",
]

EXPECTED_DELETED = [
    "test_image_renamed_ext.jpg",
    "test_image_wrong_ext.jpg",
    "test_image_wrong_format.png",
    "large_junkfile_named_jpg.jpg",
    "large_junkfile_named_exe.exe",
]


def get_terraform_outputs():
    """
    Read Terraform outputs to get bucket names and IAM user credentials.

    Returns:
        dict: Configuration with bucket names and user credentials
    """
    try:
        result = subprocess.run(
            ["terraform", "output", "-json"],
            cwd=Path(__file__).parent.parent.parent / "terraform",
            capture_output=True,
            text=True,
            check=True,
        )
        outputs = json.loads(result.stdout)

        # Get bucket encryption from S3 API
        s3_system = boto3.client("s3")

        # Get KMS key for ingest bucket
        ingest_enc = s3_system.get_bucket_encryption(
            Bucket=outputs["ingest_bucket_name"]["value"]
        )
        ingest_kms_key = ingest_enc["ServerSideEncryptionConfiguration"]["Rules"][0][
            "ApplyServerSideEncryptionByDefault"
        ]["KMSMasterKeyID"]

        # Get KMS key for processed bucket
        processed_enc = s3_system.get_bucket_encryption(
            Bucket=outputs["processed_bucket_name"]["value"]
        )
        processed_kms_key = processed_enc["ServerSideEncryptionConfiguration"]["Rules"][
            0
        ]["ApplyServerSideEncryptionByDefault"]["KMSMasterKeyID"]

        config = {
            "ingest_bucket": outputs["ingest_bucket_name"]["value"],
            "processed_bucket": outputs["processed_bucket_name"]["value"],
            "ingest_kms_key": ingest_kms_key,
            "processed_kms_key": processed_kms_key,
            "user_a_access_key": outputs["user_a_access_key_id"]["value"],
            "user_a_secret_key": outputs["user_a_secret_access_key"]["value"],
            "user_b_access_key": outputs["user_b_access_key_id"]["value"],
            "user_b_secret_key": outputs["user_b_secret_access_key"]["value"],
        }
        return config
    except subprocess.CalledProcessError as e:
        print(f"Failed to get Terraform outputs: {e}")
        print(f"stderr: {e.stderr}")
        sys.exit(1)
    except (json.JSONDecodeError, KeyError) as e:
        print(f"Failed to parse Terraform outputs: {e}")
        sys.exit(1)


def create_s3_client(access_key, secret_key):
    """Create S3 client with specific credentials."""
    return boto3.client(
        "s3",
        aws_access_key_id=access_key,
        aws_secret_access_key=secret_key,
    )


def upload_file_to_s3(s3_client, file_path, bucket, key, kms_key_id=None):
    """
    Upload a file to S3 with KMS encryption.

    Args:
        s3_client: Boto3 S3 client
        file_path: Local file path
        bucket: S3 bucket name
        key: S3 object key
        kms_key_id: KMS key ID for encryption (optional)

    Returns:
        bool: True if successful, False otherwise
    """
    try:
        extra_args = {}
        if kms_key_id:
            extra_args = {"ServerSideEncryption": "aws:kms", "SSEKMSKeyId": kms_key_id}
        s3_client.upload_file(str(file_path), bucket, key, ExtraArgs=extra_args)
        return True
    except ClientError as e:
        print(f"Failed to upload {key}: {e}")
        return False


def download_file_from_s3(s3_client, bucket, key, local_path):
    """
    Download a file from S3.

    Returns:
        bool: True if successful, False otherwise
    """
    try:
        s3_client.download_file(bucket, key, str(local_path))
        return True
    except ClientError as e:
        print(f"Failed to download {key}: {e}")
        return False


def check_file_exists(s3_client, bucket, key):
    """
    Check if a file exists in S3.

    Returns:
        bool: True if exists, False otherwise
    """
    try:
        s3_client.head_object(Bucket=bucket, Key=key)
        return True
    except ClientError as e:
        if e.response["Error"]["Code"] == "404":
            return False
        print(f"Error checking if {key} exists in {bucket}: {e}")
        return False


def list_bucket(s3_client, bucket):
    """
    List objects in a bucket.

    Returns:
        list: List of object keys, or None on error
    """
    try:
        response = s3_client.list_objects_v2(Bucket=bucket)
        return [obj["Key"] for obj in response.get("Contents", [])]
    except ClientError as e:
        print(f"Failed to list bucket {bucket}: {e}")
        return None


def delete_file_from_s3(s3_client, bucket, key):
    """
    Delete a file from S3.

    Returns:
        bool: True if successful, False otherwise
    """
    try:
        s3_client.delete_object(Bucket=bucket, Key=key)
        return True
    except ClientError as e:
        print(f"Failed to delete {key}: {e}")
        return False


def check_exif_removed(file_path):
    """
    Check if EXIF data has been removed from an image.

    Returns:
        bool: True if EXIF removed, False if EXIF present
    """
    try:
        with Image.open(file_path) as img:
            has_exif = bool(img.getexif())
            return not has_exif
    except Exception as e:
        print(f"Failed to check EXIF for {file_path}: {e}")
        return False


def test_permission(s3_client, action_desc, test_func, should_succeed):
    """
    Test a permission and verify it matches expected behavior.

    Args:
        s3_client: Boto3 S3 client
        action_desc: Description of the action being tested
        test_func: Function to execute that returns (success: bool, error: str)
        should_succeed: Whether the action should succeed (True) or fail (False)

    Returns:
        bool: True if test passed, False otherwise
    """
    success, error = test_func()

    if should_succeed:
        if success:
            print(f"✅ {action_desc} (allowed as expected)")
            return True
        else:
            print(f"❌ {action_desc} (should be allowed but was denied)")
            print(f"  Error: {error}")
            return False
    else:
        if not success:
            print(f"✅ {action_desc} (denied as expected)")
            return True
        else:
            print(f"❌ {action_desc} (should be denied but was allowed)")
            return False


def test_lambda_processing(config):
    """
    Phase 1: Test Lambda processing with user_a credentials.

    Upload test files, wait for Lambda processing, verify results.

    Returns:
        tuple (success: bool, test_count: int)
    """
    print("=" * 50)
    print("LAMBDA PROCESSING TESTS")
    print("=" * 50)

    # Create S3 clients for user_a and user_b
    s3_user_a = create_s3_client(
        config["user_a_access_key"], config["user_a_secret_key"]
    )
    s3_user_b = create_s3_client(
        config["user_b_access_key"], config["user_b_secret_key"]
    )

    tests_passed = 0
    tests_total = 0
    images_dir = Path(__file__).parent / "images"

    # Upload all test files using user_a
    print("Uploading test files to ingest bucket...")
    uploaded_files = []
    for filename in FILES:
        source_path = images_dir / filename
        if not source_path.exists():
            print(f"Test file {filename} not found, skipping")
            continue

        if upload_file_to_s3(
            s3_user_a,
            source_path,
            config["ingest_bucket"],
            filename,
            config["ingest_kms_key"],
        ):
            uploaded_files.append(filename)
            print(f"  Uploaded: {filename}")
        else:
            print(f"  Failed to upload: {filename}")

    if not uploaded_files:
        print("No files were uploaded successfully")
        return False, 0

    print("Waiting for Lambda to process files...")

    max_wait_time = 90
    check_interval = 5
    elapsed = 0

    while elapsed < max_wait_time:
        time.sleep(check_interval)
        elapsed += check_interval

        # Check if all expected files have been processed or deleted
        all_done = True
        for filename in uploaded_files:
            exists_in_ingest = check_file_exists(
                s3_user_a, config["ingest_bucket"], filename
            )
            if exists_in_ingest:
                all_done = False
                break

        if all_done:
            print(f"All files processed (took {elapsed} seconds)")
            break

        print(f"  Still processing... ({elapsed}s elapsed)")

    if elapsed >= max_wait_time:
        print("Reached maximum wait time, proceeding with validation")

    print("Verifying processed files...")
    for filename in EXPECTED_PROCESSED:
        if filename not in uploaded_files:
            continue

        tests_total += 1

        # Should NOT exist in ingest bucket
        if check_file_exists(s3_user_a, config["ingest_bucket"], filename):
            print("  ❌ File still in ingest bucket (should be processed)")
            continue

        # Should exist in processed bucket (checked by user_b)
        if not check_file_exists(s3_user_b, config["processed_bucket"], filename):
            print("  ❌ File not found in processed bucket")
            continue

        # Download and check EXIF removed
        download_path = Path("/tmp") / filename
        if not download_file_from_s3(
            s3_user_b, config["processed_bucket"], filename, download_path
        ):
            print("  ❌ Failed to download processed file")
            continue

        if not check_exif_removed(download_path):
            print("  ❌ EXIF data still present")
            download_path.unlink()
            continue

        download_path.unlink()
        print("  ✅ Processed correctly (in processed bucket, no EXIF data)")
        tests_passed += 1

    print("Verifying deleted files (invalid/failed files)...")
    for filename in EXPECTED_DELETED:
        if filename not in uploaded_files:
            continue

        tests_total += 1

        # Should NOT exist in ingest bucket (deleted by Lambda)
        if check_file_exists(s3_user_a, config["ingest_bucket"], filename):
            print("  ❌ File still in ingest bucket (should be deleted)")
            continue

        # Should NOT exist in processed bucket
        if check_file_exists(s3_user_b, config["processed_bucket"], filename):
            print(
                "  ❌ File found in processed bucket (should be deleted, not processed)"
            )
            continue

        print("  ✅ Deleted correctly (not in any bucket)")
        tests_passed += 1

    print(f"Phase 1 Results: {tests_passed}/{tests_total} tests passed")

    return tests_passed == tests_total, tests_total


def test_user_a_permissions(config):
    """
    Phase 2: Test user_a permissions on ingest bucket.

    user_a should be able to:
    - Upload files to ingest bucket
    - Read files from ingest bucket
    - List ingest bucket

    user_a should NOT be able to:
    - Delete files from ingest bucket
    - Access processed bucket (read or write)

    Returns:
        tuple (success: bool, test_count: int)
    """
    print("=" * 50)
    print("USER_A PERMISSION TESTS")
    print("=" * 50)

    s3_user_a = create_s3_client(
        config["user_a_access_key"], config["user_a_secret_key"]
    )

    tests_passed = 0
    tests_total = 0
    test_file_key = "test_user_a_permissions.txt"
    test_file_content = b"Test file for user_a permissions"
    test_file_path = Path("/tmp") / test_file_key

    # Test 1: Upload to ingest bucket (should succeed)
    tests_total += 1

    def test_upload():
        try:
            test_file_path.write_bytes(test_file_content)
            s3_user_a.upload_file(
                str(test_file_path),
                config["ingest_bucket"],
                test_file_key,
                ExtraArgs={
                    "ServerSideEncryption": "aws:kms",
                    "SSEKMSKeyId": config["ingest_kms_key"],
                },
            )
            return True, None
        except Exception as e:
            return False, str(e)
        finally:
            if test_file_path.exists():
                test_file_path.unlink()

    if test_permission(
        s3_user_a, "user_a upload to ingest", test_upload, should_succeed=True
    ):
        tests_passed += 1

    # Test 2: Read from ingest bucket (should succeed)
    tests_total += 1

    def test_read():
        try:
            s3_user_a.download_file(
                config["ingest_bucket"], test_file_key, str(test_file_path)
            )
            content = test_file_path.read_bytes()
            test_file_path.unlink()
            return content == test_file_content, (
                None if content == test_file_content else "Content mismatch"
            )
        except Exception as e:
            return False, str(e)

    if test_permission(
        s3_user_a, "user_a read from ingest", test_read, should_succeed=True
    ):
        tests_passed += 1

    # Test 3: List ingest bucket (should succeed)
    tests_total += 1

    def test_list():
        try:
            s3_user_a.list_objects_v2(Bucket=config["ingest_bucket"])
            return True, None
        except Exception as e:
            return False, str(e)

    if test_permission(
        s3_user_a, "user_a list ingest bucket", test_list, should_succeed=True
    ):
        tests_passed += 1

    # Test 4: Delete from ingest bucket (should fail)
    tests_total += 1

    def test_delete():
        try:
            s3_user_a.delete_object(Bucket=config["ingest_bucket"], Key=test_file_key)
            return True, None
        except ClientError as e:
            if e.response["Error"]["Code"] in ["AccessDenied", "Forbidden", "403"]:
                return False, str(e)
            return True, None  # Different error, assume it was attempted
        except Exception as e:
            return False, str(e)

    if test_permission(
        s3_user_a, "user_a delete from ingest", test_delete, should_succeed=False
    ):
        tests_passed += 1
    else:
        # If delete succeeded, clean up the file
        try:
            # Use system credentials to delete
            s3_system = boto3.client("s3")
            s3_system.delete_object(Bucket=config["ingest_bucket"], Key=test_file_key)
        except:
            pass

    # Test 5: Read from processed bucket (should fail)
    tests_total += 1

    def test_read_processed():
        try:
            # Try to list processed bucket
            s3_user_a.list_objects_v2(Bucket=config["processed_bucket"])
            return True, None
        except ClientError as e:
            if e.response["Error"]["Code"] in ["AccessDenied", "Forbidden", "403"]:
                return False, str(e)
            return True, None
        except Exception as e:
            return False, str(e)

    if test_permission(
        s3_user_a,
        "user_a access processed bucket",
        test_read_processed,
        should_succeed=False,
    ):
        tests_passed += 1

    # Test 6: Write to processed bucket (should fail)
    tests_total += 1

    def test_write_processed():
        try:
            test_file_path.write_bytes(test_file_content)
            s3_user_a.upload_file(
                str(test_file_path),
                config["processed_bucket"],
                test_file_key,
                ExtraArgs={
                    "ServerSideEncryption": "aws:kms",
                    "SSEKMSKeyId": config["processed_kms_key"],
                },
            )
            return True, None
        except ClientError as e:
            if e.response["Error"]["Code"] in ["AccessDenied", "Forbidden", "403"]:
                return False, str(e)
            return True, None
        except Exception as e:
            return False, str(e)
        finally:
            if test_file_path.exists():
                test_file_path.unlink()

    if test_permission(
        s3_user_a,
        "user_a write to processed bucket",
        test_write_processed,
        should_succeed=False,
    ):
        tests_passed += 1

    print(f"Phase 2 Results: {tests_passed}/{tests_total} tests passed")

    return tests_passed == tests_total, tests_total


def test_user_b_permissions(config):
    """
    Phase 3: Test user_b permissions on processed bucket.

    user_b should be able to:
    - Read files from processed bucket
    - List processed bucket

    user_b should NOT be able to:
    - Write files to processed bucket
    - Delete files from processed bucket
    - Access ingest bucket

    Returns:
        tuple (success: bool, test_count: int)
    """
    print("=" * 50)
    print("USER_B PERMISSION TESTS")
    print("=" * 50)

    s3_user_b = create_s3_client(
        config["user_b_access_key"], config["user_b_secret_key"]
    )

    tests_passed = 0
    tests_total = 0

    # Use a file that was processed in Phase 1 (if any)
    # We expect test_image_no_exif.jpg to be in processed bucket
    test_file_key = "test_image_no_exif.jpg"
    test_file_path = Path("/tmp") / test_file_key

    # Test 1: Read from processed bucket (should succeed)
    tests_total += 1

    def test_read():
        try:
            s3_user_b.download_file(
                config["processed_bucket"], test_file_key, str(test_file_path)
            )
            # Check file was downloaded
            if test_file_path.exists():
                test_file_path.unlink()
                return True, None
            return False, "File not downloaded"
        except Exception as e:
            return False, str(e)

    if test_permission(
        s3_user_b, "user_b read from processed", test_read, should_succeed=True
    ):
        tests_passed += 1

    # Test 2: List processed bucket (should succeed)
    tests_total += 1

    def test_list():
        try:
            s3_user_b.list_objects_v2(Bucket=config["processed_bucket"])
            return True, None
        except Exception as e:
            return False, str(e)

    if test_permission(
        s3_user_b, "user_b list processed bucket", test_list, should_succeed=True
    ):
        tests_passed += 1

    # Test 3: Write to processed bucket (should fail)
    tests_total += 1

    def test_write():
        temp_write_path = Path("/tmp/test_write_userb.txt")
        try:
            temp_write_path.write_bytes(b"test content")
            s3_user_b.upload_file(
                str(temp_write_path),
                config["processed_bucket"],
                "test_write.txt",
                ExtraArgs={
                    "ServerSideEncryption": "aws:kms",
                    "SSEKMSKeyId": config["processed_kms_key"],
                },
            )
            return True, None
        except ClientError as e:
            if e.response["Error"]["Code"] in ["AccessDenied", "Forbidden", "403"]:
                return False, str(e)
            return True, None
        except Exception as e:
            return False, str(e)
        finally:
            if temp_write_path.exists():
                temp_write_path.unlink()

    if test_permission(
        s3_user_b, "user_b write to processed bucket", test_write, should_succeed=False
    ):
        tests_passed += 1

    # Test 4: Delete from processed bucket (should fail)
    tests_total += 1

    def test_delete():
        try:
            s3_user_b.delete_object(
                Bucket=config["processed_bucket"], Key=test_file_key
            )
            return True, None
        except ClientError as e:
            if e.response["Error"]["Code"] in ["AccessDenied", "Forbidden", "403"]:
                return False, str(e)
            return True, None
        except Exception as e:
            return False, str(e)

    if test_permission(
        s3_user_b, "user_b delete from processed", test_delete, should_succeed=False
    ):
        tests_passed += 1

    # Test 5: Access ingest bucket (should fail)
    tests_total += 1

    def test_access_ingest():
        try:
            s3_user_b.list_objects_v2(Bucket=config["ingest_bucket"])
            return True, None
        except ClientError as e:
            if e.response["Error"]["Code"] in ["AccessDenied", "Forbidden", "403"]:
                return False, str(e)
            return True, None
        except Exception as e:
            return False, str(e)

    if test_permission(
        s3_user_b,
        "user_b access ingest bucket",
        test_access_ingest,
        should_succeed=False,
    ):
        tests_passed += 1

    print(f"Phase 3 Results: {tests_passed}/{tests_total} tests passed")

    return tests_passed == tests_total, tests_total


def main():
    """Main validation function."""
    print("Starting validation")

    config = get_terraform_outputs()
    phase1_success, phase1_count = test_lambda_processing(config)
    phase2_success, phase2_count = test_user_a_permissions(config)
    phase3_success, phase3_count = test_user_b_permissions(config)

    # Summary
    print("=" * 50)
    print("VALIDATION SUMMARY")
    print("=" * 50)
    print(f"Phase 1 (Lambda Processing): {'PASS' if phase1_success else 'FAIL'}")
    print(f"Phase 2 (user_a Permissions): {'PASS' if phase2_success else 'FAIL'}")
    print(f"Phase 3 (user_b Permissions): {'PASS' if phase3_success else 'FAIL'}")

    total_tests = phase1_count + phase2_count + phase3_count
    if phase1_success and phase2_success and phase3_success:
        print(f"✅ ALL TESTS PASSED ({total_tests} tests)")
        return 0
    else:
        print(f"❌ SOME TESTS FAILED ({total_tests} tests)")
        return 1


if __name__ == "__main__":
    sys.exit(main())
