const types = @import("types.zig");

pub const Display = struct {
    pub const Request = union(enum) {
        sync: struct {
            /// new_id<wl_callback>
            callback: u32,
        },
        get_registry: struct {
            /// new_id<wl_registry>
            registry: u32,
        },
    };

    pub const Event = union(enum) {
        @"error": struct {
            object_id: u32,
            code: u32,
            message: []const u8,
        },
        delete_id: struct {
            id: u32,
        },
    };

    pub const Error = enum(u32) {
        invalid_object,
        invalid_method,
        no_memory,
        implementation,
    };
};

pub const Registry = struct {
    pub const Event = union(enum) {
        global: struct {
            name: u32,
            interface: [:0]const u8,
            version: u32,
        },
        global_remove: struct {
            name: u32,
        },
    };

    pub const Request = union(enum) {
        bind: struct {
            name: u32,
            interface: [:0]const u8,
            version: u32,
            new_id: u32,
        },
    };
};

pub const Compositor = struct {
    pub const INTERFACE = "wl_compositor";
    pub const VERSION = 5;

    pub const Request = union(enum) {
        create_surface: struct {
            new_id: u32,
        },
        create_region: struct {
            new_id: u32,
        },
    };
};

pub const ShmPool = struct {
    pub const Request = union(enum) {
        create_buffer: struct {
            new_id: u32,
            offset: i32,
            width: i32,
            height: i32,
            stride: i32,
            format: Shm.Format,
        },
        destroy: void,
        resize: struct {
            size: i32,
        },
    };
};

pub const Shm = struct {
    pub const INTERFACE = "wl_shm";
    pub const VERSION = 1;

    pub const Request = union(enum) {
        create_pool: struct {
            new_id: u32,
            // file descriptors are sent through a control message
            fd: types.Fd,
            size: u32,
        },
    };

    pub const Event = union(enum) {
        format: struct {
            format: Format,
        },
    };

    pub const Error = enum(u32) {
        invalid_format,
        invalid_stride,
        invalid_fd,
    };

    pub const Format = enum(u32) {
        argb8888,
        xrgb8888,
        _,
    };
};

pub const Surface = struct {
    pub const Request = union(enum) {
        destroy: void,
        attach: struct {
            buffer: u32,
            x: i32,
            y: i32,
        },
        damage: struct {
            x: i32,
            y: i32,
            width: i32,
            height: i32,
        },
        frame: struct {
            /// id of a new callback object
            callback: u32,
        },
        set_opaque_region: struct {
            region: u32,
        },
        set_input_region: struct {
            region: u32,
        },
        commit: void,
    };

    pub const Event = union(enum) {
        enter: struct {
            output: u32,
        },
        leave: struct {
            output: u32,
        },
        preferred_buffer_scale: struct {
            factor: i32,
        },
        preferred_buffer_transform: struct {
            transform: u32,
        },
    };

    pub const Error = enum(u32) {
        invalid_scale,
        invalid_transform,
        invalid_size,
        invalid_offset,
        defunct_role_object,
    };
};

pub const Buffer = struct {
    pub const Request = union(enum) {
        destroy: void,
    };

    pub const Event = union(enum) {
        release: void,
    };
};

pub const Seat = struct {
    pub const INTERFACE = "wl_seat";
    pub const VERSION = 8;

    pub const Request = union(enum) {
        get_pointer: struct {
            new_id: u32,
        },
        get_keyboard: struct {
            new_id: u32,
        },
        get_touch: struct {
            new_id: u32,
        },
        release: void,
    };

    pub const Event = union(enum) {
        capabilities: struct {
            capability: u32,
        },
        name: struct {
            name: []const u8,
        },
    };

    pub const Capability = packed struct(u32) {
        pointer: bool,
        keyboard: bool,
        touch: bool,
        _unused: u29,
    };

    pub const Error = enum(u32) {};
};

pub const Pointer = struct {
    pub const Request = union(enum) {
        set_cursor: struct {
            serial: u32,
            surface: u32,
            hotspot_x: i32,
            hotspot_y: i32,
        },
        release: void,
    };

    pub const Event = union(enum) {
        enter: struct {
            serial: u32,
            surface: u32,
            surface_x: u32,
            surface_y: u32,
        },
        leave: struct {
            serial: u32,
            surface: u32,
        },
        motion: struct {
            time: u32,
            surface_x: i32, //i24.8
            surface_y: i32, //i24.8
        },
        button: struct {
            serial: u32,
            time: u32,
            button: u32,
            state: ButtonState,
        },
        axis: struct {
            time: u32,
            axis: Axis,
            value: i32, //i24.8
        },
        frame: void,
        axis_source: struct {
            axis_source: u32,
        },
        axis_stop: struct {
            time: u32,
            axis: Axis,
        },
        axis_discrete: struct {
            axis: Axis,
            discrete: i32,
        },
        axis_value120: struct {
            axis: Axis,
            value120: i32,
        },
        axis_relative_direction: struct {
            axis: Axis,
            direction: AxisRelativeDirection,
        },
    };

    pub const Error = enum(u32) {
        role,
    };

    pub const ButtonState = enum(u32) {
        released,
        pressed,
    };

    pub const Axis = enum(u32) {
        vertical_scroll,
        horizontal_scroll,
    };

    pub const AxisSource = enum(u32) {
        wheel,
        finger,
        continuous,
        wheel_tilt,
    };

    pub const AxisRelativeDirection = enum(u32) {
        identical,
        inverted,
    };
};

pub const Keyboard = struct {
    pub const Request = union(enum) {
        release: void,
    };

    pub const Event = union(enum) {
        keymap: struct {
            format: KeymapFormat,
            fd: types.Fd,
            size: u32,
        },
        enter: struct {
            serial: u32,
            surface: u32,
            keys: []const u32,
        },
        leave: struct {
            serial: u32,
            surface: u32,
        },
        key: struct {
            serial: u32,
            time: u32,
            key: u32,
            state: KeyState,
        },
        modifiers: struct {
            serial: u32,
            mods_depressed: u32,
            mods_latched: u32,
            mods_locked: u32,
            group: u32,
        },
        repeat_info: struct {
            rate: i32,
            delay: i32,
        },
    };

    pub const KeymapFormat = enum(u32) {
        no_keymap,
        xkb_v1,
    };

    pub const KeyState = enum(u32) {
        released,
        pressed,
    };
};
