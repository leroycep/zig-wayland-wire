const std = @import("std");
const wayland = @import("wayland");

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
    });

    const DISPLAY_ID = 1;
    const shm_id = ids[0] orelse return error.NeccessaryWaylandExtensionMissing;
    const compositor_id = ids[1] orelse return error.NeccessaryWaylandExtensionMissing;
    const xdg_wm_base_id = ids[2] orelse return error.NeccessaryWaylandExtensionMissing;
    const wl_seat_id = ids[3] orelse return error.NeccessaryWaylandExtensionMissing;

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
    const Pixel = [4]u8;
    const framebuffer_size = [2]usize{ 128, 128 };
    const framebuffer_file_len = framebuffer_size[0] * framebuffer_size[1] * @sizeOf(Pixel);

    const framebuffer_fd = try std.os.memfd_create("my-wayland-framebuffer", 0);
    try std.os.ftruncate(framebuffer_fd, framebuffer_file_len);
    const framebuffer_bytes = try std.os.mmap(null, framebuffer_file_len, std.os.PROT.READ | std.os.PROT.WRITE, std.os.MAP.SHARED, framebuffer_fd, 0);
    const framebuffer = @as([*][4]u8, @ptrCast(framebuffer_bytes.ptr))[0 .. framebuffer_bytes.len / @sizeOf([4]u8)];

    // put some interesting colors into the framebuffer
    for (0..framebuffer_size[1]) |y| {
        const row = framebuffer[y * framebuffer_size[0] .. (y + 1) * framebuffer_size[0]];
        for (row, 0..framebuffer_size[0]) |*pixel, x| {
            pixel.* = .{
                @truncate(x),
                @truncate(y),
                0x00,
                0xFF,
            };
        }
    }

    const wl_shm_pool_id = id_pool.create();
    {
        std.debug.print("framebuffer_fd: {}\n", .{framebuffer_fd});
        try conn.send(
            wayland.core.Shm.Request,
            shm_id,
            .{ .create_pool = .{
                .new_id = wl_shm_pool_id,
                .fd = @enumFromInt(framebuffer_fd),
                .size = framebuffer_file_len,
            } },
        );
    }

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
                },
                .close => running = false,
                else => |tag| std.debug.print("<- xdg_toplevel@{} {s} {}\n", .{ header.object_id, @tagName(tag), event }),
            }
        } else if (header.object_id == wl_buffer_id) {
            const event = try wayland.deserialize(wayland.core.Buffer.Event, header, body);
            std.debug.print("<- wl_buffer@{} {}\n", .{ header.object_id, event });
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
                },
                else => {
                    std.debug.print("<- wl_keyboard@{}\n", .{event});
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
