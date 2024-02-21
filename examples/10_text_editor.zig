const std = @import("std");
const wayland = @import("wayland");
const xkbcommon = wayland.xkbcommon;
const font8x8 = @cImport({
    @cInclude("font8x8.h");
});
const PieceTable = @import("PieceTable.zig").PieceTable;

const Pixel = [4]u8;
const Theme = struct {
    const background = 0x282A36;
    const current_line = 0x44475A;
    const foreground = 0xF8F8F2;
    const comment = 0x6272A4;

    const cyan = 0x8BE9FD;
    const green = 0x50FA7B;
    const orange = 0xFFB86C;
    const pink = 0xFF79C6;
    const purple = 0xBD93F9;
    const red = 0xFF5555;
    const yellow = 0xF1FA8C;
};

fn toPixel(color: u24) Pixel {
    return .{
        @intCast(color & 0xFF),
        @intCast(color >> 8 & 0xFF),
        @intCast(color >> 16 & 0xFF),
        0xFF,
    };
}

pub fn main() !void {
    var general_allocator = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = general_allocator.deinit();
    const gpa = general_allocator.allocator();

    const display_path = try wayland.getDisplayPath(gpa);
    defer gpa.free(display_path);

    var conn = try wayland.Conn.init(gpa, display_path);
    defer conn.deinit();

    // Create an id pool to allocate ids for us
    var id_pool = wayland.IdPool{};

    const ids = try wayland.registerGlobals(gpa, &id_pool, conn.socket, &.{
        wayland.core.Shm,
        wayland.core.Compositor,
        wayland.xdg.WmBase,
        wayland.core.Seat,
        wayland.zxdg.DecorationManagerV1,
        wayland.zwp.TextInputManagerV3,
    });

    const DISPLAY_ID = 1;
    const shm_id = ids[0] orelse return error.NeccessaryWaylandExtensionMissing;
    const compositor_id = ids[1] orelse return error.NeccessaryWaylandExtensionMissing;
    const xdg_wm_base_id = ids[2] orelse return error.NeccessaryWaylandExtensionMissing;
    const wl_seat_id = ids[3] orelse return error.NeccessaryWaylandExtensionMissing;
    const zwp_text_input_manager_v3 = ids[5] orelse return error.NeccessaryWaylandExtensionMissing;

    const surface_id = id_pool.create();
    try conn.send(
        wayland.core.Compositor.Request,
        compositor_id,
        .{ .create_surface = .{
            .new_id = surface_id,
        } },
    );

    const xdg_surface_id = id_pool.create();
    try conn.send(
        wayland.xdg.WmBase.Request,
        xdg_wm_base_id,
        .{ .get_xdg_surface = .{
            .id = xdg_surface_id,
            .surface = surface_id,
        } },
    );

    const xdg_toplevel_id = id_pool.create();
    try conn.send(
        wayland.xdg.Surface.Request,
        xdg_surface_id,
        .{ .get_toplevel = .{
            .id = xdg_toplevel_id,
        } },
    );

    const zwp_text_input_v3_id = id_pool.create();
    try conn.send(
        wayland.zwp.TextInputManagerV3.Request,
        zwp_text_input_manager_v3,
        .{ .get_text_input = .{
            .id = zwp_text_input_v3_id,
            .seat = wl_seat_id,
        } },
    );

    var zxdg_toplevel_decoration_id_opt: ?u32 = null;
    if (ids[4]) |zxdg_decoration_manager_id| {
        zxdg_toplevel_decoration_id_opt = id_pool.create();
        try conn.send(
            wayland.zxdg.DecorationManagerV1.Request,
            zxdg_decoration_manager_id,
            .{ .get_toplevel_decoration = .{
                .new_id = zxdg_toplevel_decoration_id_opt.?,
                .toplevel = xdg_toplevel_id,
            } },
        );
    }

    try conn.send(
        wayland.core.Surface.Request,
        surface_id,
        wayland.core.Surface.Request.commit,
    );

    const registry_done_id = id_pool.create();
    try conn.send(
        wayland.core.Display.Request,
        DISPLAY_ID,
        .{ .sync = .{ .callback = registry_done_id } },
    );

    var done = false;
    var surface_configured = false;
    var seat_capabilties: ?wayland.core.Seat.Capability = null;
    while (!done or !surface_configured) {
        const header, const body = try conn.recv();

        if (header.object_id == xdg_surface_id) {
            const event = try wayland.deserialize(wayland.xdg.Surface.Event, header, body);
            switch (event) {
                .configure => |conf| {
                    try conn.send(
                        wayland.xdg.Surface.Request,
                        xdg_surface_id,
                        .{ .ack_configure = .{
                            .serial = conf.serial,
                        } },
                    );
                    surface_configured = true;
                },
            }
        } else if (zxdg_toplevel_decoration_id_opt != null and header.object_id == zxdg_toplevel_decoration_id_opt.?) {
            const event = try wayland.deserialize(wayland.zxdg.ToplevelDecorationV1.Event, header, body);
            std.debug.print("<- zxdg_toplevel_decoration@{}\n", .{event});
        } else if (header.object_id == xdg_toplevel_id) {
            const event = try wayland.deserialize(wayland.xdg.Toplevel.Event, header, body);
            std.debug.print("<- {}\n", .{event});
        } else if (header.object_id == registry_done_id) {
            done = true;
        } else if (header.object_id == shm_id) {
            const event = try wayland.deserialize(wayland.core.Shm.Event, header, body);
            switch (event) {
                .format => |format| std.debug.print("<- format {} {}\n", .{ format.format, std.zig.fmtEscapes(std.mem.asBytes(&format.format)) }),
            }
        } else if (header.object_id == wl_seat_id) {
            const event = try wayland.deserialize(wayland.core.Seat.Event, header, body);
            switch (event) {
                .capabilities => |capabilities| {
                    const cap: wayland.core.Seat.Capability = @bitCast(capabilities.capability);
                    std.debug.print("<- wl_seat.capabilties = {}\n", .{cap});
                    seat_capabilties = cap;
                },
                .name => |name| {
                    std.debug.print("<- wl_seat.name = {s}\n", .{name.name});
                },
            }
        } else if (header.object_id == DISPLAY_ID) {
            const event = try wayland.deserialize(wayland.core.Display.Event, header, body);
            switch (event) {
                .@"error" => |err| std.debug.print("<- error({}): {} {s}\n", .{ err.object_id, err.code, err.message }),
                .delete_id => |id| {
                    std.debug.print("id {} deleted\n", .{id});
                    id_pool.destroy(id.id);
                },
            }
        } else {
            std.debug.print("{} {x} \"{}\"\n", .{ header.object_id, header.size_and_opcode.opcode, std.zig.fmtEscapes(std.mem.sliceAsBytes(body)) });
        }
    }

    var wl_pointer_id_opt: ?u32 = null;
    var wl_keyboard_id_opt: ?u32 = null;
    if (seat_capabilties) |caps| {
        if (caps.pointer) {
            wl_pointer_id_opt = id_pool.create();
            std.debug.print("wl pointer id: {}\n", .{wl_pointer_id_opt.?});
            try conn.send(
                wayland.core.Seat.Request,
                wl_seat_id,
                .{ .get_pointer = .{
                    .new_id = wl_pointer_id_opt.?,
                } },
            );
        }
        if (caps.keyboard) {
            wl_keyboard_id_opt = id_pool.create();
            std.debug.print("wl keyboard id: {}\n", .{wl_keyboard_id_opt.?});
            try conn.send(
                wayland.core.Seat.Request,
                wl_seat_id,
                .{ .get_keyboard = .{
                    .new_id = wl_keyboard_id_opt.?,
                } },
            );
        }
    }
    const wl_pointer_id = wl_pointer_id_opt orelse return error.MissingPointer;
    const wl_keyboard_id = wl_keyboard_id_opt orelse return error.MissingKeyboard;

    // allocate a shared memory file for display purposes
    const framebuffer_size = [2]u32{ 128, 128 };
    const pool_file_len = 1024 * framebuffer_size[0] * framebuffer_size[1] * @sizeOf(Pixel);

    const pool_fd = try std.os.memfd_create("my-wayland-framebuffer", 0);
    try std.os.ftruncate(pool_fd, pool_file_len);
    const pool_bytes = try std.os.mmap(null, pool_file_len, std.os.PROT.READ | std.os.PROT.WRITE, std.os.MAP.SHARED, pool_fd, 0);
    var pool_fixed_buffer_allocator = std.heap.FixedBufferAllocator.init(pool_bytes);
    var pool_general_purpose_allocator = std.heap.GeneralPurposeAllocator(.{}){ .backing_allocator = pool_fixed_buffer_allocator.allocator() };
    const pool_alloc = pool_general_purpose_allocator.allocator();

    const framebuffer = try pool_alloc.alloc(Pixel, framebuffer_size[0] * framebuffer_size[1]);

    // put some interesting colors into the framebuffer
    renderGradient(framebuffer, framebuffer_size);

    const wl_shm_pool_id = id_pool.create();
    {
        std.debug.print("framebuffer_fd: {}\n", .{pool_fd});
        try conn.send(
            wayland.core.Shm.Request,
            shm_id,
            .{ .create_pool = .{
                .new_id = wl_shm_pool_id,
                .fd = @enumFromInt(pool_fd),
                .size = pool_file_len,
            } },
        );
    }

    var framebuffers = std.AutoHashMap(u32, []Pixel).init(gpa);
    defer framebuffers.deinit();
    try framebuffers.put(wl_shm_pool_id, framebuffer);

    const wl_buffer_id = id_pool.create();
    try conn.send(
        wayland.core.ShmPool.Request,
        wl_shm_pool_id,
        .{ .create_buffer = .{
            .new_id = wl_buffer_id,
            .offset = 0,
            .width = framebuffer_size[0],
            .height = framebuffer_size[1],
            .stride = framebuffer_size[0] * @sizeOf([4]u8),
            .format = .argb8888,
        } },
    );

    try conn.send(
        wayland.core.Surface.Request,
        surface_id,
        .{ .attach = .{
            .buffer = wl_buffer_id,
            .x = 0,
            .y = 0,
        } },
    );

    try conn.send(
        wayland.core.Surface.Request,
        surface_id,
        .{ .damage = .{
            .x = 0,
            .y = 0,
            .width = std.math.maxInt(i32),
            .height = std.math.maxInt(i32),
        } },
    );

    try conn.send(
        wayland.core.Surface.Request,
        surface_id,
        wayland.core.Surface.Request.commit,
    );

    var window_size: [2]u32 = [2]u32{ @intCast(framebuffer_size[0]), @intCast(framebuffer_size[1]) };
    const xkb_ctx = xkbcommon.Context.new(.no_flags) orelse return error.XKBInit;
    defer xkb_ctx.unref();

    var xkb_keymap_opt: ?*xkbcommon.Keymap = null;
    defer if (xkb_keymap_opt) |xkb_keymap| {
        xkb_keymap.unref();
    };
    var xkb_state_opt: ?*xkbcommon.State = null;
    defer if (xkb_state_opt) |xkb_state| {
        xkb_state.unref();
    };

    var piece_table = try PieceTable.init(gpa, "Hello, World!");
    defer piece_table.deinit();

    var edit_buffer: [1024]u8 = [1]u8{0} ** 1024;
    var edit_slice: ?[]u8 = null;

    var delete_before: usize = 0;
    var delete_after: usize = 0;

    // var preedit_buffer: [1024]u8 = [1]u8{0} ** 1024;
    // var preedit_slice: ?[]u8 = null;

    var cursor_pos: usize = piece_table.getTotalSize();

    var running = true;
    while (running) {
        const header, const body = try conn.recv();

        if (header.object_id == xdg_surface_id) {
            const event = try wayland.deserialize(wayland.xdg.Surface.Event, header, body);
            switch (event) {
                .configure => |conf| {
                    try conn.send(
                        wayland.xdg.Surface.Request,
                        xdg_surface_id,
                        .{ .ack_configure = .{
                            .serial = conf.serial,
                        } },
                    );

                    const new_buffer_id = id_pool.create();
                    const new_framebuffer = try pool_alloc.alloc(Pixel, window_size[0] * window_size[1]);
                    try framebuffers.put(new_buffer_id, new_framebuffer);

                    // put some interesting colors into the new_framebuffer
                    renderGradient(new_framebuffer, window_size);

                    const text = try piece_table.writeAllAlloc();
                    defer gpa.free(text);
                    // blit some characters
                    renderText(new_framebuffer, window_size, .{ 10, 10 }, text);

                    try conn.send(
                        wayland.core.ShmPool.Request,
                        wl_shm_pool_id,
                        .{ .create_buffer = .{
                            .new_id = new_buffer_id,
                            .offset = @intCast(@intFromPtr(new_framebuffer.ptr) - @intFromPtr(pool_bytes.ptr)),
                            .width = @intCast(window_size[0]),
                            .height = @intCast(window_size[1]),
                            .stride = @as(i32, @intCast(window_size[0])) * @sizeOf([4]u8),
                            .format = .argb8888,
                        } },
                    );

                    try conn.send(
                        wayland.core.Surface.Request,
                        surface_id,
                        .{ .attach = .{
                            .buffer = new_buffer_id,
                            .x = 0,
                            .y = 0,
                        } },
                    );

                    try conn.send(
                        wayland.core.Surface.Request,
                        surface_id,
                        .{ .damage = .{
                            .x = 0,
                            .y = 0,
                            .width = std.math.maxInt(i32),
                            .height = std.math.maxInt(i32),
                        } },
                    );

                    // commit the configuration
                    try conn.send(
                        wayland.core.Surface.Request,
                        surface_id,
                        wayland.core.Surface.Request.commit,
                    );
                },
            }
        } else if (header.object_id == xdg_toplevel_id) {
            const event = try wayland.deserialize(wayland.xdg.Toplevel.Event, header, body);
            switch (event) {
                .configure => |conf| {
                    std.debug.print("<- xdg_toplevel@{} configure <{}, {}> {any}\n", .{ header.object_id, conf.width, conf.height, conf.states });
                    window_size = .{
                        @intCast(conf.width),
                        @intCast(conf.height),
                    };
                },
                .close => running = false,
                else => |tag| std.debug.print("<- xdg_toplevel@{} {s} {}\n", .{ header.object_id, @tagName(tag), event }),
            }
        } else if (header.object_id == xdg_wm_base_id) {
            const event = try wayland.deserialize(wayland.xdg.WmBase.Event, header, body);
            switch (event) {
                .ping => |ping| {
                    try conn.send(
                        wayland.xdg.WmBase.Request,
                        xdg_wm_base_id,
                        .{ .pong = .{
                            .serial = ping.serial,
                        } },
                    );
                },
            }
        } else if (header.object_id == wl_pointer_id) {
            const event = try wayland.deserialize(wayland.core.Pointer.Event, header, body);
            std.debug.print("<- wl_pointer@{}\n", .{event});
        } else if (header.object_id == wl_keyboard_id) {
            const event = try wayland.deserialize(wayland.core.Keyboard.Event, header, body);
            switch (event) {
                .keymap => |keymap| {
                    const fd = conn.fd_queue.orderedRemove(0);
                    std.debug.print("keymap format={}, size={}, fd={}\n", .{
                        keymap.format,
                        keymap.size,
                        fd,
                    });
                    const mem = try std.os.mmap(
                        null,
                        keymap.size,
                        std.os.PROT.READ,
                        std.os.MAP.PRIVATE,
                        fd,
                        0,
                    );
                    std.debug.print("---START xkb file---\n{s}\n---END xkb file---\n", .{mem});
                    xkb_keymap_opt = xkbcommon.Keymap.newFromString(xkb_ctx, @ptrCast(mem), .text_v1, .no_flags) orelse return error.XKBKeymap;
                    xkb_state_opt = xkbcommon.State.new(xkb_keymap_opt.?) orelse return error.XKBStateInit;
                },
                .modifiers => |mods| {
                    if (xkb_state_opt) |xkb_state| {
                        _ = xkb_state.updateMask(
                            mods.mods_depressed,
                            mods.mods_latched,
                            mods.mods_locked,
                            0,
                            0,
                            0,
                        );
                    }
                },
                .key => |key| {
                    if (xkb_state_opt) |xkb_state| {
                        const keycode: xkbcommon.Keycode = key.key + 8;
                        const keysym: xkbcommon.Keysym = xkb_state.keyGetOneSym(keycode);
                        var buf: [64]u8 = undefined;
                        // const name_len = keysym.getName(&buf, buf.len);
                        // std.debug.print("{s}\n", .{buf[0..@intCast(name_len)]});

                        if (key.state == .pressed) {
                            const sym = xkbcommon.Keysym;
                            switch (@as(u32, @intFromEnum(keysym))) {
                                sym.BackSpace => {
                                    try piece_table.delete(cursor_pos - 1, 1);
                                    cursor_pos -= 1;
                                },
                                sym.Delete => {
                                    piece_table.delete(cursor_pos, 1) catch |e| switch (e) {
                                        error.OutOfBounds => {},
                                        else => return e,
                                    };
                                },
                                sym.Left => {
                                    cursor_pos -|= 1;
                                },
                                sym.Right => {
                                    cursor_pos += 1;
                                    cursor_pos = @min(cursor_pos, piece_table.getTotalSize());
                                },
                                else => if (key.state == .pressed) {
                                    const size = xkb_state.keyGetUtf8(keycode, &buf);
                                    try piece_table.insert(cursor_pos, buf[0..size]);
                                    cursor_pos += size;
                                },
                            }

                            const new_buffer_id, const new_framebuffer = try getFramebuffer(&framebuffers, &id_pool, pool_alloc, window_size);

                            // put some interesting colors into the new_framebuffer
                            renderGradient(new_framebuffer, window_size);

                            const text = try piece_table.writeAllAlloc();
                            defer gpa.free(text);
                            // blit some characters
                            renderText(new_framebuffer, window_size, .{ 10, 10 }, text);

                            try conn.send(
                                wayland.core.ShmPool.Request,
                                wl_shm_pool_id,
                                .{ .create_buffer = .{
                                    .new_id = new_buffer_id,
                                    .offset = @intCast(@intFromPtr(new_framebuffer.ptr) - @intFromPtr(pool_bytes.ptr)),
                                    .width = @intCast(window_size[0]),
                                    .height = @intCast(window_size[1]),
                                    .stride = @as(i32, @intCast(window_size[0])) * @sizeOf([4]u8),
                                    .format = .argb8888,
                                } },
                            );

                            try conn.send(
                                wayland.core.Surface.Request,
                                surface_id,
                                .{ .attach = .{
                                    .buffer = new_buffer_id,
                                    .x = 0,
                                    .y = 0,
                                } },
                            );

                            try conn.send(
                                wayland.core.Surface.Request,
                                surface_id,
                                .{ .damage = .{
                                    .x = 0,
                                    .y = 0,
                                    .width = std.math.maxInt(i32),
                                    .height = std.math.maxInt(i32),
                                } },
                            );

                            // commit the configuration
                            try conn.send(
                                wayland.core.Surface.Request,
                                surface_id,
                                wayland.core.Surface.Request.commit,
                            );
                        }
                    }
                },
                else => {
                    std.debug.print("<- wl_keyboard@{}\n", .{event});
                },
            }
        } else if (header.object_id == zwp_text_input_v3_id) {
            const event = try wayland.deserialize(wayland.zwp.TextInputV3.Event, header, body);
            std.debug.print("<- zwp_text_input_v3@{} event {}\n", .{ zwp_text_input_v3_id, event });
            switch (event) {
                .enter => |e| {
                    _ = e;

                    // if (e.surface == surface_id) {
                    try conn.send(
                        wayland.zwp.TextInputV3.Request,
                        zwp_text_input_v3_id,
                        .enable,
                    );

                    try conn.send(
                        wayland.zwp.TextInputV3.Request,
                        zwp_text_input_v3_id,
                        .{ .set_content_type = .{
                            .hint = .multiline,
                            .purpose = .normal,
                        } },
                    );

                    try conn.send(
                        wayland.zwp.TextInputV3.Request,
                        zwp_text_input_v3_id,
                        .commit,
                    );
                    // }
                },
                .leave => |e| {
                    _ = e;

                    // if (e.surface == surface_id) {
                    try conn.send(
                        wayland.zwp.TextInputV3.Request,
                        zwp_text_input_v3_id,
                        .disable,
                    );
                    // }
                },
                .preedit_string => {},
                .commit_string => |commit| {
                    edit_slice = edit_buffer[0..commit.text.len];
                    @memcpy(edit_slice.?, commit.text);
                },
                .delete_surrounding_text => |offset| {
                    delete_before = offset.before_length;
                    delete_after = offset.after_length;
                },
                .done => |_| {
                    // 1 replace existing pre-edit string with cursor
                    // 2 delete requested surrounding text
                    const start = cursor_pos - delete_before;
                    const end = cursor_pos + delete_after;
                    const length = end - start;
                    if (length != 0) {
                        try piece_table.delete(start, length);
                    }
                    // 3 insert commit string with cursor at its end
                    if (edit_slice) |slice| {
                        try piece_table.insert(cursor_pos, slice);
                        cursor_pos += slice.len;
                        edit_slice = null;
                    }
                    // 4 calculate surrounding text to send
                    // 5 insert new preedit text in cursor position
                    // 6 place cursor inside predit text
                },
            }
        } else if (framebuffers.get(header.object_id)) |framebuffer_slice| {
            const event = try wayland.deserialize(wayland.core.Buffer.Event, header, body);
            switch (event) {
                .release => {
                    _ = framebuffers.remove(header.object_id);
                    pool_alloc.free(framebuffer_slice);
                },
            }
        } else if (header.object_id == DISPLAY_ID) {
            const event = try wayland.deserialize(wayland.core.Display.Event, header, body);
            switch (event) {
                .@"error" => |err| std.debug.print("<- error({}): {} {s}\n", .{ err.object_id, err.code, err.message }),
                .delete_id => |id| id_pool.destroy(id.id),
            }
        } else {
            std.debug.print("{} {x} \"{}\"\n", .{ header.object_id, header.size_and_opcode.opcode, std.zig.fmtEscapes(std.mem.sliceAsBytes(body)) });
        }
    }
}

