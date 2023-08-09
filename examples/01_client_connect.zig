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
    var wp_single_pixel_buffer_manager_id: u32 = 7;

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
            std.debug.print("{} {s} ", .{ header.object_id, @tagName(event) });
            switch (event) {
                .global => |global| {
                    std.debug.print("{} \"{}\" v{}\n", .{ global.name, std.zig.fmtEscapes(global.interface), global.version });

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
                    } else if (std.mem.eql(u8, global.interface, "wp_single_pixel_buffer_manager_v1")) {
                        const message = try wayland.serialize(
                            wayland.core.Registry.Request,
                            &buffer,
                            registry_id,
                            .{ .bind = .{
                                .name = global.name,
                                .interface = global.interface,
                                .version = global.version,
                                .new_id = wp_single_pixel_buffer_manager_id,
                            } },
                        );
                        try socket.writeAll(std.mem.sliceAsBytes(message));
                    }
                },
                .global_remove => std.debug.print("{}\n", .{std.zig.fmtEscapes(std.mem.sliceAsBytes(message_buffer.items))}),
            }
        } else if (header.object_id == registry_done_id) {
            std.debug.print("<-", .{});
            for (message_buffer.items) |word| {
                std.debug.print(" {}", .{std.fmt.fmtSliceHexLower(std.mem.asBytes(&word))});
            }
            std.debug.print(" (sync event id)\n", .{});
            break;
        } else {
            std.debug.print("{} {x} \"{}\"\n", .{ header.object_id, header.size_and_opcode.opcode, std.zig.fmtEscapes(std.mem.sliceAsBytes(message_buffer.items)) });
        }
    }
}
