const std = @import("std");
const http = std.http;
const mem = std.mem;
const fs = std.fs;

const UploadsDir = "uploads";
const IndexHtml = @embedFile("index.html");

fn getExtension(content_type: []const u8) []const u8 {
    const types = [_]struct { []const u8, []const u8 }{
        .{ "image/jpeg", ".jpg" },
        .{ "image/png", ".png" },
        .{ "image/gif", ".gif" },
        .{ "image/webp", ".webp" },
        .{ "image/svg+xml", ".svg" },
    };
    for (types) |t| {
        if (mem.eql(u8, content_type, t[0])) return t[1];
    }
    return ".bin";
}

fn parseMultipartContent(allocator: mem.Allocator, data: []const u8, boundary: []const u8) !?[]const u8 {
    var start_marker: [128]u8 = undefined;
    const start_marker_len = try std.fmt.bufPrint(&start_marker, "--{s}", .{boundary});

    var permanent_upload = false;
    var file_data: ?[]const u8 = null;
    var content_type: []const u8 = "application/octet-stream";

    var pos: usize = 0;
    while (pos < data.len) {
        const newline_pos = mem.indexOf(u8, data[pos..], "\r\n") orelse break;
        const line = data[pos .. pos + newline_pos];

        if (mem.startsWith(u8, line, start_marker_len)) {
            pos += newline_pos + 2;

            var header_end = pos;
            while (header_end < data.len - 3) {
                if (mem.startsWith(u8, data[header_end..], "\r\n\r\n")) break;
                header_end += 1;
            }
            if (header_end >= data.len - 3) break;

            const headers = data[pos .. header_end + 2];
            const body_start = header_end + 4;

            var field_name: []const u8 = "";
            const name_start = mem.indexOf(u8, headers, "name=\"");
            if (name_start) |ns| {
                const val_start = ns + 6;
                const val_end = mem.indexOf(u8, headers[val_start..], "\"") orelse 0;
                field_name = headers[val_start .. val_start + val_end];
            }

            const ct_start = mem.indexOf(u8, headers, "Content-Type: ");
            if (ct_start) |cts| {
                const ct_val_start = cts + 14;
                const ct_val_end = mem.indexOf(u8, headers[ct_val_start..], "\r\n") orelse (headers.len - ct_val_start);
                content_type = headers[ct_val_start .. ct_val_start + ct_val_end];
            }

            var body_end = body_start;
            while (body_end < data.len - start_marker_len.len - 2) {
                if (mem.startsWith(u8, data[body_end..], "\r\n--")) {
                    if (mem.startsWith(u8, data[body_end + 2 ..], start_marker_len)) {
                        break;
                    }
                }
                body_end += 1;
            }

            const body_content = data[body_start..body_end];

            if (mem.eql(u8, field_name, "permanent")) {
                permanent_upload = mem.indexOf(u8, body_content, "true") != null;
            } else if (mem.eql(u8, field_name, "file")) {
                file_data = body_content;
            }

            pos = body_end + 2;
            continue;
        }
        pos += newline_pos + 2;
    }

    if (file_data) |fd| {
        if (fd.len == 0) return null;

        const timestamp = std.time.timestamp();
        const ext = getExtension(content_type);

        const filename = if (permanent_upload)
            try std.fmt.allocPrint(allocator, "{d}-permanent{s}", .{ timestamp, ext })
        else
            try std.fmt.allocPrint(allocator, "{d}{s}", .{ timestamp, ext });

        const filepath = try std.fmt.allocPrint(allocator, "{s}/{s}", .{ UploadsDir, filename });

        const file = fs.cwd().createFile(filepath, .{}) catch |err| {
            allocator.free(filename);
            allocator.free(filepath);
            return err;
        };
        defer file.close();
        try file.writeAll(fd);

        return filename;
    }
    return null;
}

