import io
import json
import logging
import os
import urllib.parse
import azure.functions as func
from azure.identity import DefaultAzureCredential
from azure.storage.blob import BlobClient
import psycopg2

app = func.FunctionApp()

QUEUE_NAME = os.getenv("STORAGE_QUEUE_NAME", "file-ingestion-queue")
CONNECTION_SETTING = "AzureWebJobsStorage"

# PostgreSQL connection parameters
PG_HOST = os.getenv("PG_HOST")
PG_PORT = os.getenv("PG_PORT", "5432")
PG_DATABASE = os.getenv("PG_DATABASE", "analyticsdb")
PG_USER = os.getenv("PG_USER")
PG_PASSWORD = os.getenv("PG_PASSWORD")
PG_SSLMODE = os.getenv("PG_SSLMODE", "require")
TARGET_TABLE = os.getenv("TARGET_TABLE", "analytics_landing")


@app.queue_trigger(
    arg_name="msg",
    queue_name=QUEUE_NAME,
    connection=CONNECTION_SETTING
)
def process_storage_event(msg: func.QueueMessage) -> None:
    """
    QueueTrigger function triggered whenever an Event Grid event is delivered
    to the Azure Storage Queue upon a new file landing in the storage container.
    """
    msg_id = msg.id
    dequeue_count = msg.dequeue_count
    logging.info(f"Processing queue message ID: {msg_id} (Attempt #{dequeue_count})")

    try:
        raw_body = msg.get_body().decode("utf-8")
        event_payload = json.loads(raw_body)

        # Event Grid payloads may be wrapped in a JSON list or a single JSON object
        if isinstance(event_payload, list):
            event_payload = event_payload[0]

        event_type = event_payload.get("eventType")
        data = event_payload.get("data", {})

        # Verify event type
        if event_type != "Microsoft.Storage.BlobCreated":
            logging.info(f"Ignoring non-BlobCreated event type: {event_type}")
            return

        raw_blob_url = data.get("url")
        if not raw_blob_url:
            logging.warning("Event received without 'data.url'. Skipping.")
            return

        blob_url = urllib.parse.unquote(raw_blob_url.split("?")[0])
        content_length = data.get("contentLength", 0)
        content_type = data.get("contentType", "unknown")

        logging.info(
            f"File detected: {blob_url} | Size: {content_length} bytes | Type: {content_type}"
        )

        # Ingest file into PostgreSQL
        ingest_file_to_postgresql(blob_url=blob_url, file_size=content_length)

        logging.info(f"PostgreSQL ingestion completed successfully for: {blob_url}")

    except Exception as exc:
        logging.error(f"Error processing message {msg_id}: {str(exc)}", exc_info=True)
        # Re-raise to trigger Azure Functions retry (up to maxDequeueCount)
        raise exc


def get_postgres_connection():
    """Establish and return connection to Azure Database for PostgreSQL Flexible Server."""
    return psycopg2.connect(
        host=PG_HOST,
        port=PG_PORT,
        dbname=PG_DATABASE,
        user=PG_USER,
        password=PG_PASSWORD,
        sslmode=PG_SSLMODE
    )


def ingest_file_to_postgresql(blob_url: str, file_size: int) -> None:
    """
    Streams file directly from Azure Blob Storage into PostgreSQL table
    using PostgreSQL's high-speed native COPY command.
    """
    logging.info(f"Starting PostgreSQL bulk ingestion for: {blob_url}")

    # Initialize Blob client using Managed Identity or storage connection
    storage_connection_str = os.getenv("AzureWebJobsStorage")
    if storage_connection_str and "UseDevelopmentStorage" not in storage_connection_str:
        blob_client = BlobClient.from_blob_url(blob_url, credential=None)
    else:
        # Falls back to DefaultAzureCredential (Managed Identity / Azure CLI auth)
        blob_client = BlobClient.from_blob_url(blob_url, credential=DefaultAzureCredential())

    file_extension = os.path.splitext(blob_url)[1].lower()

    with get_postgres_connection() as conn:
        with conn.cursor() as cursor:
            if file_extension in [".csv", ".txt"]:
                # High-speed stream: Stream CSV directly into Postgres via COPY FROM STDIN
                logging.info(f"Streaming CSV blob directly into PostgreSQL table: {TARGET_TABLE}")
                blob_stream = blob_client.download_blob().chunks()

                # Using string buffer / generator for copy_expert
                copy_sql = f"COPY {TARGET_TABLE} FROM STDIN WITH (FORMAT csv, HEADER true, DELIMITER ',');"
                
                # Download blob stream into in-memory stream for fast loading
                blob_data = blob_client.download_blob().readall()
                csv_buffer = io.StringIO(blob_data.decode("utf-8"))
                cursor.copy_expert(sql=copy_sql, file=csv_buffer)

            elif file_extension in [".parquet"]:
                # Parquet file ingestion using pyarrow
                logging.info(f"Parsing Parquet blob and ingesting into PostgreSQL table: {TARGET_TABLE}")
                import pyarrow.parquet as pq

                blob_data = blob_client.download_blob().readall()
                parquet_buffer = io.BytesIO(blob_data)
                table = pq.read_table(parquet_buffer)
                df = table.to_pandas()

                # Convert DataFrame to in-memory CSV buffer for native COPY
                csv_buffer = io.StringIO()
                df.to_csv(csv_buffer, index=False, header=False)
                csv_buffer.seek(0)

                cursor.copy_expert(
                    sql=f"COPY {TARGET_TABLE} FROM STDIN WITH (FORMAT csv, HEADER false, DELIMITER ',');",
                    file=csv_buffer
                )
            else:
                raise ValueError(f"Unsupported file format for ingestion: {file_extension}")

            conn.commit()
            logging.info(f"Data committed to PostgreSQL table '{TARGET_TABLE}'.")
