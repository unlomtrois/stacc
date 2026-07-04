//! The `net` module: TCP client sockets, the first hybrid
//! (Stacy + native) module.
//!
//! The language surface lives in net.stacy (types, methods, extern
//! declarations), spliced in at `use net;`. The extern symbols have
//! two implementations with identical value-level behavior: net_impl.c
//! joins the `zig cc` link for native builds, and the handlers below
//! serve the VM through raw Linux syscalls.
//!
//! Because externs are only declarable inside modules, a program that
//! never says `use net;` provably cannot touch the network.

const std = @import("std");
const linux = std.os.linux;
const module = @import("module.zig");
const value = @import("../compiler/value.zig");
const Value = value.Value;

pub const definition = module.Module{
    .name = "net",
    .stacy_source = @embedFile("net.stacy"),
    .native_impl = @embedFile("net_impl.c"),
    .vm_externs = &.{
        .{ .symbol = "net_connect", .handler = &vmConnect },
        .{ .symbol = "net_send", .handler = &vmSend },
        .{ .symbol = "net_recv", .handler = &vmRecv },
        .{ .symbol = "net_close", .handler = &vmClose },
    },
};

var recv_buffer: [65536]u8 = undefined;

fn failure(results: *[2]Value) u32 {
    results[0] = .{ .i64 = -1 };
    return 1;
}

/// "a.b.c.d" -> network-order sockaddr_in, or null.
fn parseIp4(host: []const u8, port: u16) ?linux.sockaddr.in {
    var octets: [4]u8 = undefined;
    var it = std.mem.splitScalar(u8, host, '.');
    var count: usize = 0;
    while (it.next()) |part| {
        if (count >= 4) return null;
        octets[count] = std.fmt.parseInt(u8, part, 10) catch return null;
        count += 1;
    }
    if (count != 4) return null;
    return .{
        .family = linux.AF.INET,
        .port = std.mem.nativeToBig(u16, port),
        .addr = std.mem.bytesToValue(u32, &octets),
    };
}

// args: [host_ptr, host_len, port] -> [fd]
fn vmConnect(args: []const Value, results: *[2]Value) u32 {
    if (args[0] != .ptr or args[1] != .i64 or args[2] != .i64) return failure(results);
    const host = args[0].ptr[0..@intCast(args[1].i64)];
    const port = std.math.cast(u16, args[2].i64) orelse return failure(results);
    const addr = parseIp4(host, port) orelse return failure(results);

    const fd_raw = linux.socket(linux.AF.INET, linux.SOCK.STREAM, 0);
    if (linux.errno(fd_raw) != .SUCCESS) return failure(results);
    const fd: linux.fd_t = @intCast(fd_raw);
    if (linux.errno(linux.connect(fd, &addr, @sizeOf(linux.sockaddr.in))) != .SUCCESS) {
        _ = linux.close(fd);
        return failure(results);
    }
    results[0] = .{ .i64 = fd };
    return 1;
}

// args: [fd, data_ptr, data_len] -> [sent or -1]
fn vmSend(args: []const Value, results: *[2]Value) u32 {
    if (args[0] != .i64 or args[1] != .ptr or args[2] != .i64) return failure(results);
    const fd: linux.fd_t = @intCast(args[0].i64);
    const data = args[1].ptr[0..@intCast(args[2].i64)];
    var total: usize = 0;
    while (total < data.len) {
        const sent = linux.sendto(fd, data.ptr + total, data.len - total, 0, null, 0);
        if (linux.errno(sent) != .SUCCESS or sent == 0) return failure(results);
        total += sent;
    }
    results[0] = .{ .i64 = @intCast(total) };
    return 1;
}

// args: [fd] -> [ptr, len] ("" on error or close)
fn vmRecv(args: []const Value, results: *[2]Value) u32 {
    results[0] = .{ .ptr = &recv_buffer };
    results[1] = .{ .i64 = 0 };
    if (args[0] != .i64) return 2;
    const fd: linux.fd_t = @intCast(args[0].i64);
    const n = linux.recvfrom(fd, &recv_buffer, recv_buffer.len, 0, null, null);
    if (linux.errno(n) == .SUCCESS and n > 0) {
        results[1] = .{ .i64 = @intCast(n) };
    }
    return 2;
}

