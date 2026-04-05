# Uptime Reporter

Lambda + DynamoDB solution for collecting uptime session reports from client devices.

## Architecture

```
[Device]
  uptime_tracker.sh  (hourly cron) → /var/lib/uptime/sessions.log
  report_uptime.sh   (daily cron)  → POST https://<api>/prod/report
                                          ↓
                                   [API Gateway]
                                          ↓
                                   [Lambda Function]
                                   (converts epochs → ISO 8601)
                                          ↓
                                   [DynamoDB Table]
                                   PK: device_id  SK: session_start
```

## How uptime tracking works

Each device tracks uptime as boot session intervals. The hourly tracker records
when the device booted (derived from `/proc/uptime`) and updates the session's
end time each hour. If the device is powered off suddenly, the last hourly
snapshot is used as the end of that session.

Sessions are stored locally in `/var/lib/uptime/sessions.log`:

```
# format: <boot_epoch> <last_seen_epoch>
1743840000 1743883200
1743900000 1743926400
```

When reporting, each session is sent as a separate payload:

```json
{
  "device_id": "sensor-living-room",
  "from": 1743840000,
  "to": 1743883200
}
```

The server converts the epoch values to ISO 8601 datetimes, calculates
`uptime_seconds`, and derives `report_date` (UTC) from the session start.

## Deploy the server

Requires [AWS SAM CLI](https://docs.aws.amazon.com/serverless-application-model/latest/developerguide/install-sam-cli.html).

```sh
cd server
sam build
sam deploy --guided
```

After deploy, note the `ApiEndpoint` output and create an API key in the AWS console
(API Gateway → API Keys → Create), then associate it with the usage plan named `uptime-plan`.

## Configure the client

Copy both scripts to the device and make them executable:

```sh
chmod +x uptime_tracker.sh report_uptime.sh
```

Set environment variables (add to `/etc/environment` or a sourced profile):

```sh
export SERVER_URL="https://<api-id>.execute-api.<region>.amazonaws.com/prod/report"
export DEVICE_ID="sensor-living-room"   # unique per device
export API_KEY="your-api-gateway-key"
```

Add cron entries (`crontab -e`):

```cron
# Record uptime session snapshot every hour
0 * * * * /opt/uptime_tracker.sh >> /var/log/uptime.log 2>&1

# Send pending session reports at 06:30 UTC (also flushes backlog from offline days)
30 6 * * * /opt/report_uptime.sh >> /var/log/uptime.log 2>&1
```

## Query uptime history

```sh
# All sessions for a device (newest first)
curl -H "x-api-key: <key>" \
  https://<api>/prod/devices/sensor-living-room/uptime

# Filter by date range (based on session start date)
curl -H "x-api-key: <key>" \
  "https://<api>/prod/devices/sensor-living-room/uptime?from=2026-03-01&to=2026-03-31"
```

Response includes individual sessions and a total uptime sum:

```json
{
  "device_id": "sensor-living-room",
  "total_uptime_seconds": 123600,
  "sessions": [
    {
      "device_id": "sensor-living-room",
      "session_start": "2026-04-05T00:00:00+00:00",
      "session_end": "2026-04-05T12:00:00+00:00",
      "from_epoch": 1743811200,
      "to_epoch": 1743854400,
      "uptime_seconds": 43200,
      "report_date": "2026-04-05",
      "received_at": "2026-04-05T06:30:12+00:00"
    }
  ]
}
```

## DynamoDB table structure

| device_id (PK)     | session_start (SK)           | session_end                  | uptime_seconds | report_date |
|--------------------|------------------------------|------------------------------|----------------|-------------|
| sensor-living-room | 2026-04-04T08:00:00+00:00    | 2026-04-04T22:23:20+00:00    | 51800          | 2026-04-04  |
| sensor-living-room | 2026-04-05T00:00:00+00:00    | 2026-04-05T12:00:00+00:00    | 43200          | 2026-04-05  |
