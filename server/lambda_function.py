import json
import os
import boto3
from datetime import datetime, timezone
from boto3.dynamodb.conditions import Key

dynamodb = boto3.resource("dynamodb")
TABLE_NAME = os.environ["UPTIME_TABLE_NAME"]
table = dynamodb.Table(TABLE_NAME)


def respond(status_code, body):
    return {
        "statusCode": status_code,
        "headers": {"Content-Type": "application/json"},
        "body": json.dumps(body),
    }


def epoch_to_iso(epoch: int) -> str:
    return datetime.fromtimestamp(epoch, tz=timezone.utc).isoformat()


def handle_report(body):
    """POST /report — store a single uptime session interval for a device.

    Expected payload:
        {
            "device_id": "sensor-abc",
            "from": 1743840000,   # epoch seconds — boot time
            "to":   1743926400    # epoch seconds — last seen / shutdown time
        }
    """
    device_id = body.get("device_id", "").strip()
    from_epoch = body.get("from")
    to_epoch = body.get("to")

    # Validate
    if not device_id:
        return respond(400, {"error": "device_id is required"})
    if from_epoch is None or not isinstance(from_epoch, (int, float)):
        return respond(400, {"error": "from must be a unix epoch integer"})
    if to_epoch is None or not isinstance(to_epoch, (int, float)):
        return respond(400, {"error": "to must be a unix epoch integer"})

    from_epoch = int(from_epoch)
    to_epoch = int(to_epoch)

    if to_epoch < from_epoch:
        return respond(400, {"error": "to must be >= from"})

    # Convert epochs to ISO 8601 datetimes
    from_iso = epoch_to_iso(from_epoch)
    to_iso = epoch_to_iso(to_epoch)
    uptime_seconds = to_epoch - from_epoch

    # Derive the calendar date (UTC) from the session start for easy querying.
    # Sessions that span midnight will be filed under the day they started.
    report_date = datetime.fromtimestamp(from_epoch, tz=timezone.utc).strftime("%Y-%m-%d")

    received_at = datetime.now(timezone.utc).isoformat()

    # PK: device_id  SK: from_iso (unique per boot session)
    table.put_item(Item={
        "device_id": device_id,
        "session_start": from_iso,      # sort key — ISO string sorts correctly
        "session_end": to_iso,
        "from_epoch": from_epoch,
        "to_epoch": to_epoch,
        "uptime_seconds": uptime_seconds,
        "report_date": report_date,     # denormalised for easy date filtering
        "received_at": received_at,
    })

    return respond(200, {
        "message": "report accepted",
        "device_id": device_id,
        "session_start": from_iso,
        "session_end": to_iso,
        "uptime_seconds": uptime_seconds,
        "report_date": report_date,
    })


def handle_get_device(device_id, query_params):
    """GET /devices/{device_id}/uptime — return session history for a device.

    Optional query params:
        from=YYYY-MM-DD   filter sessions starting on or after this date
        to=YYYY-MM-DD     filter sessions starting on or before this date
    """
    if not device_id:
        return respond(400, {"error": "device_id is required"})

    from_date = (query_params or {}).get("from")
    to_date = (query_params or {}).get("to")

    key_cond = Key("device_id").eq(device_id)

    if from_date and to_date:
        # session_start is ISO so lexicographic comparison works correctly
        key_cond = key_cond & Key("session_start").between(from_date, to_date + "T23:59:59+00:00")
    elif from_date:
        key_cond = key_cond & Key("session_start").gte(from_date)
    elif to_date:
        key_cond = key_cond & Key("session_start").lte(to_date + "T23:59:59+00:00")

    result = table.query(
        KeyConditionExpression=key_cond,
        ScanIndexForward=False,  # newest first
    )

    sessions = result["Items"]
    total_uptime = sum(int(s.get("uptime_seconds", 0)) for s in sessions)

    return respond(200, {
        "device_id": device_id,
        "total_uptime_seconds": total_uptime,
        "sessions": sessions,
    })


def lambda_handler(event, context):
    method = event.get("httpMethod", "")
    path = event.get("path", "")
    query_params = event.get("queryStringParameters") or {}

    try:
        if method == "POST" and path == "/report":
            body = json.loads(event.get("body") or "{}")
            return handle_report(body)

        if method == "GET" and path.startswith("/devices/"):
            parts = path.strip("/").split("/")
            if len(parts) == 3 and parts[2] == "uptime":
                return handle_get_device(parts[1], query_params)

        return respond(404, {"error": "not found"})

    except json.JSONDecodeError:
        return respond(400, {"error": "invalid JSON body"})
    except Exception as e:
        print(f"Unhandled error: {e}")
        return respond(500, {"error": "internal server error"})