fn cmsg(comptime T: type) type {
    const padding_size = (@sizeOf(T) + @sizeOf(c_long) - 1) & ~(@as(usize, @sizeOf(c_long)) - 1);
    return extern struct {
        len: c_ulong = @sizeOf(@This()) - padding_size,
        level: c_int,
        type: c_int,
        data: T,
        _padding: [padding_size]u8 align(1) = [_]u8{0} ** padding_size,
    };
}

fn getFramebuffer(framebuffers: *std.AutoHashMap(u32, []Pixel), id_pool: *wayland.IdPool, pool_alloc: std.mem.Allocator, fb_size: [2]u32) !struct { u32, []Pixel } {
    const new_buffer_id = id_pool.create();
    const new_framebuffer = try pool_alloc.alloc(Pixel, fb_size[0] * fb_size[1]);
    try framebuffers.put(new_buffer_id, new_framebuffer);
    return .{ new_buffer_id, new_framebuffer };
}

fn renderGradient(framebuffer: []Pixel, fb_size: [2]u32) void {
    for (0..fb_size[1]) |y| {
        const row = framebuffer[y * fb_size[0] .. (y + 1) * fb_size[0]];
        for (row, 0..fb_size[0]) |*pixel, x| {
            pixel.* = .{
                @truncate(x),
                @truncate(y),
                0x00,
                0xFF,
            };
        }
    }
}

fn textWidth(str: []const u8) usize {
    return std.unicode.utf8CountCodepoints(str) catch 0; // incorrect, but I'm going with it
}

fn renderText(framebuffer: []Pixel, fb_size: [2]u32, pos: [2]usize, str: []const u8) void {
    const top, const left = pos;
    const bot = @min(top + 8, fb_size[1]);
    const right = @min(left + textWidth(str) * 8, fb_size[0]);

    for (top..bot) |y| {
        const row = framebuffer[y * fb_size[0] .. (y + 1) * fb_size[0]];
        for (row[left..right], left..right) |*pixel, x| {
            const col = ((x - left) / 8);
            const which_char = str[col];
            if (!std.ascii.isPrint(which_char)) continue;
            const char = font8x8.font8x8_basic[which_char];
            const line = char[(y - top) % 8];
            if ((line >> @intCast((x - left) % 8)) & 0x1 != 0) {
                pixel.* = toPixel(Theme.foreground);
            } else {
                pixel.* = toPixel(Theme.background);
            }
        }
    }
}
