const std = @import("std");
const wayland = @import("wayland");

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