// args: [fd] -> [0 or -1]
fn vmClose(args: []const Value, results: *[2]Value) u32 {
    if (args[0] != .i64) return failure(results);
    const fd: linux.fd_t = @intCast(args[0].i64);
    results[0] = .{ .i64 = if (linux.errno(linux.close(fd)) == .SUCCESS) 0 else -1 };
    return 1;
}

// ── tests ──────────────────────────────────────────────────────────

test "parseIp4" {
    const addr = parseIp4("127.0.0.1", 80).?;
    try std.testing.expectEqual(std.mem.nativeToBig(u16, 80), addr.port);
    try std.testing.expectEqual(std.mem.bytesToValue(u32, &[4]u8{ 127, 0, 0, 1 }), addr.addr);
    try std.testing.expect(parseIp4("localhost", 80) == null);
    try std.testing.expect(parseIp4("1.2.3", 80) == null);
    try std.testing.expect(parseIp4("1.2.3.4.5", 80) == null);
}

test "end to end: a Stacy program talks to a real TCP listener (VM)" {
    const compiler = @import("../compiler/compiler.zig");

    // a listener on an ephemeral port; connect completes against the
    // SYN backlog and small sends fit kernel buffers, so a single
    // thread suffices
    const listen_raw = linux.socket(linux.AF.INET, linux.SOCK.STREAM, 0);
    try std.testing.expect(linux.errno(listen_raw) == .SUCCESS);
    const listen_fd: linux.fd_t = @intCast(listen_raw);
    defer _ = linux.close(listen_fd);

    var addr = parseIp4("127.0.0.1", 0).?;
    try std.testing.expect(linux.errno(linux.bind(listen_fd, @ptrCast(&addr), @sizeOf(linux.sockaddr.in))) == .SUCCESS);
    var addr_len: linux.socklen_t = @sizeOf(linux.sockaddr.in);
    try std.testing.expect(linux.errno(linux.getsockname(listen_fd, @ptrCast(&addr), &addr_len)) == .SUCCESS);
    const port = std.mem.bigToNative(u16, addr.port);
    try std.testing.expect(linux.errno(linux.listen(listen_fd, 1)) == .SUCCESS);

    const allocator = std.testing.allocator;
    const src = try std.fmt.allocPrint(allocator,
        \\use net;
        \\let s = net_connect("127.0.0.1", {d});
        \\print(s.ok());
        \\print(s.send("ping from stacy"));
        \\print(s.close());
    , .{port});
    defer allocator.free(src);

    var aw = std.Io.Writer.Allocating.init(allocator);
    defer aw.deinit();
    try compiler.interpret(allocator, src, &aw.writer);
    try std.testing.expectEqualStrings("true\n15\n0\n", aw.writer.buffered());

    // the listener side must have received the bytes
    const conn_raw = linux.accept4(listen_fd, null, null, 0);
    try std.testing.expect(linux.errno(conn_raw) == .SUCCESS);
    const conn_fd: linux.fd_t = @intCast(conn_raw);
    defer _ = linux.close(conn_fd);
    var buf: [64]u8 = undefined;
    const n = linux.recvfrom(conn_fd, &buf, buf.len, 0, null, null);
    try std.testing.expect(linux.errno(n) == .SUCCESS);
    try std.testing.expectEqualStrings("ping from stacy", buf[0..n]);
}

test "connect to a dead port fails as a value, not an error" {
    const compiler = @import("../compiler/compiler.zig");
    const allocator = std.testing.allocator;
    var aw = std.Io.Writer.Allocating.init(allocator);
    defer aw.deinit();
    try compiler.interpret(allocator,
        \\use net;
        \\let s = net_connect("127.0.0.1", 1);
        \\print(s.ok());
        \\let bad = net_connect("not an ip", 80);
        \\print(bad.fd);
    , &aw.writer);
    try std.testing.expectEqualStrings("false\n-1\n", aw.writer.buffered());
}
