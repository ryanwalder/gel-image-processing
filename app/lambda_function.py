import logging
import os
import tempfile
import time

import boto3
from botocore.exceptions import ClientError
from PIL import Image, UnidentifiedImageError

# Configure logging/boto
logger = logging.getLogger(__name__)
s3_client = boto3.client("s3")
ssm_client = boto3.client("ssm")

# Cache for SSM parameters to avoid repeated calls with 5-minute TTL
_param_cache = {}
_param_cache_timestamp = None
_PARAM_CACHE_TTL_SECONDS = 300


def _setup_logging():
    """
    Set up logging configuration based on the LOG_LEVEL environment variable.

    Validates the log level and defaults to INFO if invalid. Configures basic logging
    with timestamp, logger name, level, and message.
    """
    valid_log_levels = {
        "DEBUG": logging.DEBUG,
        "INFO": logging.INFO,
        "WARNING": logging.WARNING,
        "ERROR": logging.ERROR,
        "CRITICAL": logging.CRITICAL,
    }

    log_level_str = os.getenv("LOG_LEVEL", "INFO").upper()

    if log_level_str not in valid_log_levels:
        logger.warning(f"Invalid LOG_LEVEL '{log_level_str}', defaulting to INFO")
        log_level = logging.INFO
    else:
        log_level = valid_log_levels[log_level_str]

    logging.basicConfig(
        level=log_level, format="%(asctime)s - %(name)s - %(levelname)s - %(message)s"
    )

    logger.setLevel(log_level)
    logger.info(f"Logging configured with level: {log_level_str}")


def _download_file(bucket, key, local_path):
    """
    Download a file from the specified S3 bucket and key to the local path.

    Args:
        bucket (str): The S3 bucket name.
        key (str): The S3 object key.
        local_path (str): The local file path to save the downloaded file.

    Raises:
        ClientError: If the download fails.
    """
    try:
        s3_client.download_file(bucket, key, local_path)
        logger.debug(f"Downloaded {key} from {bucket} to {local_path}")
    except ClientError as e:
        logger.error(f"Failed to download {key} from {bucket}: {e}")
        raise


def _upload_file(bucket, key, local_path, kms_key_arn=None):
    """
    Upload a local file to the specified S3 bucket and key.

    Args:
        bucket (str): The S3 bucket name.
        key (str): The S3 object key.
        local_path (str): The local file path to upload.
        kms_key_arn (str, optional): KMS key ARN for server-side encryption.

    Raises:
        ClientError: If the upload fails.
    """
    try:
        extra_args = {}
        if kms_key_arn:
            extra_args = {"ServerSideEncryption": "aws:kms", "SSEKMSKeyId": kms_key_arn}
        s3_client.upload_file(local_path, bucket, key, ExtraArgs=extra_args)
        logger.debug(f"Uploaded {local_path} to {bucket}/{key}")
    except ClientError as e:
        logger.error(f"Failed to upload {local_path} to {bucket}/{key}: {e}")
        raise


def _delete_file(bucket, key):
    """
    Delete a file from the specified S3 bucket and key.

    Args:
        bucket (str): The S3 bucket name.
        key (str): The S3 object key.

    Raises:
        ClientError: If the delete fails.
    """
    try:
        s3_client.delete_object(Bucket=bucket, Key=key)
        logger.debug(f"Deleted {key} from {bucket}")
    except ClientError as e:
        logger.error(f"Failed to delete {key} from {bucket}: {e}")
        raise


def _is_jpeg(file_path):
    """
    Check if the file at the given path is a valid JPEG image.

    Performs validation:
    1. File extension check (.jpg or .jpeg)
    2. Pillow library validation

    Args:
        file_path (str): The path to the file to check.

    Returns:
        bool: True if the file is a valid JPEG, False otherwise.
    """
    # Check file extension
    ext = os.path.splitext(file_path)[1].lower()
    if ext not in [".jpg", ".jpeg"]:
        logger.debug(f"File {file_path} rejected: invalid extension {ext}")
        return False

    try:
        with Image.open(file_path) as img:
            is_jpeg = img.format == "JPEG"
            if not is_jpeg:
                logger.warning(f"File {file_path} is {img.format}, not JPEG")
                return False

        # Reopen to verify (verify() invalidates the image)
        with Image.open(file_path) as img:
            img.verify()

        return True
    except UnidentifiedImageError:
        logger.warning(f"File {file_path} is not a recognized image format")
        return False
    except (IOError, SyntaxError) as e:
        logger.error(f"PIL validation error for {file_path}: {e}")
        return False


