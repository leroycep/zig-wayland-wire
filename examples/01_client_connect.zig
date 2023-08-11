const std = @import("std");
const wayland = @import("wayland");

pub fn main() !void {
    var general_allocator = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = general_allocator.deinit();
    const gpa = general_allocator.allocator();

    const display_path = try wayland.getDisplayPath(gpa);
    defer gpa.free(display_path);

    const socket = try std.net.connectUnixSocket(display_path);
    defer socket.close();

    // reserve an object id for the registry
    const registry_id = 2;
    {
        var buffer: [5]u32 = undefined;
        const message = try wayland.serialize(wayland.core.Display.Request, &buffer, 1, .{ .get_registry = .{ .registry = registry_id } });
        try socket.writeAll(std.mem.sliceAsBytes(message));
    }

    // create a sync callback so we know when the registry is done listing extensions
    const registry_done_id = 3;
    {
        var buffer: [5]u32 = undefined;
        const message = try wayland.serialize(wayland.core.Display.Request, &buffer, 1, .{ .sync = .{ .callback = registry_done_id } });
        try socket.writeAll(std.mem.sliceAsBytes(message));
    }

    var shm_id: u32 = 4;
    var compositor_id: u32 = 5;
    var xdg_wm_base_id: u32 = 6;

    var message_buffer = std.ArrayList(u32).init(gpa);
    defer message_buffer.deinit();
    while (true) {
        var header: wayland.Header = undefined;
        const header_bytes_read = try socket.readAll(std.mem.asBytes(&header));
        if (header_bytes_read < @sizeOf(wayland.Header)) {
            break;
        }

        try message_buffer.resize((header.size_and_opcode.size - @sizeOf(wayland.Header)) / @sizeOf(u32));
        const bytes_read = try socket.readAll(std.mem.sliceAsBytes(message_buffer.items));
        message_buffer.shrinkRetainingCapacity(bytes_read / @sizeOf(u32));

        if (header.object_id == registry_id) {
            const event = try wayland.deserialize(wayland.core.Registry.Event, header, message_buffer.items);
            switch (event) {
                .global => |global| {
                    var buffer: [20]u32 = undefined;
                    if (std.mem.eql(u8, global.interface, "wl_shm")) {
                        const message = try wayland.serialize(
                            wayland.core.Registry.Request,
                            &buffer,
                            registry_id,
                            .{ .bind = .{
                                .name = global.name,
                                .interface = global.interface,
                                .version = global.version,
                                .new_id = shm_id,
                            } },
                        );
                        try socket.writeAll(std.mem.sliceAsBytes(message));
                    } else if (std.mem.eql(u8, global.interface, "wl_compositor")) {
                        const message = try wayland.serialize(
                            wayland.core.Registry.Request,
                            &buffer,
                            registry_id,
                            .{ .bind = .{
                                .name = global.name,
                                .interface = global.interface,
                                .version = global.version,
                                .new_id = compositor_id,
                            } },
                        );
                        try socket.writeAll(std.mem.sliceAsBytes(message));
                    } else if (std.mem.eql(u8, global.interface, "xdg_wm_base")) {
                        const message = try wayland.serialize(
                            wayland.core.Registry.Request,
                            &buffer,
                            registry_id,
                            .{ .bind = .{
                                .name = global.name,
                                .interface = global.interface,
                                .version = global.version,
                                .new_id = xdg_wm_base_id,
                            } },
                        );
                        try socket.writeAll(std.mem.sliceAsBytes(message));
                    }
                },
                .global_remove => {},
            }
        } else if (header.object_id == registry_done_id) {
            break;
        } else {
            std.debug.print("{} {x} \"{}\"\n", .{ header.object_id, header.size_and_opcode.opcode, std.zig.fmtEscapes(std.mem.sliceAsBytes(message_buffer.items)) });
        }
    }

    const surface_id = 7;
    {
        var buffer: [10]u32 = undefined;
        const message = try wayland.serialize(
            wayland.core.Compositor.Request,
            &buffer,
            compositor_id,
            .{ .create_surface = .{
                .new_id = surface_id,
            } },
        );
        try socket.writeAll(std.mem.sliceAsBytes(message));
    }

    const xdg_surface_id = 8;
    {
        var buffer: [10]u32 = undefined;
        const message = try wayland.serialize(
            wayland.xdg.WmBase.Request,
            &buffer,
            xdg_wm_base_id,
            .{ .get_xdg_surface = .{
                .id = xdg_surface_id,
                .surface = surface_id,
            } },
        );
        try socket.writeAll(std.mem.sliceAsBytes(message));
    }

    const xdg_toplevel_id = 9;
    {
        var buffer: [10]u32 = undefined;
        const message = try wayland.serialize(
            wayland.xdg.Surface.Request,
            &buffer,
            xdg_surface_id,
            .{ .get_toplevel = .{
                .id = xdg_toplevel_id,
            } },
        );
        try socket.writeAll(std.mem.sliceAsBytes(message));
    }

    {
        var buffer: [10]u32 = undefined;
        const message = try wayland.serialize(
            wayland.core.Surface.Request,
            &buffer,
            surface_id,
            wayland.core.Surface.Request.commit,
        );
        try socket.writeAll(std.mem.sliceAsBytes(message));
    }

    {
        var buffer: [5]u32 = undefined;
        const message = try wayland.serialize(wayland.core.Display.Request, &buffer, 1, .{ .sync = .{ .callback = registry_done_id } });
        try socket.writeAll(std.mem.sliceAsBytes(message));
    }

    var done = false;
    var surface_configured = false;
    while (!done or !surface_configured) {
        var header: wayland.Header = undefined;
        const header_bytes_read = try socket.readAll(std.mem.asBytes(&header));
        if (header_bytes_read < @sizeOf(wayland.Header)) {
            return error.SocketClosed;
        }

        try message_buffer.resize((header.size_and_opcode.size - @sizeOf(wayland.Header)) / @sizeOf(u32));
        const bytes_read = try socket.readAll(std.mem.sliceAsBytes(message_buffer.items));
        message_buffer.shrinkRetainingCapacity(bytes_read / @sizeOf(u32));

        if (header.object_id == xdg_surface_id) {
            const event = try wayland.deserialize(wayland.xdg.Surface.Event, header, message_buffer.items);
            switch (event) {
                .configure => |conf| {
                    var buffer: [10]u32 = undefined;
                    const message = try wayland.serialize(
                        wayland.xdg.Surface.Request,
                        &buffer,
                        xdg_surface_id,
                        .{ .ack_configure = .{
                            .serial = conf.serial,
                        } },
                    );
                    try socket.writeAll(std.mem.sliceAsBytes(message));
                    surface_configured = true;
                },
            }
        } else if (header.object_id == xdg_toplevel_id) {
            // const event = try wayland.deserialize(wayland.xdg.Toplevel.Event, header, message_buffer.items);
            // std.debug.print("<- {}\n", .{event});
            std.debug.print("<- xdg_toplevel@{} {s} {}\n", .{ header.object_id, @tagName(@as(std.meta.Tag(wayland.xdg.Toplevel.Event), @enumFromInt(header.size_and_opcode.opcode))), std.zig.fmtEscapes(std.mem.sliceAsBytes(message_buffer.items)) });
        } else if (header.object_id == registry_done_id) {
            done = true;
        } else if (header.object_id == shm_id) {
            const event = try wayland.deserialize(wayland.core.Shm.Event, header, message_buffer.items);
            switch (event) {
                .format => |format| std.debug.print("<- format {} {}\n", .{ format.format, std.zig.fmtEscapes(std.mem.asBytes(&format.format)) }),
            }
        } else if (header.object_id == 1) {
            const event = try wayland.deserialize(wayland.core.Display.Event, header, message_buffer.items);
            switch (event) {
                .@"error" => |err| std.debug.print("<- error({}): {} {s}\n", .{ err.object_id, err.code, err.message }),
                .delete_id => |id| std.debug.print("<- delete_id {}\n", .{id.name}),
            }
        } else {
            std.debug.print("{} {x} \"{}\"\n", .{ header.object_id, header.size_and_opcode.opcode, std.zig.fmtEscapes(std.mem.sliceAsBytes(message_buffer.items)) });
        }
    }

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

    const wl_shm_pool_id = 10;
    {
        var buffer: [10]u32 = undefined;
        const message = try wayland.serialize(
            wayland.core.Shm.Request,
            &buffer,
            shm_id,
            .{ .create_pool = .{
                .new_id = wl_shm_pool_id,
                .size = framebuffer_file_len,
            } },
        );
        // Send the file descriptor through a control message
        const message_bytes = std.mem.sliceAsBytes(message);
        const msg_iov = [_]std.os.iovec_const{
            .{
                .iov_base = message_bytes.ptr,
                .iov_len = message_bytes.len,
            },
        };
        const control_message = cmsg(std.os.fd_t){
            .level = std.os.SOL.SOCKET,
            .type = 0x01, // value of SCM_RIGHTS
            .data = framebuffer_fd,
        };
        const socket_message = std.os.msghdr_const{
            .name = null,
            .namelen = 0,
            .iov = &msg_iov,
            .iovlen = msg_iov.len,
            // .control = null,
            // .controllen = 0,
            .control = &control_message,
            .controllen = @sizeOf(cmsg(std.os.fd_t)),
            .flags = 0,
        };
        _ = try std.os.sendmsg(socket.handle, &socket_message, 0);
    }

    const wl_buffer_id = 11;
    {
        var buffer: [10]u32 = undefined;
        const message = try wayland.serialize(
            wayland.core.ShmPool.Request,
            &buffer,
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
        try socket.writeAll(std.mem.sliceAsBytes(message));
    }

    {
        var buffer: [10]u32 = undefined;
        const message = try wayland.serialize(
            wayland.core.Surface.Request,
            &buffer,
            surface_id,
            .{ .attach = .{
                .buffer = wl_buffer_id,
                .x = 0,
                .y = 0,
            } },
        );
        try socket.writeAll(std.mem.sliceAsBytes(message));
    }

    {
        var buffer: [10]u32 = undefined;
        const message = try wayland.serialize(
            wayland.core.Surface.Request,
            &buffer,
            surface_id,
            .{ .damage = .{
                .x = 0,
                .y = 0,
                .width = std.math.maxInt(i32),
                .height = std.math.maxInt(i32),
            } },
        );
        try socket.writeAll(std.mem.sliceAsBytes(message));
    }

    {
        var buffer: [10]u32 = undefined;
        const message = try wayland.serialize(
            wayland.core.Surface.Request,
            &buffer,
            surface_id,
            wayland.core.Surface.Request.commit,
        );
        try socket.writeAll(std.mem.sliceAsBytes(message));
    }

    var running = true;
    while (running) {
        var header: wayland.Header = undefined;
        const header_bytes_read = try socket.readAll(std.mem.asBytes(&header));
        if (header_bytes_read < @sizeOf(wayland.Header)) {
            return error.SocketClosed;
        }

        try message_buffer.resize((header.size_and_opcode.size - @sizeOf(wayland.Header)) / @sizeOf(u32));
        const bytes_read = try socket.readAll(std.mem.sliceAsBytes(message_buffer.items));
        message_buffer.shrinkRetainingCapacity(bytes_read / @sizeOf(u32));

        if (header.object_id == xdg_surface_id) {
            const event = try wayland.deserialize(wayland.xdg.Surface.Event, header, message_buffer.items);
            switch (event) {
                .configure => |conf| {
                    var buffer: [10]u32 = undefined;
                    const message = try wayland.serialize(
                        wayland.xdg.Surface.Request,
                        &buffer,
                        xdg_surface_id,
                        .{ .ack_configure = .{
                            .serial = conf.serial,
                        } },
                    );
                    try socket.writeAll(std.mem.sliceAsBytes(message));
                },
            }
        } else if (header.object_id == xdg_toplevel_id) {
            const event = try wayland.deserialize(wayland.xdg.Toplevel.Event, header, message_buffer.items);
            switch (event) {
                .configure => |conf| {
                    std.debug.print("<- xdg_toplevel@{} configure <{}, {}> {any}\n", .{ header.object_id, conf.width, conf.height, conf.states });
                },
                .close => running = false,
                else => |tag| std.debug.print("<- xdg_toplevel@{} {s} {}\n", .{ header.object_id, @tagName(tag), event }),
            }
        } else if (header.object_id == wl_buffer_id) {
            const event = try wayland.deserialize(wayland.core.Buffer.Event, header, message_buffer.items);
            std.debug.print("<- wl_buffer@{} {}\n", .{ header.object_id, event });
        } else if (header.object_id == 1) {
            const event = try wayland.deserialize(wayland.core.Display.Event, header, message_buffer.items);
            switch (event) {
                .@"error" => |err| std.debug.print("<- error({}): {} {s}\n", .{ err.object_id, err.code, err.message }),
                .delete_id => {
                    // TODO: add id to list of free ids
                },
            }
        } else {
            std.debug.print("{} {x} \"{}\"\n", .{ header.object_id, header.size_and_opcode.opcode, std.zig.fmtEscapes(std.mem.sliceAsBytes(message_buffer.items)) });
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
