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

    var end_marker: [132]u8 = undefined;
    const end_marker_buf = try std.fmt.bufPrint(&end_marker, "--{s}--", .{boundary});

    var pos: usize = 0;
    while (pos < data.len) {
        const newline_pos = mem.indexOf(u8, data[pos..], "\r\n") orelse break;
        const line = data[pos .. pos + newline_pos];

        if (mem.startsWith(u8, line, start_marker_len)) {
            pos += newline_pos + 2;
            var header_end_pos = pos;
            while (header_end_pos < data.len) {
                if (mem.startsWith(u8, data[header_end_pos..], "\r\n\r\n")) {
                    break;
                }
                header_end_pos += 1;
            }

            const headers = data[pos .. header_end_pos + 2];
            const content_type_start = mem.indexOf(u8, headers, "Content-Type: ");
            var content_type: []const u8 = "application/octet-stream";
            if (content_type_start) |cts| {
                const ct_line_start = cts + 14;
                const ct_line_end = mem.indexOf(u8, headers[ct_line_start..], "\r\n") orelse (headers.len - ct_line_start);
                content_type = headers[ct_line_start .. ct_line_start + ct_line_end];
            }

            pos = header_end_pos + 4;
            var file_end = pos;
            while (file_end < data.len - end_marker_buf.len) {
                if (mem.startsWith(u8, data[file_end..], end_marker_buf)) {
                    break;
                }
                file_end += 1;
            }
            while (file_end > pos and (data[file_end - 1] == '\r' or data[file_end - 1] == '\n')) {
                file_end -= 1;
            }

            const file_data = data[pos..file_end];
            if (file_data.len == 0) continue;

            const timestamp = std.time.timestamp();
            const ext = getExtension(content_type);
            const filename = try std.fmt.allocPrint(allocator, "{d}{s}", .{ timestamp, ext });
            const filepath = try std.fmt.allocPrint(allocator, "{s}/{s}", .{ UploadsDir, filename });

            const file = fs.cwd().createFile(filepath, .{}) catch |err| {
                allocator.free(filename);
                allocator.free(filepath);
                return err;
            };
            defer file.close();
            try file.writeAll(file_data);

            return filename;
        }
        pos += newline_pos + 2;
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