def _strip_exif(file_path):
    """
    Strip EXIF data from the JPEG file at the given path atomically.

    Uses Pillow to remove EXIF metadata by writing to a temp file,
    then atomically replacing the original to prevent data loss on write failure.
    File is closed before atomic rename to avoid descriptor leaks.

    Args:
        file_path (str): The path to the JPEG file.

    Raises:
        OSError: If file access fails
        ValueError: If image processing fails
    """
    temp_path = None
    try:
        # First, check if image has EXIF data (closes file after check)
        with Image.open(file_path) as img:
            has_exif = bool(img.getexif())

        if not has_exif:
            logger.info(f"No EXIF data present in {file_path}, no stripping needed")
            return

        # Create temp file in same directory for atomic rename
        dir_path = os.path.dirname(file_path) or "."
        _, ext = os.path.splitext(file_path)
        with tempfile.NamedTemporaryFile(delete=False, dir=dir_path, suffix=ext) as tmp:
            temp_path = tmp.name

        # Open file again to process and save to temp (closes before rename)
        with Image.open(file_path) as img:
            img.save(temp_path, format="JPEG", exif=b"")

        # Atomic rename only after successful save and file is closed
        os.replace(temp_path, file_path)
        temp_path = None
        logger.info(f"EXIF data stripped from {file_path}")

    except (OSError, IOError) as e:
        logger.error(f"File access error while stripping EXIF from {file_path}: {e}")
        if temp_path and os.path.exists(temp_path):
            os.unlink(temp_path)
        raise OSError(f"Failed to access file for EXIF stripping: {e}")
    except ValueError as e:
        logger.error(
            f"Image processing error while stripping EXIF from {file_path}: {e}"
        )
        if temp_path and os.path.exists(temp_path):
            os.unlink(temp_path)
        raise ValueError(f"Failed to process image for EXIF stripping: {e}")


def _exif_removed(file_path):
    """
    Check if EXIF data has been successfully removed from the JPEG file.

    Loads EXIF data and checks if any metadata is present.

    Args:
        file_path (str): The path to the JPEG file.

    Returns:
        bool: True if no EXIF data is present, False otherwise.

    Raises:
        Exception: If EXIF loading fails.
    """
    try:
        with Image.open(file_path) as img:
            has_exif = bool(img.getexif())
            return not has_exif
    except Exception as e:
        logger.error(f"Failed to check EXIF removal for {file_path}: {e}")
        raise


def _process_file(
    file_path, key, ingest_bucket, processed_bucket, processed_kms_key_arn
):
    """
    Process the downloaded file: validate JPG, strip EXIF, check removal, upload to processed or delete if failed.

    Args:
        file_path (str): Path to the downloaded file.
        key (str): S3 object key.
        ingest_bucket (str): The ingest bucket name.
        processed_bucket (str): The processed bucket name.
        processed_kms_key_arn (str): KMS key ARN for processed bucket encryption.
    """
    if not _is_jpeg(file_path):
        logger.warning(f"File {key} is not a valid JPEG, deleting")
        _delete_file(ingest_bucket, key)
        return

    try:
        _strip_exif(file_path)
    except Exception as e:
        logger.error(f"Failed to strip EXIF from {key}: {e}, deleting file")
        _delete_file(ingest_bucket, key)
        return

    try:
        if not _exif_removed(file_path):
            logger.error(f"EXIF data still present in {key}, deleting file")
            _delete_file(ingest_bucket, key)
            return
    except Exception as e:
        logger.error(f"Failed to check EXIF removal for {key}: {e}, deleting file")
        _delete_file(ingest_bucket, key)
        return

    _upload_file(processed_bucket, key, file_path, kms_key_arn=processed_kms_key_arn)
    _delete_file(ingest_bucket, key)