const Server = struct {
    allocator: mem.Allocator,

    fn handleRequest(self: *Server, req: *http.Server.Request) !void {
        const method = req.head.method;
        const target = req.head.target;

        if (method == .GET and mem.eql(u8, target, "/")) {
            try req.respond(IndexHtml, .{
                .status = .ok,
                .extra_headers = &.{
                    .{ .name = "Content-Type", .value = "text/html" },
                },
            });
            return;
        }

        if (mem.eql(u8, target, "/upload") or mem.startsWith(u8, target, "/upload")) {
            if (method == .POST) {
                const content_type_h = req.head.content_type orelse "";
                const boundary_start = mem.indexOf(u8, content_type_h, "boundary=");
                if (boundary_start) |bs| {
                    const boundary = content_type_h[bs + 9 ..];

                    const body = try (try req.reader()).readAllAlloc(self.allocator, 10_000_000);
                    defer self.allocator.free(body);

                    if (try parseMultipartContent(self.allocator, body, boundary)) |filename| {
                        defer self.allocator.free(filename);

                        const json_response = try std.fmt.allocPrint(self.allocator, "{{\"success\":true,\"filename\":\"{s}\"}}", .{filename});
                        defer self.allocator.free(json_response);

                        try req.respond(json_response, .{
                            .status = .ok,
                            .extra_headers = &.{
                                .{ .name = "Content-Type", .value = "application/json" },
                                .{ .name = "Access-Control-Allow-Origin", .value = "*" },
                            },
                        });
                        return;
                    }
                }

                try req.respond("{\"success\":false,\"error\":1}", .{
                    .status = .bad_request,
                    .extra_headers = &.{
                        .{ .name = "Content-Type", .value = "application/json" },
                    },
                });
                return;
            }

            if (method == .OPTIONS) {
                try req.respond("", .{
                    .status = .ok,
                    .extra_headers = &.{
                        .{ .name = "Access-Control-Allow-Origin", .value = "*" },
                        .{ .name = "Access-Control-Allow-Methods", .value = "POST, OPTIONS" },
                        .{ .name = "Access-Control-Allow-Headers", .value = "Content-Type" },
                    },
                });
                return;
            }
        }

        if (method == .GET and mem.startsWith(u8, target, "/uploads/")) {
            const filepath = target[1..];
            const file = fs.cwd().openFile(filepath, .{}) catch {
                try req.respond("Not found", .{ .status = .not_found });
                return;
            };
            defer file.close();

            const contents = file.readToEndAlloc(self.allocator, 50_000_000) catch {
                try req.respond("Internal server error", .{ .status = .internal_server_error });
                return;
            };
            defer self.allocator.free(contents);

            const ext = std.fs.path.extension(filepath);
            var content_type: []const u8 = "application/octet-stream";
            if (mem.eql(u8, ext, ".jpg") or mem.eql(u8, ext, ".jpeg")) content_type = "image/jpeg" else if (mem.eql(u8, ext, ".png")) content_type = "image/png" else if (mem.eql(u8, ext, ".gif")) content_type = "image/gif" else if (mem.eql(u8, ext, ".webp")) content_type = "image/webp";

            try req.respond(contents, .{
                .status = .ok,
                .extra_headers = &.{
                    .{ .name = "Content-Type", .value = content_type },
                },
            });
            return;
        }

        try req.respond("Not found", .{ .status = .not_found });
    }
};

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    fs.cwd().makePath(UploadsDir) catch |err| {
        if (err != error.PathAlreadyExists) return err;
    };

    const addr = try std.net.Address.parseIp("0.0.0.0", 8081);
    var net_server = try addr.listen(.{});

    std.log.info("UpDérive server running at http://0.0.0.0:8081", .{});

    while (true) {
        const conn = net_server.accept() catch |err| {
            std.log.err("accept error: {}", .{err});
            continue;
        };

        var read_buffer: [8192]u8 = undefined;
        var http_server = http.Server.init(conn, &read_buffer);

        var request = http_server.receiveHead() catch |err| {
            std.log.err("receive head error: {}", .{err});
            continue;
        };

        var srv_instance = Server{ .allocator = allocator };
        srv_instance.handleRequest(&request) catch |err| {
            std.log.err("handle request error: {}", .{err});
        };
    }
}
