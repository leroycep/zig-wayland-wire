const std = @import("std");
const testing = std.testing;
pub const core = @import("./core.zig");
pub const xdg = @import("./xdg.zig");
pub const zxdg = @import("./zxdg.zig");

pub fn getDisplayPath(gpa: std.mem.Allocator) ![]u8 {
    const xdg_runtime_dir_path = try std.process.getEnvVarOwned(gpa, "XDG_RUNTIME_DIR");
    defer gpa.free(xdg_runtime_dir_path);
    const display_name = std.process.getEnvVarOwned(gpa, "WAYLAND_DISPLAY") catch |err| switch (err) {
        error.EnvironmentVariableNotFound => return try std.fs.path.join(gpa, &.{ xdg_runtime_dir_path, "wayland-0" }),
        else => return err,
    };
    defer gpa.free(display_name);

    return try std.fs.path.join(gpa, &.{ xdg_runtime_dir_path, display_name });
}

pub const Header = extern struct {
    object_id: u32 align(1),
    size_and_opcode: SizeAndOpcode align(1),

    pub const SizeAndOpcode = packed struct(u32) {
        opcode: u16,
        size: u16,
    };
};

test "[]u32 from header" {
    try std.testing.expectEqualSlices(
        u32,
        &[_]u32{
            1,
            (@as(u32, 12) << 16) | (4),
        },
        &@as([2]u32, @bitCast(Header{
            .object_id = 1,
            .size_and_opcode = .{
                .size = 12,
                .opcode = 4,
            },
        })),
    );
}

test "header from []u32" {
    try std.testing.expectEqualDeep(
        Header{
            .object_id = 1,
            .size_and_opcode = .{
                .size = 12,
                .opcode = 4,
            },
        },
        @as(Header, @bitCast([2]u32{
            1,
            (@as(u32, 12) << 16) | (4),
        })),
    );
}

pub fn readUInt(buffer: []const u32, parent_pos: *usize) !u32 {
    var pos = parent_pos.*;
    if (pos >= buffer.len) return error.EndOfStream;

    const uint: u32 = @bitCast(buffer[pos]);
    pos += 1;

    parent_pos.* = pos;
    return uint;
}

pub fn readInt(buffer: []const u32, parent_pos: *usize) !i32 {
    var pos = parent_pos.*;
    if (pos >= buffer.len) return error.EndOfStream;

    const int: i32 = @bitCast(buffer[pos]);
    pos += 1;

    parent_pos.* = pos;
    return int;
}

pub fn readString(buffer: []const u32, parent_pos: *usize) ![:0]const u8 {
    var pos = parent_pos.*;

    const len = try readUInt(buffer, &pos);
    const wordlen = std.mem.alignForward(usize, len, @sizeOf(u32)) / @sizeOf(u32);

    if (pos + wordlen > buffer.len) return error.EndOfStream;
    const string = std.mem.sliceAsBytes(buffer[pos..])[0 .. len - 1 :0];
    pos += std.mem.alignForward(usize, len, @sizeOf(u32)) / @sizeOf(u32);

    parent_pos.* = pos;
    return string;
}

pub fn readArray(comptime T: type, buffer: []const u32, parent_pos: *usize) ![]const T {
    var pos = parent_pos.*;

    const byte_size = try readUInt(buffer, &pos);

    const array = @as([*]const T, @ptrCast(buffer[pos..].ptr))[0 .. byte_size / @sizeOf(T)];
    pos += byte_size / @sizeOf(u32);

    parent_pos.* = pos;
    return array;
}

pub fn deserializeArguments(comptime Signature: type, buffer: []const u32) !Signature {
    if (Signature == void) return {};
    var result: Signature = undefined;
    var pos: usize = 0;
    inline for (std.meta.fields(Signature)) |field| {
        switch (@typeInfo(field.type)) {
            .Int => |int_info| switch (int_info.signedness) {
                .signed => @field(result, field.name) = try readInt(buffer, &pos),
                .unsigned => @field(result, field.name) = try readUInt(buffer, &pos),
            },
            .Enum => |enum_info| if (@sizeOf(enum_info.tag_type) == @sizeOf(u32)) {
                @field(result, field.name) = @enumFromInt(try readInt(buffer, &pos));
            } else {
                @compileError("Unsupported type " ++ @typeName(field.type));
            },
            .Pointer => |ptr| switch (ptr.size) {
                .Slice => if (ptr.child == u8) {
                    @field(result, field.name) = try readString(buffer, &pos);
                } else {
                    @field(result, field.name) = try readArray(ptr.child, buffer, &pos);
                },
                else => @compileError("Unsupported type " ++ @typeName(field.type)),
            },
            else => @compileError("Unsupported type " ++ @typeName(field.type)),
        }
    }
    return result;
}