def _get_config():
    """
    Fetch configuration from AWS Systems Manager Parameter Store.

    Parameters are cached across Lambda invocations for performance with 5-minute TTL.
    Cache is invalidated if older than 5 minutes to detect parameter updates.

    Returns:
        tuple: (ingest_bucket, processed_bucket, file_max_size, processed_kms_key_arn)
    """
    global _param_cache, _param_cache_timestamp

    # Return cached parameters if available and not stale
    if _param_cache and _param_cache_timestamp is not None:
        cache_age = time.time() - _param_cache_timestamp
        if cache_age < _PARAM_CACHE_TTL_SECONDS:
            logger.debug(f"Using cached config (age: {cache_age:.1f}s)")
            return (
                _param_cache["ingest_bucket"],
                _param_cache["processed_bucket"],
                _param_cache["file_max_size"],
                _param_cache["processed_kms_key_arn"],
            )
        else:
            logger.info(f"Invalidating stale config cache (age: {cache_age:.1f}s)")
            _param_cache.clear()
            _param_cache_timestamp = None

    try:
        project_name = os.getenv("PROJECT_NAME", "gel-exifstrip")

        # Fetch all parameters in one call for efficiency
        response = ssm_client.get_parameters(
            Names=[
                f"/{project_name}/ingest-bucket",
                f"/{project_name}/processed-bucket",
                f"/{project_name}/processed-kms-key-arn",
                f"/{project_name}/max-file-size",
            ],
            WithDecryption=True,
        )

        if len(response["Parameters"]) != 4:
            logger.error(f"Expected 4 parameters, got {len(response['Parameters'])}")
            return None, None, None, None

        params = {param["Name"]: param["Value"] for param in response["Parameters"]}

        ingest_bucket = params.get(f"/{project_name}/ingest-bucket")
        processed_bucket = params.get(f"/{project_name}/processed-bucket")
        processed_kms_key_arn = params.get(f"/{project_name}/processed-kms-key-arn")

        try:
            file_max_size = int(
                params.get(f"/{project_name}/max-file-size", "10485760")
            )
        except ValueError:
            logger.warning(
                "Invalid MAX_FILE_SIZE in Parameter Store, using default 10485760"
            )
            file_max_size = 10485760

        # Validate buckets
        for name, bucket in [
            ("ingest_bucket", ingest_bucket),
            ("processed_bucket", processed_bucket),
        ]:
            if not bucket or not isinstance(bucket, str) or not bucket.strip():
                logger.error(f"Invalid {name}: must be a non-empty string")
                return None, None, None, None
            try:
                s3_client.head_bucket(Bucket=bucket)
            except ClientError as e:
                logger.error(f"{name} '{bucket}' does not exist or access denied: {e}")
                return None, None, None, None

        if not processed_kms_key_arn:
            logger.error("processed_kms_key_arn is required")
            return None, None, None, None

        # Cache the parameters for subsequent invocations with timestamp
        _param_cache["ingest_bucket"] = ingest_bucket
        _param_cache["processed_bucket"] = processed_bucket
        _param_cache["file_max_size"] = file_max_size
        _param_cache["processed_kms_key_arn"] = processed_kms_key_arn
        _param_cache_timestamp = time.time()

        logger.info("Fetched fresh config from Parameter Store")
        return ingest_bucket, processed_bucket, file_max_size, processed_kms_key_arn

    except ClientError as e:
        logger.error(f"Failed to fetch parameters from Parameter Store: {e}")
        return None, None, None, None


def _process_record(record, processed_bucket, file_max_size, processed_kms_key_arn):
    """
    Process a single S3 event record.

    Args:
        record (dict): S3 event record.
        processed_bucket (str): Processed bucket name.
        file_max_size (int): Max file size.
        processed_kms_key_arn (str): KMS key ARN for processed bucket encryption.
    """
    bucket = record["s3"]["bucket"]["name"]
    key = record["s3"]["object"]["key"]
    size = record["s3"]["object"].get("size")

    # Get object size metadata delete in 0/undefined or > FILE_MAX_SIZE
    if size is None:
        logger.error(f"File {key} size missing from event, deleting")
        _delete_file(bucket, key)
        return

    if size > file_max_size:
        logger.error(f"File {key} size {size} exceeds {file_max_size}, deleting")
        _delete_file(bucket, key)
        return

    logger.info(f"Processing file {key} from {bucket}")

    # Preserve file extension in temp file for format validation
    _, ext = os.path.splitext(key)
    with tempfile.NamedTemporaryFile(delete=False, suffix=ext) as tmp:
        local_path = tmp.name

    try:
        _download_file(bucket, key, local_path)
        _process_file(local_path, key, bucket, processed_bucket, processed_kms_key_arn)
    finally:
        if os.path.exists(local_path):
            os.unlink(local_path)
            logger.debug(f"Cleaned up temp file {local_path}")

    logger.info(f"Processed and cleaned up {key}")


def lambda_handler(event, context):
    """
    AWS Lambda handler function to process S3 events.

    Processes images from the ingest bucket, strips EXIF data,
    and moves them to processed bucket. Failed files are deleted.

    Args:
        event (dict): AWS event object containing S3 records
        context (LambdaContext): AWS Lambda context object

    Returns:
        dict: Status information about the execution
    """
    _setup_logging()

    ingest_bucket, processed_bucket, file_max_size, processed_kms_key_arn = (
        _get_config()
    )
    if not ingest_bucket:
        return {"status": "error", "message": "Configuration retrieval failed"}

    record_count = len(event.get("Records", []))
    processed_count = 0
    failed_records = []

    for record in event.get("Records", []):
        try:
            _process_record(
                record, processed_bucket, file_max_size, processed_kms_key_arn
            )
            processed_count += 1
        except Exception as e:
            record_key = record.get("s3", {}).get("object", {}).get("key", "unknown")
            logger.error(f"Failed to process record {record_key}: {e}")
            failed_records.append(record_key)

    if processed_count == 0 and record_count > 0:
        status = "error"
        logger.error(f"All {record_count} records failed to process")
    elif processed_count == record_count:
        status = "success"
        logger.info(f"Successfully processed all {record_count} records")
    else:
        status = "partial_failure"
        logger.warning(
            f"Processed {processed_count}/{record_count} records. {len(failed_records)} failed."
        )

    return {
        "status": status,
        "processed": processed_count,
        "total": record_count,
        "failed": len(failed_records),
    }
