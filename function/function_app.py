import json
import logging
import os
import urllib.parse
import azure.functions as func

app = func.FunctionApp()

QUEUE_NAME = os.getenv("STORAGE_QUEUE_NAME", "file-ingestion-queue")
CONNECTION_SETTING = "AzureWebJobsStorage"


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

        # Decode URL to handle escaped characters, spaces, or query parameters
        blob_url = urllib.parse.unquote(raw_blob_url.split("?")[0])
        content_length = data.get("contentLength", 0)
        content_type = data.get("contentType", "unknown")

        logging.info(
            f"File detected: {blob_url} | Size: {content_length} bytes | Type: {content_type}"
        )

        # Execute target analytics database ingestion
        ingest_file_to_analytics_db(blob_url=blob_url, file_size=content_length)

        logging.info(f"Ingestion completed successfully for: {blob_url}")

    except Exception as exc:
        logging.error(f"Error processing message {msg_id}: {str(exc)}", exc_info=True)
        # Raising an exception signals Azure Functions to keep the message for retry.
        # After reaching maxDequeueCount (default 5 in host.json), it automatically
        # moves to the poison queue (<queue_name>-poison).
        raise exc


def ingest_file_to_analytics_db(blob_url: str, file_size: int) -> None:
    """
    Triggers the data load into the target analytics database.
    
    BEST PRACTICE:
    Use native database bulk load (e.g. COPY INTO) so compute happens inside the
    database engine in parallel without pulling massive files through Function memory.
    """
    logging.info(f"Triggering database bulk ingestion for: {blob_url}")

    # --- Scenario 1: Azure Synapse Analytics / Azure SQL / Microsoft Fabric ---
    # Example T-SQL execution:
    # sql_query = f"""
    # COPY INTO dbo.staging_landing
    # FROM '{blob_url}'
    # WITH (
    #     FILE_TYPE = 'PARQUET',
    #     CREDENTIAL = (IDENTITY = 'Managed Identity'),
    #     AUTO_CREATE_TABLE = 'OFF'
    # );
    # """

    # --- Scenario 2: Snowflake (if triggered programmatically) ---
    # sql_query = f"""
    # COPY INTO my_table
    # FROM '@my_azure_stage/{os.path.basename(blob_url)}'
    # FILE_FORMAT = (TYPE = 'PARQUET');
    # """

    # --- Scenario 3: PostgreSQL / ClickHouse / BigQuery ---
    # Stream or issue client command to load from storage.

    pass