pub fn deserialize(comptime Union: type, header: Header, buffer: []const u32) !Union {
    const op = try std.meta.intToEnum(std.meta.Tag(Union), header.size_and_opcode.opcode);
    switch (op) {
        inline else => |f| {
            const Payload = std.meta.TagPayload(Union, f);
            const payload = try deserializeArguments(Payload, buffer);
            return @unionInit(Union, @tagName(f), payload);
        },
    }
}

/// Returns the length of the serialized message in `u32` words.
pub fn calculateSerializedWordLen(comptime Signature: type, message: Signature) usize {
    var pos: usize = 0;
    inline for (std.meta.fields(Signature)) |field| {
        switch (@typeInfo(field.type)) {
            .Int => pos += 1,
            .Pointer => |ptr| switch (ptr.size) {
                .Slice => {
                    // for size of string in bytes
                    pos += 1;

                    const str = @field(message, field.name);
                    pos += std.mem.alignForward(usize, str.len + 1, @sizeOf(u32)) / @sizeOf(u32);
                },
                else => @compileError("Unsupported type " ++ @typeName(field.type)),
            },
            else => @compileError("Unsupported type " ++ @typeName(field.type)),
        }
    }
    return pos;
}

/// Message must live until the iovec array is written.
pub fn serializeArguments(comptime Signature: type, buffer: []u32, message: Signature) ![]u32 {
    if (Signature == void) return buffer[0..0];
    var pos: usize = 0;
    inline for (std.meta.fields(Signature)) |field| {
        switch (@typeInfo(field.type)) {
            .Int => {
                if (pos >= buffer.len) return error.OutOfMemory;
                buffer[pos] = @bitCast(@field(message, field.name));
                pos += 1;
            },
            .Enum => |enum_info| if (enum_info.tag_type == u32) {
                if (pos >= buffer.len) return error.OutOfMemory;
                buffer[pos] = @intFromEnum(@field(message, field.name));
                pos += 1;
            } else {
                @compileError("Unsupported type " ++ @typeName(field.type));
            },
            .Pointer => |ptr| switch (ptr.size) {
                .Slice => {
                    const str = @field(message, field.name);
                    if (str.len >= std.math.maxInt(u32)) return error.StringTooLong;

                    buffer[pos] = @intCast(str.len + 1);
                    pos += 1;

                    const str_len_aligned = std.mem.alignForward(usize, str.len + 1, @sizeOf(u32));
                    const padding_len = str_len_aligned - str.len;
                    if (str_len_aligned / @sizeOf(u32) >= buffer[pos..].len) return error.OutOfMemory;
                    const buffer_bytes = std.mem.sliceAsBytes(buffer[pos..]);
                    @memcpy(buffer_bytes[0..str.len], str);
                    @memset(buffer_bytes[str.len..][0..padding_len], 0);
                    pos += str_len_aligned / @sizeOf(u32);
                },
                else => @compileError("Unsupported type " ++ @typeName(field.type)),
            },
            else => @compileError("Unsupported type " ++ @typeName(field.type)),
        }
    }
    return buffer[0..pos];
}

pub fn serialize(comptime Union: type, buffer: []u32, object_id: u32, message: Union) ![]u32 {
    const header_wordlen = @sizeOf(Header) / @sizeOf(u32);
    const header: *Header = @ptrCast(buffer[0..header_wordlen]);
    header.object_id = object_id;

    const tag = std.meta.activeTag(message);
    header.size_and_opcode.opcode = @intFromEnum(tag);

    const arguments = switch (message) {
        inline else => |payload| try serializeArguments(@TypeOf(payload), buffer[header_wordlen..], payload),
    };

    header.size_and_opcode.size = @intCast(@sizeOf(Header) + arguments.len * @sizeOf(u32));
    return buffer[0 .. header.size_and_opcode.size / @sizeOf(u32)];
}

