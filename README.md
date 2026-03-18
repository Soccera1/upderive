# UpDérive

A minimal HTTP server for image uploads, written in Zig.

## Features

- Single-binary HTTP server
- Image upload via multipart form data
- Serves uploaded images
- Supports JPEG, PNG, GIF, WebP, and SVG
- REST API with JSON responses

## Building

```bash
zig build
```

The binary will be output to `zig-out/bin/upderive`.

## Running

```bash
zig build run
```

Or run the installed binary directly:

```bash
./zig-out/bin/upderive
```

The server listens on `0.0.0.0:8081` by default.

## API

### HTML Interface

- `GET /` - Serves the upload page

### Upload

- `POST /upload` - Upload an image via multipart form data
  - Request: `multipart/form-data` with boundary
  - Response: `{"success": true, "filename": "<timestamp>.<ext>"}`
  - Files are saved to the `uploads/` directory

### Download

- `GET /uploads/<filename>` - Retrieve an uploaded image

## CLI Tool

A Python CLI tool (`ulderive`) is provided for uploading images from the command line.

```bash
./ulderive image.png
./ulderive photo1.jpg photo2.png -q    # quiet mode, URLs only
```

No external dependencies required (uses Python standard library).

## System Service

An OpenRC init script is provided at `init.d/upderive` (primarily for Gentoo, works on most OpenRC-based systems).

Installation:

```bash
cp init.d/upderive /etc/init.d/upderive
rc-update add upderive default
rc-service upderive start
```

## Automatic Cleanup

A cron job is provided to remove old uploads that haven't been modified in 30 days. Files with `-permanent` in the name are preserved.

Installation:

```bash
cp cron/cleanup-uploads.sh /usr/local/bin/cleanup-uploads.sh
cp cron/upderive-cleanup /etc/cron.d/upderive-cleanup
```

The cron job runs daily at 3:00 AM and logs to `/var/log/upderive-cleanup.log`.

## License

GNU Affero General Public License v3.0 - see [LICENSE](LICENSE)