test "deserialize Registry.Event.Global" {
    const words = [_]u32{
        1,
        7,
        @bitCast(@as([4]u8, "wl_s".*)),
        @bitCast(@as([4]u8, "hm\x00\x00".*)),
        3,
    };
    const parsed = try deserializeArguments(core.Registry.Event.Global, &words);
    try std.testing.expectEqualDeep(core.Registry.Event.Global{
        .name = 1,
        .interface = "wl_shm",
        .version = 3,
    }, parsed);
}

test "deserialize Registry.Event" {
    const header = Header{
        .object_id = 123,
        .size_and_opcode = .{
            .size = 28,
            .opcode = @intFromEnum(core.Registry.Event.Tag.global),
        },
    };
    const words = [_]u32{
        1,
        7,
        @bitCast(@as([4]u8, "wl_s".*)),
        @bitCast(@as([4]u8, "hm\x00\x00".*)),
        3,
    };
    const parsed = try deserialize(core.Registry.Event, header, &words);
    try std.testing.expectEqualDeep(
        core.Registry.Event{
            .global = .{
                .name = 1,
                .interface = "wl_shm",
                .version = 3,
            },
        },
        parsed,
    );

    const header2 = Header{
        .object_id = 1,
        .size_and_opcode = .{
            .size = 14 * @sizeOf(u32),
            .opcode = @intFromEnum(core.Display.Event.Tag.@"error"),
        },
    };
    const words2 = [_]u32{
        1,
        15,
        40,
        @bitCast(@as([4]u8, "inva".*)),
        @bitCast(@as([4]u8, "lid ".*)),
        @bitCast(@as([4]u8, "argu".*)),
        @bitCast(@as([4]u8, "ment".*)),
        @bitCast(@as([4]u8, "s to".*)),
        @bitCast(@as([4]u8, " wl_".*)),
        @bitCast(@as([4]u8, "regi".*)),
        @bitCast(@as([4]u8, "stry".*)),
        @bitCast(@as([4]u8, "@2.b".*)),
        @bitCast(@as([4]u8, "ind\x00".*)),
    };
    const parsed2 = try deserialize(core.Display.Event, header2, &words2);
    try std.testing.expectEqualDeep(
        core.Display.Event{
            .@"error" = .{
                .object_id = 1,
                .code = 15,
                .message = "invalid arguments to wl_registry@2.bind",
            },
        },
        parsed2,
    );
}

test "serialize Registry.Event.Global" {
    const message = core.Registry.Event.Global{
        .name = 1,
        .interface = "wl_shm",
        .version = 3,
    };
    var buffer: [5]u32 = undefined;
    const serialized = try serializeArguments(core.Registry.Event.Global, &buffer, message);

    try std.testing.expectEqualSlices(
        u32,
        &[_]u32{
            1,
            7,
            @bitCast(@as([4]u8, "wl_s".*)),
            @bitCast(@as([4]u8, "hm\x00\x00".*)),
            3,
        },
        serialized,
    );
}

pub const IdPool = struct {
    next_id: u32 = 2,
    free_ids: std.BoundedArray(u32, 1024) = .{},

    pub fn create(this: *@This()) u32 {
        if (this.free_ids.popOrNull()) |id| {
            return id;
        }

        defer this.next_id += 1;
        return this.next_id;
    }

    pub fn destroy(this: *@This(), id: u32) void {
        for (this.free_ids.slice()) |existing_id| {
            if (existing_id == id) return;
        }
        this.free_ids.append(id) catch {};
    }
};

pub fn registerGlobals(alloc: std.mem.Allocator, id_pool: *IdPool, socket: std.net.Stream, comptime T: []const type) ![T.len]?u32 {
    const Item = struct { version: u32, index: u32 };
    const Pair = struct { []const u8, Item };
    comptime var kvs_list: []const Pair = &[_]Pair{};
    inline for (T, 0..) |t, i| {
        kvs_list = kvs_list ++ &[_]Pair{.{ t.INTERFACE, .{ .version = t.VERSION, .index = i } }};
    }
    const map = std.ComptimeStringMap(Item, kvs_list);

    const registry_id = id_pool.create();
    {
        var buffer: [5]u32 = undefined;
        const message = try serialize(core.Display.Request, &buffer, 1, .{ .get_registry = .{ .registry = registry_id } });
        try socket.writeAll(std.mem.sliceAsBytes(message));
    }

    const registry_done_id = id_pool.create();
    {
        var buffer: [5]u32 = undefined;
        const message = try serialize(core.Display.Request, &buffer, 1, .{ .sync = .{ .callback = registry_done_id } });
        try socket.writeAll(std.mem.sliceAsBytes(message));
    }

    var ids: [T.len]?u32 = [_]?u32{null} ** T.len;
    var message_buffer = std.ArrayList(u32).init(alloc);
    defer message_buffer.deinit();
    while (true) {
        var header: Header = undefined;
        const header_bytes_read = try socket.readAll(std.mem.asBytes(&header));
        if (header_bytes_read < @sizeOf(Header)) break;

        try message_buffer.resize((header.size_and_opcode.size - @sizeOf(Header)) / @sizeOf(u32));
        const bytes_read = try socket.readAll(std.mem.sliceAsBytes(message_buffer.items));
        message_buffer.shrinkRetainingCapacity(bytes_read / @sizeOf(u32));

        if (header.object_id == registry_id) {
            const event = try deserialize(core.Registry.Event, header, message_buffer.items);
            switch (event) {
                .global => |global| {
                    var buffer: [20]u32 = undefined;
                    if (map.get(global.interface)) |item| {
                        const new_id = id_pool.create();
                        ids[item.index] = new_id;
                        const message = try serialize(core.Registry.Request, &buffer, registry_id, .{ .bind = .{
                            .name = global.name,
                            .interface = global.interface,
                            .version = item.version,
                            .new_id = new_id,
                        } });
                        try socket.writeAll(std.mem.sliceAsBytes(message));
                    }
                },
                .global_remove => {},
            }
        } else if (header.object_id == registry_done_id) {
            break;
        } else {
            std.log.info("{} {x} \"{}\"", .{
                header.object_id,
                header.size_and_opcode.opcode,
                std.zig.fmtEscapes(std.mem.sliceAsBytes(message_buffer.items)),
            });
        }
    }

    return ids;
}

pub const Conn = struct {
    allocator: std.mem.Allocator,
    send_buffer: []u32,
    recv_buffer: []u32,
    socket: std.net.Stream,

    pub fn init(alloc: std.mem.Allocator, display_path: []const u8) !Conn {
        const send_buffer = try alloc.alloc(u32, 16);
        const recv_buffer = try alloc.alloc(u32, 16);
        return .{
            .allocator = alloc,
            .send_buffer = send_buffer,
            .recv_buffer = recv_buffer,
            .socket = try std.net.connectUnixSocket(display_path),
        };
    }

    pub fn deinit(conn: *Conn) void {
        conn.allocator.free(conn.send_buffer);
        conn.allocator.free(conn.recv_buffer);
        conn.socket.close();
    }

    pub fn send(conn: *Conn, comptime Signature: type, id: u32, message: Signature) !void {
        const msg = while (true) {
            const msg = serialize(
                Signature,
                conn.send_buffer,
                id,
                message,
            ) catch |e| switch (e) {
                error.OutOfMemory => {
                    conn.send_buffer = try conn.allocator.realloc(conn.send_buffer, conn.send_buffer.len * 2);
                    continue;
                },
            };

            break msg;
        };
        try conn.socket.writeAll(std.mem.sliceAsBytes(msg));
    }

    pub const Message = struct { Header, []const u32 };
    pub fn recv(conn: *Conn) !Message {
        var header: Header = undefined;
        const header_bytes_read = try conn.socket.readAll(std.mem.asBytes(&header));
        if (header_bytes_read < @sizeOf(Header)) {
            return error.SocketClosed;
        }

        const msg_size = (header.size_and_opcode.size - @sizeOf(Header)) / @sizeOf(u32);
        if (msg_size > conn.recv_buffer.len) {
            var new_size = conn.recv_buffer.len * 2;
            while (new_size < msg_size) new_size *= 2;
            conn.recv_buffer = try conn.allocator.realloc(conn.recv_buffer, new_size);
        }
        const bytes_read = try conn.socket.readAll(std.mem.sliceAsBytes(conn.recv_buffer[0..msg_size]));
        const message = conn.recv_buffer[0 .. bytes_read / @sizeOf(u32)];

        return .{ header, message };
    }
};
